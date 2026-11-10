import 'dart:convert';

import 'package:a_trade/market_data/alpaca_market_data_client.dart';
import 'package:a_trade/market_data/local_market_data_service.dart';
import 'package:a_trade/market_data/market_data.dart';
import 'package:a_trade/providers/assistant_service.dart' as frontend;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// ignore: avoid_relative_lib_imports
import '../backend/lib/assistant.dart';
// ignore: avoid_relative_lib_imports
import '../backend/lib/daily_indicator_service.dart';
// ignore: avoid_relative_lib_imports
import '../backend/lib/lan_data_policy.dart';
// ignore: avoid_relative_lib_imports
import '../backend/lib/research.dart';
// ignore: avoid_relative_lib_imports
import '../backend/lib/schwab_market_data.dart';
// ignore: avoid_relative_lib_imports
import '../backend/lib/schwab_oauth.dart';
// ignore: avoid_relative_lib_imports
import '../backend/lib/sec_filings.dart';
// ignore: avoid_relative_lib_imports
import '../backend/lib/server.dart';

final now = DateTime.utc(2026, 11, 5, 20);
final candleTime = DateTime.utc(2026, 11, 4, 6);

class FixtureStore implements SchwabTokenStore {
  int reads = 0;
  SchwabTokens? tokens = SchwabTokens(
    accessToken: 'synthetic-access',
    refreshToken: 'synthetic-refresh',
    expiresAt: now.add(const Duration(hours: 1)),
  );
  @override
  Future<SchwabTokens?> read() async {
    reads++;
    return tokens;
  }

  @override
  Future<void> write(SchwabTokens value) async => tokens = value;
}

Map<String, dynamic> quoteFixture() => {
  'SYNTH': <String, dynamic>{
    'assetMainType': 'EQUITY',
    'symbol': 'SYNTH',
    'realtime': true,
    'quoteType': 'NBBO',
    'quote': <String, dynamic>{
      'lastPrice': 101.5,
      'bidPrice': 101,
      'askPrice': 102,
      'tradeTime': now
          .subtract(const Duration(seconds: 10))
          .millisecondsSinceEpoch,
      'quoteTime': now
          .subtract(const Duration(seconds: 5))
          .millisecondsSinceEpoch,
      'totalVolume': 150000,
    },
  },
};

Map<String, dynamic> barFixture() => {
  'symbol': 'SYNTH',
  'empty': false,
  'candles': <dynamic>[
    <String, dynamic>{
      'datetime': candleTime.millisecondsSinceEpoch,
      'datetimeISO8601': '2026-11-04',
      'open': 100,
      'high': 103,
      'low': 99,
      'close': 101.5,
      'volume': 150000,
    },
  ],
};

SchwabMarketDataClient adapter(
  Future<http.Response> Function(http.Request) handler, {
  FixtureStore? store,
  DateTime Function()? clock,
  Duration timeout = const Duration(seconds: 15),
}) {
  final oauth = SchwabOAuthClient(
    clientId: 'fixture-id',
    clientSecret: 'fixture-secret',
    store: store ?? FixtureStore(),
    clock: clock ?? () => now,
    httpClient: MockClient(
      (_) async => throw StateError('Unexpected token request'),
    ),
  );
  final client = SchwabMarketDataClient(
    oauth: oauth,
    client: MockClient(handler),
    clock: clock ?? () => now,
    timeout: timeout,
  );
  addTearDown(client.close);
  addTearDown(oauth.close);
  return client;
}

Future<List<MarketBar>> history(
  SchwabMarketDataClient client, {
  DateTime? start,
  DateTime? end,
  PriceAdjustment adjustment = PriceAdjustment.raw,
}) => client.dailyBars(
  'SYNTH',
  start: start ?? now.subtract(const Duration(days: 30)),
  end: end ?? now,
  adjustment: adjustment,
);

