import 'dart:convert';

import 'package:a_trade/market_data/indicator_snapshot.dart';
import 'package:a_trade/market_data/daily_indicators.dart';
import 'package:a_trade/market_data/market_data.dart';
import 'package:a_trade/market_data/local_market_data_service.dart';
import 'package:a_trade/providers/assistant_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'indicator_card_fixtures.dart';

Map<String, dynamic> fixture() =>
    jsonDecode(jsonEncode(indicatorCardFixture())) as Map<String, dynamic>;

void main() {
  test(
    'frontend accepts actual deterministic engine serialization, not just handwritten fixtures',
    () {
      final cutoff = DateTime.utc(2026, 10, 12, 8);
      final start = DateTime.utc(2026, 8, 1);
      final dates = [
        for (var i = 0; i < 45; i++)
          start.add(Duration(days: i)).toIso8601String().substring(0, 10),
      ];
      final bars = [
        for (var i = 0; i < dates.length; i++)
          MarketBar(
            symbol: 'SOFI',
            provider: MarketDataProvider.alpaca,
            feed: MarketDataFeed.iex,
            timestamp: DateTime.parse('${dates[i]}T04:00:00Z'),
            retrievedAt: cutoff.subtract(const Duration(seconds: 1)),
            adjustment: PriceAdjustment.raw,
            open: 10 + i.toDouble(),
            high: 12 + i.toDouble(),
            low: 9 + i.toDouble(),
            close: 11 + i.toDouble(),
            volume: 1000 + i * 10,
          ),
      ];
      final result = DailyIndicatorEngine.calculate(
        config: DailyIndicatorConfig(
          symbol: 'SOFI',
          provider: MarketDataProvider.alpaca,
          feed: MarketDataFeed.iex,
          adjustment: PriceAdjustment.raw,
          analysisCutoff: cutoff,
          latestCompletedSessionDate: dates.last,
          maximumRetrievalAge: const Duration(minutes: 5),
          lookback: 20,
          expectedSessionDates: dates,
        ),
        bars: bars,
      );
      final payload =
          jsonDecode(
                jsonEncode({
                  'status': 'ok',
                  'data': result.toJson(),
                  'limitations': [
                    'Synthetic daily engine fixture, not live data.',
                  ],
                  'sources': [
                    {
                      'url':
                          'https://data.alpaca.markets/v2/stocks/SOFI/bars?feed=iex',
                      'publishedAt': dates.last,
                      'retrievedAt': bars.last.retrievedAt.toIso8601String(),
                    },
                  ],
                }),
              )
              as Map<String, dynamic>;
      final parsed = IndicatorSnapshot.parse(payload, 'SOFI');
      expect(parsed.metrics['relativeStrengthIndex']!.value, 100);
      expect(parsed.metrics['exponentialMovingAverage']!.isAvailable, isTrue);
      expect(parsed.metrics['closeReturn']!.isAvailable, isFalse);
    },
  );

  test(
    'indicator request uses local route, normalized ticker and no secrets',
    () async {
      final service = LocalMarketDataService(
        client: MockClient((request) async {
          expect(request.method, 'GET');
          expect(request.url.path, '/api/v1/market-data/indicators');
          expect(request.url.queryParameters, {'symbol': 'SOFI'});
          expect(request.followRedirects, isFalse);
          expect(request.headers.containsKey('authorization'), isFalse);
          return http.Response(jsonEncode(indicatorCardFixture()), 200);
        }),
      );
      final result = await service.indicators(
        'http://127.0.0.1:8765',
        ' sofi ',
      );
      expect(result.metrics['relativeStrengthIndex']!.value, 62.5);
      expect(result.metrics['closeReturn']!.isAvailable, isFalse);
      expect(result.sources.single.date, '2026-10-09');
      expect(() => result.metrics.clear(), throwsUnsupportedError);
      expect(() => result.limitations.add('bad'), throwsUnsupportedError);
    },
  );

  test(
    'unavailable indicators preserve explicit limitations without fabricated sources',
    () {
      final result = IndicatorSnapshot.parse({
        'status': 'unavailable',
        'data': null,
        'sources': [],
        'limitations': ['Provider unavailable; no fallback.'],
      }, 'SOFI');
      expect(result.metrics, isEmpty);
      expect(result.sources, isEmpty);
      expect(result.limitations.single, contains('unavailable'));
    },
  );

  final mutations = <String, void Function(Map<String, dynamic>)>{
    'other symbol': (json) => json['data']['symbol'] = 'OTHER',
    'paid feed': (json) => json['data']['feed'] = 'sip',
    'unknown formula': (json) =>
        json['data']['formulaVersion'] = 'fabricated-v999',
    'raw return': (json) {
      json['data']['closeReturn']['availability'] = 'available';
      json['data']['closeReturn']['unavailableReason'] = null;
      json['data']['closeReturn']['value'] = 0.85;
    },
    'invalid RSI': (json) =>
        json['data']['relativeStrengthIndex']['value'] = 101,
    'wrong units': (json) =>
        json['data']['relativeStrengthIndex']['units'] = 'percent',
    'wrong warmup': (json) =>
        json['data']['relativeStrengthIndex']['requiredSampleCount'] = 1,
    'inconsistent observed window': (json) {
      json['data']['simpleMovingAverage']['observedSampleCount'] = 21;
      json['data']['simpleMovingAverage']['retrievalTimes'].add(
        '2026-10-12T08:00:00Z',
      );
    },
    'infinite price': (json) =>
        json['data']['simpleMovingAverage']['value'] = double.infinity,
    'missing samples': (json) =>
        json['data']['simpleMovingAverage']['observedSampleCount'] = 1,
    'stale available': (json) =>
        json['data']['simpleMovingAverage']['staleSampleCount'] = 1,
    'invented source': (json) =>
        json['sources'][0]['url'] = 'https://evil.test/bars',
    'other ticker source': (json) => json['sources'][0]['url'] =
        'https://data.alpaca.markets/v2/stocks/OTHER/bars?feed=iex',
    'credential source': (json) => json['sources'][0]['url'] =
        'https://data.alpaca.markets/v2/stocks/SOFI/bars?feed=iex&apikey=secret',
    'bad fraction': (json) =>
        json['data']['sessionColors']['value']['greenFraction'] = 0.85,
    'wrong direction': (json) =>
        json['data']['smaTrend']['value']['direction'] = 'falling',
    'invented unavailability': (json) =>
        json['data']['closeReturn']['unavailableReason'] = 'noReason',
    'future source': (json) =>
        json['sources'][0]['retrievedAt'] = '2099-01-01T00:00:00Z',
  };
  for (final entry in mutations.entries) {
    test('rejects indicator response: ${entry.key}', () {
      final json = fixture();
      entry.value(json);
      expect(
        () => IndicatorSnapshot.parse(json, 'SOFI'),
        throwsFormatException,
      );
    });
  }

  test('indicator failures sanitize arbitrary backend messages', () async {
    final service = LocalMarketDataService(
      client: MockClient(
        (_) async => http.Response('{"error":"private server key"}', 429),
      ),
    );
    await expectLater(
      service.indicators('http://localhost:8765', 'SOFI'),
      throwsA(
        isA<LocalMarketDataException>().having(
          (e) => e.message,
          'safe quota error',
          allOf(contains('quota'), isNot(contains('private'))),
        ),
      ),
    );
  });

  test(
    'indicator requests reject remote backend URLs before network access',
    () async {
      var calls = 0;
      final service = LocalMarketDataService(
        client: MockClient((_) async {
          calls++;
          return http.Response('{}', 200);
        }),
      );
      await expectLater(
        service.indicators('https://untrusted.example', 'SOFI'),
        throwsA(isA<LocalMarketDataException>()),
      );
      expect(calls, 0);
    },
  );

  test(
    'research frontend accepts deterministic indicator allowlisted tool',
    () async {
      final service = AssistantService(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'explanation':
                  'Code-computed fixture indicators are informational.',
              'provider': 'lmstudio',
              'model': 'fixture-local',
              'toolsUsed': ['get_technical_indicators'],
              'limitations': [],
              'sources': [
                {
                  'title': 'Synthetic bars',
                  'url':
                      'https://data.alpaca.markets/v2/stocks/SOFI/bars?feed=iex',
                  'publishedAt': '2026-10-09',
                  'retrievedAt': '2026-10-12T08:00:00Z',
                },
              ],
            }),
            200,
          ),
        ),
      );
      final result = await service.research(
        'http://localhost:8765',
        'SOFI',
        'Interpret indicators.',
        holdingDays: 10,
      );
      expect(result.toolsUsed, ['get_technical_indicators']);
    },
  );
}
