import 'dart:convert';
import 'dart:io';

import 'package:a_trade/market_data/alpaca_market_data_client.dart';
import 'package:a_trade/market_data/daily_indicators.dart';
import 'package:a_trade/market_data/indicator_snapshot.dart';
import 'package:a_trade/market_data/market_data.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

// ignore: avoid_relative_lib_imports
import '../backend/lib/assistant.dart';
// ignore: avoid_relative_lib_imports
import '../backend/lib/daily_indicator_service.dart';
// ignore: avoid_relative_lib_imports
import '../backend/lib/lan_data_policy.dart';
// ignore: avoid_relative_lib_imports
import '../backend/lib/server.dart';

final _fixtureNow = DateTime.utc(2026, 10, 12, 12);

class _IndicatorMarket implements MarketDataRepository {
  _IndicatorMarket({this.provider = MarketDataProvider.alpaca, DateTime? now})
    : now = now ?? _fixtureNow;

  final MarketDataProvider provider;
  final DateTime now;
  int barCalls = 0;
  bool fail = false;
  List<MarketBar>? overrideBars;
  DateTime? requestedStart;
  DateTime? requestedEnd;
  PriceAdjustment? requestedAdjustment;

  MarketDataFeed get feed => switch (provider) {
    MarketDataProvider.alpaca => MarketDataFeed.iex,
    MarketDataProvider.twelveData => MarketDataFeed.endOfDay,
    MarketDataProvider.schwab => MarketDataFeed.unknown,
  };

  @override
  Future<MarketQuote?> latestQuote(String symbol) async => null;

  @override
  Future<List<MarketBar>> dailyBars(
    String symbol, {
    required DateTime start,
    required DateTime end,
    PriceAdjustment adjustment = PriceAdjustment.raw,
  }) async {
    barCalls++;
    requestedStart = start;
    requestedEnd = end;
    requestedAdjustment = adjustment;
    if (fail) {
      throw const MarketDataException(
        'synthetic provider detail must not be exposed',
        statusCode: 429,
      );
    }
    return overrideBars ?? _barsFor(start, end, now);
  }

  List<MarketBar> _barsFor(DateTime start, DateTime end, DateTime retrievedAt) {
    final dates = UsEquitySessionCalendar.expectedSessionDates(
      start: start,
      end: end,
    );
    return [
      for (var index = 0; index < dates.length; index++)
        _bar(
          dates[index],
          provider: provider,
          feed: feed,
          retrievedAt: retrievedAt,
          close: 100 + index.toDouble(),
        ),
    ];
  }

  MarketBar _bar(
    String date, {
    required MarketDataProvider provider,
    required MarketDataFeed feed,
    required DateTime retrievedAt,
    required double close,
    String symbol = 'SYNTH',
    DateTime? timestamp,
    String? tradingDate,
    String? exchangeTimezone,
  }) {
    final parsed = _utcDate(date);
    return MarketBar(
      symbol: symbol,
      provider: provider,
      feed: feed,
      timestamp: timestamp ?? parsed,
      retrievedAt: retrievedAt,
      adjustment: PriceAdjustment.raw,
      open: close - 0.25,
      high: close + 1,
      low: close - 1,
      close: close,
      volume: 1000,
      tradingDate:
          tradingDate ??
          (provider == MarketDataProvider.twelveData ? date : null),
      exchangeTimezone:
          exchangeTimezone ??
          (provider == MarketDataProvider.twelveData
              ? 'America/New_York'
              : null),
    );
  }
}

DateTime _utcDate(String date) => DateTime.utc(
  int.parse(date.substring(0, 4)),
  int.parse(date.substring(5, 7)),
  int.parse(date.substring(8, 10)),
);

DailyIndicatorService _service(
  _IndicatorMarket market, {
  DateTime Function()? clock,
}) => DailyIndicatorService(
  marketData: market,
  provider: market.provider,
  clock: clock ?? () => market.now,
);