void main() {
  test(
    'fixed quote endpoint, server bearer only, no redirects or invented metrics',
    () async {
      final client = adapter((request) async {
        expect(
          request.url,
          Uri.https('api.schwabapi.com', '/marketdata/v1/quotes', {
            'symbols': 'SYNTH',
            'fields': 'quote',
            'indicative': 'false',
          }),
        );
        expect(request.method, 'GET');
        expect(request.followRedirects, isFalse);
        expect(request.headers['authorization'], 'Bearer synthetic-access');
        expect(request.url.toString(), isNot(contains('synthetic-access')));
        return http.Response(jsonEncode(quoteFixture()), 200);
      });
      final quote = (await client.latestQuote(' synth '))!;
      expect(quote.provider, MarketDataProvider.schwab);
      expect(quote.feed, MarketDataFeed.schwabEquity);
      expect(quote.totalVolume, 150000);
      expect(quote.lastPrice, 101.5);
      expect(quote.toJson()['quoteType'], 'NBBO');
      expect(quote.toJson(), isNot(contains('previousClose')));
      expect(
        quote.freshnessAt(now: now, maximumAge: const Duration(minutes: 1)),
        MarketDataFreshness.fresh,
      );
    },
  );

  for (final entry in <(Object?, Object?, MarketDataFreshness)>[
    (false, 'NFL', MarketDataFreshness.delayed),
    (null, null, MarketDataFreshness.unavailable),
    (true, 'NFL', MarketDataFreshness.unavailable),
    (true, 'FUTURE_TYPE', MarketDataFreshness.unavailable),
    (true, null, MarketDataFreshness.unavailable),
  ]) {
    test(
      'honest realtime/quoteType freshness ${entry.$1}/${entry.$2}',
      () async {
        final fixture = quoteFixture();
        fixture['SYNTH']['realtime'] = entry.$1;
        fixture['SYNTH']['quoteType'] = entry.$2;
        final client = adapter(
          (_) async => http.Response(jsonEncode(fixture), 200),
        );
        final quote = (await client.latestQuote('SYNTH'))!;
        expect(
          quote.freshnessAt(now: now, maximumAge: const Duration(minutes: 1)),
          entry.$3,
        );
      },
    );
  }
  test('old NBBO timestamp is stale, not current', () async {
    final fixture = quoteFixture();
    fixture['SYNTH']['quote']['quoteTime'] = now
        .subtract(const Duration(days: 1))
        .millisecondsSinceEpoch;
    fixture['SYNTH']['quote']['tradeTime'] = now
        .subtract(const Duration(days: 1))
        .millisecondsSinceEpoch;
    final client = adapter(
      (_) async => http.Response(jsonEncode(fixture), 200),
    );
    expect(
      (await client.latestQuote(
        'SYNTH',
      ))!.freshnessAt(now: now, maximumAge: const Duration(minutes: 1)),
      MarketDataFreshness.stale,
    );
  });

  final badQuotes = <String, void Function(Map<String, dynamic>)>{
    'symbol mismatch': (f) => f['SYNTH']['symbol'] = 'OTHER',
    'asset mismatch': (f) => f['SYNTH']['assetMainType'] = 'OPTION',
    'future timestamp': (f) => f['SYNTH']['quote']['quoteTime'] = now
        .add(const Duration(seconds: 1))
        .millisecondsSinceEpoch,
    'missing trade timestamp': (f) => f['SYNTH']['quote'].remove('tradeTime'),
    'crossed market': (f) => f['SYNTH']['quote']['bidPrice'] = 105,
    'negative volume': (f) => f['SYNTH']['quote']['totalVolume'] = -1,
    'fractional volume': (f) => f['SYNTH']['quote']['totalVolume'] = 1.5,
    'invalid price': (f) => f['SYNTH']['quote']['lastPrice'] = -1,
    'realtime wrong type': (f) => f['SYNTH']['realtime'] = 'true',
  };
  for (final entry in badQuotes.entries) {
    test('reject quote ${entry.key} without fallback', () async {
      final fixture = quoteFixture();
      entry.value(fixture);
      var requests = 0;
      final client = adapter((_) async {
        requests++;
        return http.Response(jsonEncode(fixture), 200);
      });
      await expectLater(
        client.latestQuote('SYNTH'),
        throwsA(isA<MarketDataException>()),
      );
      expect(requests, 1);
    });
  }

  test(
    'daily query uses supported enum pair and unknown output adjustment',
    () async {
      final client = adapter((request) async {
        expect(request.url.host, 'api.schwabapi.com');
        expect(request.url.path, '/marketdata/v1/pricehistory');
        expect(request.url.queryParameters, {
          'symbol': 'SYNTH',
          'periodType': 'year',
          'frequencyType': 'daily',
          'frequency': '1',
          'startDate':
              '${now.subtract(const Duration(days: 30)).millisecondsSinceEpoch}',
          'endDate': '${now.millisecondsSinceEpoch}',
          'needExtendedHoursData': 'false',
          'needPreviousClose': 'false',
        });
        return http.Response(jsonEncode(barFixture()), 200);
      });
      final bar = (await history(client)).single;
      expect(bar.adjustment, PriceAdjustment.unknown);
      expect(bar.tradingDate, '2026-11-04');
      expect(bar.exchangeTimezone, isNull);
      expect(bar.toJson()['timestampSemantics'], 'providerTradingDate');
    },
  );
  test(
    'daily date absent is explicitly a UTC proxy, not exchange timezone',
    () async {
      final fixture = barFixture();
      fixture['candles'][0].remove('datetimeISO8601');
      final client = adapter(
        (_) async => http.Response(jsonEncode(fixture), 200),
      );
      final bar = (await history(client)).single;
      expect(bar.tradingDate, isNull);
      expect(bar.toJson()['timestampSemantics'], 'utcDateProxy');
    },
  );
  test(
    '120 inclusive calendar day bound and adjusted/future/reversed requests fail before auth',
    () async {
      final store = FixtureStore();
      final client = adapter(
        (_) async => http.Response(jsonEncode(barFixture()), 200),
        store: store,
      );
      await expectLater(
        history(client, start: now.subtract(const Duration(days: 120))),
        throwsFormatException,
      );
      await expectLater(
        history(
          client,
          start: now
              .subtract(const Duration(days: 120))
              .add(const Duration(hours: 1)),
        ),
        throwsFormatException,
      );
      await expectLater(
        history(client, start: now.add(const Duration(days: 1))),
        throwsFormatException,
      );
      await expectLater(
        history(client, end: now.add(const Duration(seconds: 1))),
        throwsFormatException,
      );
      await expectLater(
        history(client, adjustment: PriceAdjustment.all),
        throwsFormatException,
      );
      expect(store.reads, 0);
      expect(
        (await history(
          client,
          start: now.subtract(const Duration(days: 119)),
        )).length,
        1,
      );
    },
  );
  final badBars = <String, void Function(Map<String, dynamic>)>{
    'mismatched symbol': (f) => f['symbol'] = 'OTHER',
    'invalid OHLC': (f) => f['candles'][0]['low'] = 102,
    'future candle': (f) => f['candles'][0]['datetime'] = now
        .add(const Duration(days: 1))
        .millisecondsSinceEpoch,
    'date inconsistent with timestamp': (f) => f['candles'][0]['datetime'] = now
        .subtract(const Duration(days: 31))
        .millisecondsSinceEpoch,
    'invalid date': (f) => f['candles'][0]['datetimeISO8601'] = '2026-02-30',
    'duplicate candle': (f) =>
        f['candles'].add(Map<String, dynamic>.from(f['candles'][0])),
    'unordered candle': (f) => f['candles'].add({
      ...f['candles'][0],
      'datetime': candleTime
          .subtract(const Duration(days: 1))
          .millisecondsSinceEpoch,
    }),
    'negative volume': (f) => f['candles'][0]['volume'] = -1,
    'false empty marker': (f) => f['empty'] = true,
    'excess records': (f) => f['candles'] = List.filled(121, f['candles'][0]),
  };
  for (final entry in badBars.entries) {
    test('reject history ${entry.key}', () async {
      final fixture = barFixture();
      entry.value(fixture);
      final client = adapter(
        (_) async => http.Response(jsonEncode(fixture), 200),
      );
      await expectLater(history(client), throwsA(isA<MarketDataException>()));
    });
  }
  test('empty history is explicit empty, never fabricated bars', () async {
    final client = adapter(
      (_) async => http.Response(
        jsonEncode({'symbol': 'SYNTH', 'empty': true, 'candles': []}),
        200,
      ),
    );
    expect(await history(client), isEmpty);
  });
  test(
    'trims validated boundary candles including observed Schwab start overrun',
    () async {
      final first = DateTime.utc(2026, 10, 6);
      final last = DateTime.utc(2026, 11, 4);
      Map<String, dynamic> candle(DateTime time) => {
        ...barFixture()['candles'][0] as Map<String, dynamic>,
        'datetime': time.millisecondsSinceEpoch,
      }..remove('datetimeISO8601');
      final fixture = {
        'symbol': 'SYNTH',
        'empty': false,
        'candles': [
          candle(DateTime.utc(2026, 10, 5, 5)),
          candle(first),
          candle(DateTime.utc(2026, 10, 7, 5)),
          candle(last),
          candle(DateTime.utc(2026, 11, 5, 6)),
        ],
      };
      final client = adapter(
        (_) async => http.Response(jsonEncode(fixture), 200),
      );
      final bars = await history(client, start: first, end: last);
      expect(bars.map((bar) => bar.timestamp), [
        first,
        DateTime.utc(2026, 10, 7, 5),
        last,
      ]);
      expect(
        bars.every((bar) => bar.timestampSemantics == 'utcDateProxy'),
        isTrue,
      );
    },
  );
  test('valid out-of-window history yields empty results', () async {
    final client = adapter(
      (_) async => http.Response(jsonEncode(barFixture()), 200),
    );
    expect(await history(client, end: DateTime.utc(2026, 11, 3)), isEmpty);
  });
  for (final defect in ['OHLC', 'volume', 'duplicate', 'order', 'future']) {
    test('out-of-window $defect still rejects the complete response', () async {
      final fixture = barFixture();
      final outside = <String, dynamic>{
        ...fixture['candles'][0] as Map<String, dynamic>,
        'datetime': DateTime.utc(2026, 10, 5, 5).millisecondsSinceEpoch,
        'datetimeISO8601': '2026-10-05',
      };
      fixture['candles'].insert(0, outside);
      switch (defect) {
        case 'OHLC':
          outside['low'] = 999;
        case 'volume':
          outside['volume'] = -1;
        case 'duplicate':
          fixture['candles'].insert(0, Map<String, dynamic>.from(outside));
        case 'order':
          fixture['candles'] = (fixture['candles'] as List).reversed.toList();
        case 'future':
          fixture['candles'].add({
            ...outside,
            'datetime': now.add(const Duration(days: 1)).millisecondsSinceEpoch,
            'datetimeISO8601': '2026-11-06',
          });
      }
      final client = adapter(
        (_) async => http.Response(jsonEncode(fixture), 200),
      );
      await expectLater(history(client), throwsA(isA<MarketDataException>()));
    });
  }
  for (final status in [301, 401, 403, 413, 429, 500]) {
    test(
      'sanitized HTTP $status, no retry and cooldown/reauth when relevant',
      () async {
        var requests = 0;
        var time = now;
        final client = adapter((_) async {
          requests++;
          return http.Response('PRIVATE PROVIDER BODY', status);
        }, clock: () => time);
        await expectLater(
          client.latestQuote('SYNTH'),
          throwsA(
            isA<MarketDataException>().having(
              (e) => e.message,
              'no body leak',
              isNot(contains('PRIVATE')),
            ),
          ),
        );
        expect(requests, 1);
        if ([401, 403, 429].contains(status)) {
          await expectLater(
            client.latestQuote('SYNTH'),
            throwsA(isA<MarketDataException>()),
          );
          expect(requests, 1);
          time = now.add(const Duration(minutes: 2));
          await expectLater(
            client.latestQuote('SYNTH'),
            throwsA(isA<MarketDataException>()),
          );
          expect(requests, status == 401 ? 1 : 2);
        }
      },
    );
  }
  test('local 10/minute cap includes concurrent requests', () async {
    var calls = 0;
    final client = adapter((_) async {
      calls++;
      return http.Response(jsonEncode(quoteFixture()), 200);
    });
    await Future.wait(List.generate(10, (_) => client.latestQuote('SYNTH')));
    await expectLater(
      client.latestQuote('SYNTH'),
      throwsA(
        isA<MarketDataException>().having(
          (e) => e.statusCode,
          'local cap',
          429,
        ),
      ),
    );
    expect(calls, 10);
  });
  for (final body in ['not-json', '[1]', 'x' * (1024 * 1024 + 1)]) {
    test(
      'malformed or oversized quote body ${body.length} is rejected',
      () async {
        final client = adapter((_) async => http.Response(body, 200));
        await expectLater(
          client.latestQuote('SYNTH'),
          throwsA(isA<MarketDataException>()),
        );
      },
    );
  }
  test('transport and timeout errors are safe', () async {
    final transport = adapter(
      (_) async => throw http.ClientException('PRIVATE'),
    );
    await expectLater(
      transport.latestQuote('SYNTH'),
      throwsA(
        isA<MarketDataException>().having(
          (e) => e.message,
          'sanitized',
          isNot(contains('PRIVATE')),
        ),
      ),
    );
    final timeout = adapter((_) async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      return http.Response('{}', 200);
    }, timeout: const Duration(milliseconds: 1));
    await expectLater(
      timeout.latestQuote('SYNTH'),
      throwsA(isA<MarketDataException>()),
    );
  });
  test('missing authorization never sends provider quote', () async {
    final store = FixtureStore()..tokens = null;
    var calls = 0;
    final client = adapter((_) async {
      calls++;
      return http.Response('{}', 200);
    }, store: store);
    await expectLater(
      client.latestQuote('SYNTH'),
      throwsA(isA<MarketDataException>()),
    );
    expect(calls, 0);
  });
  test('invalid symbols never read tokens or send requests', () async {
    final store = FixtureStore();
    final client = adapter(
      (_) async => throw StateError('Unexpected HTTP'),
      store: store,
    );
    for (final symbol in ['', 'AAPL,MSFT', '../orders', 'A' * 16]) {
      await expectLater(client.latestQuote(symbol), throwsFormatException);
      await expectLater(
        client.dailyBars(
          symbol,
          start: now.subtract(const Duration(days: 1)),
          end: now,
        ),
        throwsFormatException,
      );
    }
    expect(store.reads, 0);
  });
  test('oversized history is rejected before JSON decoding', () async {
    final client = adapter(
      (_) async => http.Response('x' * (2 * 1024 * 1024 + 1), 200),
    );
    await expectLater(history(client), throwsA(isA<MarketDataException>()));
  });
  for (final url in [
    'https://api.schwabapi.com/marketdata/v1/quotes?symbols=SYNTH',
    'https://api.schwabapi.com/marketdata/v1/pricehistory?symbol=SYNTH',
    'https://api.schwabapi.com/marketdata/v1/quotes?symbols=OTHER',
    'https://api.schwabapi.com/marketdata/v1/quotes?symbols=SYNTH&symbols=OTHER',
    'https://api.schwabapi.com/marketdata/v1/quotes?symbols=SYNTH&access_token=PRIVATE',
    'https://api.schwabapi.com/trader/v1/accounts?symbol=SYNTH',
    'https://api.schwabapi.com:444/marketdata/v1/quotes?symbols=SYNTH',
    'https://api.schwabapi.com.evil.test/marketdata/v1/quotes?symbols=SYNTH',
  ]) {
    test('browser exact Schwab research source allowlist: $url', () async {
      final service = frontend.AssistantService(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'explanation': 'Synthetic evidence, not a forecast.',
              'provider': 'lmstudio',
              'model': 'fixture-model',
              'toolsUsed': ['get_market_quote'],
              'limitations': ['Synthetic only'],
              'sources': [
                {
                  'url': url,
                  'title': 'Synthetic Schwab source',
                  'publishedAt': now.toIso8601String(),
                  'retrievedAt': now.toIso8601String(),
                },
              ],
            }),
            200,
          ),
        ),
      );
      addTearDown(service.close);
      final result = service.research(
        'http://127.0.0.1:8765',
        'SYNTH',
        'Explain source limitations.',
        holdingDays: 10,
      );
      if (url ==
              'https://api.schwabapi.com/marketdata/v1/quotes?symbols=SYNTH' ||
          url ==
              'https://api.schwabapi.com/marketdata/v1/pricehistory?symbol=SYNTH') {
        expect((await result).sources.single.url.toString(), url);
      } else {
        await expectLater(result, throwsA(isA<frontend.AssistantException>()));
      }
    });
  }
  for (final mutation in [
    'feed',
    'symbol',
    'freshness',
    'volume',
    'realtime',
  ]) {
    test('browser refuses invalid Schwab quote $mutation', () async {
      final client = adapter(
        (_) async => http.Response(jsonEncode(quoteFixture()), 200),
      );
      final quote = (await client.latestQuote('SYNTH'))!;
      final data = quote.toJson(
        now: now,
        maximumAge: const Duration(minutes: 1),
      );
      switch (mutation) {
        case 'feed':
          data['feed'] = 'sip';
        case 'symbol':
          data['symbol'] = 'OTHER';
        case 'freshness':
          data['realtime'] = null;
        case 'volume':
          data['totalVolume'] = -1;
        case 'realtime':
          data['realtime'] = 'true';
      }
      final browser = LocalMarketDataService(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'provider': 'schwab',
              'feed': 'schwabEquity',
              'coverage': schwabCoverage,
              'data': data,
            }),
            200,
          ),
        ),
      );
      addTearDown(browser.close);
      await expectLater(
        browser.quote('http://127.0.0.1:8765', 'SYNTH'),
        throwsA(isA<LocalMarketDataException>()),
      );
    });
  }
  test(
    'indicators refuse adjustment unknown before any history fetch',
    () async {
      var calls = 0;
      final client = adapter((_) async {
        calls++;
        return http.Response('{}', 200);
      });
      final result = await DailyIndicatorService(
        marketData: client,
        provider: MarketDataProvider.schwab,
      ).analyze(symbol: 'SYNTH');
      expect(result['status'], 'unavailable');
      expect(jsonEncode(result), contains('adjustment'));
      expect(calls, 0);
    },
  );
  test(
    'LAN rights are separate from OAuth, personal terms and model forwarding',
    () {
      expect(
        LanDataPolicy.fromEnvironment({}).permits(MarketDataProvider.schwab),
        isTrue,
      );
      final policy = LanDataPolicy.fromEnvironment({
        'A_TRADER_AUTH_ENABLED': 'true',
        'SCHWAB_MARKET_DATA_TERMS_CONFIRMED': 'true',
        'A_TRADER_MODEL_FORWARDING_TERMS_CONFIRMED': 'true',
      });
      expect(policy.permits(MarketDataProvider.schwab), isFalse);
      expect(
        LanDataPolicy.fromEnvironment({
          'A_TRADER_AUTH_ENABLED': 'true',
          'SCHWAB_LAN_DISPLAY_TERMS_CONFIRMED': 'true',
        }).permits(MarketDataProvider.schwab),
        isTrue,
      );
    },
  );
  test(
    'research quote and history use exact token-free symbol URLs and unknown adjustment',
    () async {
      final client = adapter(
        (request) async => http.Response(
          jsonEncode(
            request.url.path.endsWith('quotes') ? quoteFixture() : barFixture(),
          ),
          200,
        ),
      );
      final tools = ResearchTools(
        marketData: client,
        provider: MarketDataProvider.schwab,
        secFilings: SecFilingsClient(permitted: false, userAgent: ''),
        clock: () => now,
      );
      final quote = await tools.execute(
        'get_market_quote',
        {'symbol': 'SYNTH'},
        symbol: 'SYNTH',
        lookbackDays: 30,
      );
      expect(quote['status'], 'ok');
      expect(
        (quote['sources'] as List).first['url'],
        'https://api.schwabapi.com/marketdata/v1/quotes?symbols=SYNTH',
      );
      final bars = await tools.execute(
        'get_daily_bars',
        {'symbol': 'SYNTH'},
        symbol: 'SYNTH',
        lookbackDays: 30,
      );
      expect(bars['status'], 'ok');
      expect((bars['data'] as List).single['adjustment'], 'unknown');
      expect(
        (bars['sources'] as List).single['url'],
        'https://api.schwabapi.com/marketdata/v1/pricehistory?symbol=SYNTH',
      );
      expect(
        jsonEncode(bars['limitations']),
        contains('Do not compute economic returns'),
      );
    },
  );
  test(
    'server to browser quote/history contract preserves Schwab metadata',
    () async {
      var providerCalls = 0;
      final client = adapter((request) async {
        providerCalls++;
        return http.Response(
          jsonEncode(
            request.url.path.endsWith('quotes') ? quoteFixture() : barFixture(),
          ),
          200,
        );
      });
      final server = ATraderServer(
        bindAddress: '127.0.0.1',
        port: 0,
        selectedProvider: MarketDataProvider.schwab,
        marketDataClient: client,
        providerStatuses: const {},
        assistantConfiguration: AssistantConfiguration.fromEnvironment({}),
        assistantService: null,
      );
      await server.start();
      addTearDown(server.close);
      expect(providerCalls, 0);
      final health = await http.get(server.uri.resolve('/health'));
      expect(health.statusCode, 200);
      expect(providerCalls, 0);
      final browser = LocalMarketDataService();
      addTearDown(browser.close);
      final quote = await browser.quote(server.uri.toString(), 'SYNTH');
      expect(quote.quote.totalVolume, 150000);
      expect(quote.quote.realtime, isTrue);
      expect(quote.quote.quoteType, 'NBBO');
      final bars = await browser.dailyBars(server.uri.toString(), 'SYNTH');
      expect(bars.bars.single.adjustment, PriceAdjustment.unknown);
      expect(bars.bars.single.timestampSemantics, 'providerTradingDate');
      expect(bars.bars.single.exchangeTimezone, isNull);
      expect(providerCalls, 2);
    },
  );
  for (final disabled in [true, false]) {
    test(
      'server Schwab ${disabled ? 'unconfigured' : 'LAN denied'} never falls back',
      () async {
        var calls = 0;
        final client = adapter((_) async {
          calls++;
          return http.Response(jsonEncode(quoteFixture()), 200);
        });
        final server = ATraderServer(
          bindAddress: '127.0.0.1',
          port: 0,
          selectedProvider: MarketDataProvider.schwab,
          marketDataClient: disabled ? null : client,
          providerStatuses: const {},
          assistantConfiguration: AssistantConfiguration.fromEnvironment({}),
          assistantService: null,
          lanDataPolicy: const LanDataPolicy(lanMode: true),
        );
        await server.start();
        addTearDown(server.close);
        for (final path in [
          '/api/v1/market-data/quote?symbol=SYNTH',
          '/api/v1/market-data/bars?symbol=SYNTH&start=2026-11-01T00:00:00Z&end=2026-11-04T00:00:00Z',
        ]) {
          final response = await http.get(server.uri.resolve(path));
          expect(response.statusCode, 503);
          expect(response.body, isNot(contains('synthetic-access')));
        }
        expect(calls, 0);
      },
    );
  }
}