void main() {
  group('US equity session calendar', () {
    test('excludes regular holidays and weekends in the bounded scope', () {
      expect(
        UsEquitySessionCalendar.expectedSessionDates(
          start: DateTime.utc(2025, 1, 8),
          end: DateTime.utc(2025, 1, 10),
        ),
        ['2025-01-08', '2025-01-10'],
      );
      expect(
        UsEquitySessionCalendar.expectedSessionDates(
          start: DateTime.utc(2026, 7, 2),
          end: DateTime.utc(2026, 7, 7),
        ),
        ['2026-07-02', '2026-07-06', '2026-07-07'],
      );
      expect(
        UsEquitySessionCalendar.expectedSessionDates(
          start: DateTime.utc(2027, 12, 30),
          end: DateTime.utc(2028, 1, 4),
        ),
        ['2027-12-30', '2027-12-31', '2028-01-03', '2028-01-04'],
      );
    });

    test('requires conservative completed-session availability cutoffs', () {
      expect(
        UsEquitySessionCalendar.latestCompletedSessionDate(
          cutoff: DateTime.utc(2026, 10, 12, 5, 59),
          provider: MarketDataProvider.alpaca,
        ),
        '2026-10-09',
      );
      expect(
        UsEquitySessionCalendar.latestCompletedSessionDate(
          cutoff: DateTime.utc(2026, 10, 13, 6),
          provider: MarketDataProvider.alpaca,
        ),
        '2026-10-12',
      );
      expect(
        UsEquitySessionCalendar.latestCompletedSessionDate(
          cutoff: DateTime.utc(2026, 10, 13, 5, 59),
          provider: MarketDataProvider.twelveData,
        ),
        '2026-10-09',
      );
      expect(
        UsEquitySessionCalendar.latestCompletedSessionDate(
          cutoff: DateTime.utc(2026, 10, 13, 6),
          provider: MarketDataProvider.twelveData,
        ),
        '2026-10-12',
      );
      expect(
        UsEquitySessionCalendar.latestCompletedSessionDate(
          cutoff: DateTime.utc(2031),
          provider: MarketDataProvider.alpaca,
        ),
        isNull,
      );
    });
  });

  group('DailyIndicatorService', () {
    test(
      'uses one bounded raw history request and returns generic engine JSON',
      () async {
        final market = _IndicatorMarket();
        final result = await _service(market).analyze(symbol: 'SYNTH');

        expect(result['status'], 'ok');
        expect(result['coverage'], isA<String>());
        expect((result['coverage'] as String).trim(), isNotEmpty);
        expect(market.barCalls, 1);
        expect(market.requestedAdjustment, PriceAdjustment.raw);
        expect(market.requestedStart, DateTime.utc(2026, 6, 15));
        expect(market.requestedEnd, DateTime.utc(2026, 10, 9));
        final data = result['data'] as Map<String, dynamic>;
        expect(data['symbol'], 'SYNTH');
        expect(data['formulaVersion'], dailyIndicatorFormulaVersion);
        expect(data['lookback'], dailyIndicatorLookbackSessions);
        expect(data['trendLag'], dailyIndicatorLagSessions);
        expect(data['rsiPeriod'], dailyIndicatorRsiPeriod);
        expect(data['maximumRetrievalAgeSeconds'], 300);
        final cutoff = DateTime.parse(data['analysisCutoff'] as String);
        expect(cutoff, _fixtureNow);
        expect(data['corporateActionComparabilityConfirmed'], isFalse);
        expect((data['coverage'] as Map)['state'], 'complete');
        final metricUnits = <String, String>{
          'sessionColors': 'count and fraction of N sessions',
          'greenToRedRatio': 'ratio',
          'closeReturn': 'fraction',
          'simpleMovingAverage': 'price',
          'relativeVolume': 'ratio',
          'smaTrend': 'fraction',
          'exponentialMovingAverage': 'price',
          'relativeStrengthIndex': 'index (0..100)',
        };
        for (final entry in metricUnits.entries) {
          final metric = data[entry.key] as Map;
          expect(metric['units'], entry.value, reason: entry.key);
          expect(metric['formulaVersion'], dailyIndicatorFormulaVersion);
          expect(metric['formula'], isA<String>());
          expect(metric['parameters'], isA<Map>());
          expect(metric['requiredSampleCount'], isA<int>());
          expect(metric['observedSampleCount'], isA<int>());
          expect(metric['staleSampleCount'], isA<int>());
          expect(metric['retrievalTimes'], isA<List>());
          expect(metric['missingSessionDates'], isA<List>());
          if (metric['availability'] == 'available') {
            expect(metric['unavailableReason'], isNull, reason: entry.key);
            expect(metric['value'], isNotNull, reason: entry.key);
          } else {
            expect(metric['availability'], 'unavailable', reason: entry.key);
            expect(metric['value'], isNull, reason: entry.key);
            expect(
              metric['unavailableReason'],
              isA<String>(),
              reason: entry.key,
            );
          }
        }
        final colors = (data['sessionColors'] as Map)['value'] as Map;
        for (final key in ['greenCount', 'redCount', 'flatCount']) {
          expect(colors[key], isA<int>());
        }
        for (final key in ['greenFraction', 'redFraction', 'flatFraction']) {
          expect(colors[key], isA<double>());
        }
        final trend = data['smaTrend'] as Map;
        expect(trend['availability'], 'available');
        expect(trend['units'], 'fraction');
        expect(
          trend['parameters'],
          containsPair('K', dailyIndicatorLagSessions),
        );
        expect(trend['value'], containsPair('direction', 'rising'));
        expect((trend['value'] as Map)['slope'], isA<double>());
        final ema = data['exponentialMovingAverage'] as Map;
        expect(ema['availability'], 'available');
        expect(ema['units'], 'price');
        expect(
          ema['parameters'],
          containsPair('N', dailyIndicatorLookbackSessions),
        );
        expect(ema['value'], isA<double>());
        final rsi = data['relativeStrengthIndex'] as Map;
        expect(rsi['availability'], 'available');
        expect(rsi['units'], 'index (0..100)');
        expect(rsi['parameters'], containsPair('P', dailyIndicatorRsiPeriod));
        expect(rsi['value'], isA<double>());
        expect(
          ((data['closeReturn'] as Map)['unavailableReason']),
          DailyIndicatorUnavailableReason.nonComparableRawPrices.name,
        );
        for (final metric in [
          'simpleMovingAverage',
          'smaTrend',
          'exponentialMovingAverage',
          'relativeStrengthIndex',
        ]) {
          expect(
            (data[metric] as Map)['availability'],
            'available',
            reason: metric,
          );
        }
        final source = (result['sources'] as List).single as Map;
        expect(source['publishedAt'], '2026-10-09');
        expect(
          DateTime.parse(source['retrievedAt'] as String).isAfter(cutoff),
          isFalse,
        );
        expect(
          source['url'],
          contains('data.alpaca.markets/v2/stocks/SYNTH/bars'),
        );
        expect(source['url'], isNot(contains('key')));
        expect(
          result['limitations'].toString(),
          contains('not an authoritative'),
        );
        expect(
          result['limitations'],
          contains(
            'SMA, SMA trend, EMA and RSI describe arithmetic prices as supplied, '
            'including raw prices without a comparability gate; they are not '
            'economic metrics, and unverified corporate actions may distort '
            'them. Only closeReturn requires raw-price comparability confirmation.',
          ),
        );
        expect(
          IndicatorSnapshot.parse(
            result.cast<String, dynamic>(),
            'SYNTH',
          ).sources,
          isNotEmpty,
        );
      },
    );

    test(
      'reports calendar gaps as incomplete rather than inferring sessions',
      () async {
        final market = _IndicatorMarket();
        final bars = market._barsFor(
          DateTime.utc(2026, 6, 15),
          DateTime.utc(2026, 10, 9),
          _fixtureNow,
        );
        market.overrideBars = bars
          ..removeWhere((bar) => bar.timestamp == DateTime.utc(2026, 8, 3));

        final result = await _service(market).analyze(symbol: 'SYNTH');

        expect(result['status'], 'ok');
        final coverage = ((result['data'] as Map)['coverage'] as Map);
        expect(coverage['state'], 'incomplete');
        expect(coverage['missingExpectedSessionDates'], contains('2026-08-03'));
      },
    );

    test(
      'empty, provider quota, mismatched identity, and future bars fail closed',
      () async {
        final emptyMarket = _IndicatorMarket()..overrideBars = [];
        final empty = await _service(emptyMarket).analyze(symbol: 'SYNTH');
        expect(empty['status'], 'unavailable');
        expect(empty['data'], isNull);
        expect(empty['sources'], isEmpty);
        expect((empty['coverage'] as String).trim(), isNotEmpty);
        expect(emptyMarket.barCalls, 1);

        final quotaMarket = _IndicatorMarket()..fail = true;
        final quota = await _service(quotaMarket).analyze(symbol: 'SYNTH');
        expect(quota['status'], 'unavailable');
        expect(quota['sources'], isEmpty);
        expect(quota.toString(), isNot(contains('synthetic provider detail')));
        expect(quotaMarket.barCalls, 1);

        final identityMarket = _IndicatorMarket();
        final bars = identityMarket._barsFor(
          DateTime.utc(2026, 6, 15),
          DateTime.utc(2026, 10, 9),
          _fixtureNow,
        );
        final last = bars.last;
        bars[bars.length - 1] = MarketBar(
          symbol: 'OTHER',
          provider: last.provider,
          feed: last.feed,
          timestamp: last.timestamp,
          retrievedAt: last.retrievedAt,
          adjustment: last.adjustment,
          open: last.open,
          high: last.high,
          low: last.low,
          close: last.close,
          volume: last.volume,
        );
        identityMarket.overrideBars = bars;
        expect(
          (await _service(identityMarket).analyze(symbol: 'SYNTH'))['status'],
          'unavailable',
        );

        final futureMarket = _IndicatorMarket();
        final futureBars = futureMarket._barsFor(
          DateTime.utc(2026, 6, 15),
          DateTime.utc(2026, 10, 9),
          _fixtureNow,
        );
        final first = futureBars.first;
        futureBars[0] = MarketBar(
          symbol: first.symbol,
          provider: first.provider,
          feed: first.feed,
          timestamp: first.timestamp,
          retrievedAt: _fixtureNow.add(const Duration(seconds: 1)),
          adjustment: first.adjustment,
          open: first.open,
          high: first.high,
          low: first.low,
          close: first.close,
          volume: first.volume,
        );
        futureMarket.overrideBars = futureBars;
        expect(
          (await _service(futureMarket).analyze(symbol: 'SYNTH'))['status'],
          'unavailable',
        );

        final futureTimestampMarket = _IndicatorMarket(
          provider: MarketDataProvider.twelveData,
        );
        final eodBars = futureTimestampMarket._barsFor(
          DateTime.utc(2026, 6, 15),
          DateTime.utc(2026, 10, 9),
          _fixtureNow,
        );
        final lastEodBar = eodBars.last;
        eodBars[eodBars.length - 1] = MarketBar(
          symbol: lastEodBar.symbol,
          provider: lastEodBar.provider,
          feed: lastEodBar.feed,
          timestamp: _fixtureNow.add(const Duration(seconds: 1)),
          retrievedAt: lastEodBar.retrievedAt,
          adjustment: lastEodBar.adjustment,
          open: lastEodBar.open,
          high: lastEodBar.high,
          low: lastEodBar.low,
          close: lastEodBar.close,
          volume: lastEodBar.volume,
          tradingDate: lastEodBar.tradingDate,
          exchangeTimezone: lastEodBar.exchangeTimezone,
        );
        futureTimestampMarket.overrideBars = eodBars;
        expect(
          (await _service(
            futureTimestampMarket,
          ).analyze(symbol: 'SYNTH'))['status'],
          'unavailable',
        );
      },
    );

    test(
      'invalid symbols, unsupported calendars and unconfirmed raw returns are safe',
      () async {
        final market = _IndicatorMarket();
        final service = _service(market);
        expect(
          (await service.analyze(symbol: 'synth'))['status'],
          'unavailable',
        );
        expect(
          (await service.analyze(symbol: 'SYNTH&foo=1'))['status'],
          'unavailable',
        );
        expect(market.barCalls, 0);

        final unsupported = _IndicatorMarket(now: DateTime.utc(2031));
        expect(
          (await _service(unsupported).analyze(symbol: 'SYNTH'))['status'],
          'unavailable',
        );
        expect(unsupported.barCalls, 0);
      },
    );
  });

  group('indicator HTTP endpoint', () {
    test(
      'serves the symbol-only GET contract and rejects unsupported inputs',
      () async {
        final market = _IndicatorMarket();
        final server = await _startServer(market);
        final base = server.uri.resolve('/api/v1/market-data/indicators');

        final success = await http.get(
          base.replace(queryParameters: {'symbol': 'SYNTH'}),
        );
        expect(success.statusCode, HttpStatus.ok);
        final body = jsonDecode(success.body) as Map<String, dynamic>;
        expect(body.keys.toSet(), {
          'status',
          'data',
          'coverage',
          'sources',
          'limitations',
        });
        expect(body['coverage'], isA<String>());
        expect((body['coverage'] as String).trim(), isNotEmpty);
        expect(body['status'], 'ok');
        final snapshot = IndicatorSnapshot.parse(body, 'SYNTH');
        expect(snapshot.symbol, 'SYNTH');
        expect(snapshot.sources, hasLength(1));

        final extra = await http.get(
          Uri.parse(
            '${base.toString()}?symbol=SYNTH&url=https%3A%2F%2Fevil.test',
          ),
        );
        expect(extra.statusCode, HttpStatus.badRequest);
        final lowercase = await http.get(
          Uri.parse('${base.toString()}?symbol=synth'),
        );
        expect(lowercase.statusCode, HttpStatus.badRequest);
        final duplicate = await http.get(
          Uri.parse('${base.toString()}?symbol=SYNTH&symbol=OTHER'),
        );
        expect(duplicate.statusCode, HttpStatus.badRequest);
        final wrongMethod = await http.post(base, body: '{}');
        expect(wrongMethod.statusCode, HttpStatus.methodNotAllowed);
        expect(market.barCalls, 1);

        final emptyMarket = _IndicatorMarket()..overrideBars = [];
        final emptyServer = await _startServer(emptyMarket);
        final unavailable = await http.get(
          emptyServer.uri.resolve(
            '/api/v1/market-data/indicators?symbol=SYNTH',
          ),
        );
        expect(unavailable.statusCode, HttpStatus.ok);
        final unavailableBody =
            jsonDecode(unavailable.body) as Map<String, dynamic>;
        expect(unavailableBody['status'], 'unavailable');
        expect(unavailableBody['data'], isNull);
        expect(unavailableBody['coverage'], isA<String>());
        expect((unavailableBody['coverage'] as String).trim(), isNotEmpty);
        final unavailableSnapshot = IndicatorSnapshot.parse(
          unavailableBody,
          'SYNTH',
        );
        expect(unavailableSnapshot.symbol, 'SYNTH');
        expect(unavailableSnapshot.sources, isEmpty);
        expect(unavailableSnapshot.metrics, isEmpty);
      },
    );

    test('enforces the existing market-data display permission gate', () async {
      final deniedMarket = _IndicatorMarket();
      final denied = await _startServer(
        deniedMarket,
        policy: const LanDataPolicy(lanMode: true),
      );
      final response = await http.get(
        denied.uri.resolve('/api/v1/market-data/indicators?symbol=SYNTH'),
      );
      expect(response.statusCode, HttpStatus.serviceUnavailable);
      expect(deniedMarket.barCalls, 0);
    });
  });
}

Future<ATraderServer> _startServer(
  _IndicatorMarket market, {
  LanDataPolicy policy = const LanDataPolicy(lanMode: false),
}) async {
  final server = ATraderServer(
    bindAddress: '127.0.0.1',
    port: 0,
    selectedProvider: market.provider,
    marketDataClient: market,
    providerStatuses: const {},
    assistantConfiguration: AssistantConfiguration.fromEnvironment(const {}),
    assistantService: null,
    indicatorService: _service(market),
    lanDataPolicy: policy,
  );
  await server.start();
  addTearDown(() => server.close(force: true));
  return server;
}
