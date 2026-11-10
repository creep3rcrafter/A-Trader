import 'package:a_trade/market_data/local_market_data_service.dart';
import 'package:a_trade/market_data/market_data.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'market_data_fixtures.dart';

const localUrl = 'http://127.0.0.1:8765';
final invalidResponse = throwsA(
  isA<LocalMarketDataException>().having(
    (error) => error.message,
    'safe error',
    'Invalid local market-data response.',
  ),
);

void main() {
  test(
    'normalizes ticker and preserves quote provenance and missing bid/ask',
    () async {
      final service = LocalMarketDataService(
        client: MockClient((request) async {
          expect(request.url.host, '127.0.0.1');
          expect(request.url.path, '/api/v1/market-data/quote');
          expect(request.url.queryParameters, {'symbol': 'AAPL'});
          expect(request.followRedirects, isFalse);
          return fixtureResponse(quoteFixture());
        }),
      );
      final result = await service.quote(
        '$localUrl/ignored?secret=ignored',
        ' aapl ',
      );
      expect(result.quote.symbol, 'AAPL');
      expect(result.quote.lastPrice, 123.5);
      expect(result.quote.bidPrice, isNull);
      expect(result.quote.provider, MarketDataProvider.alpaca);
      expect(result.quote.feed, MarketDataFeed.iex);
      expect(result.quote.retrievedAt, DateTime.utc(2026, 10, 11, 20));
      expect(result.freshness, MarketDataFreshness.fresh);
    },
  );

  test('Twelve Data provenance does not claim verified freshness', () async {
    final service = LocalMarketDataService(
      client: MockClient(
        (_) async => fixtureResponse(quoteFixture(twelve: true)),
      ),
    );
    final result = await service.quote(localUrl, 'AAPL');
    expect(result.quote.provider, MarketDataProvider.twelveData);
    expect(result.freshness, MarketDataFreshness.unavailable);
    expect(
      result.quote.freshnessAt(
        now: result.quote.retrievedAt,
        maximumAge: const Duration(minutes: 1),
      ),
      MarketDataFreshness.unavailable,
    );
  });

  for (final twelve in [false, true]) {
    test(
      'daily bars preserve dates/timezone ($twelve), explicit raw last30 request',
      () async {
        final body = barsFixture(twelve: twelve);
        final service = LocalMarketDataService(
          client: MockClient((request) async {
            expect(request.url.path, '/api/v1/market-data/bars');
            final params = request.url.queryParameters;
            expect(params['adjustment'], 'raw');
            expect(params['symbol'], 'AAPL');
            expect(
              DateTime.parse(
                params['end']!,
              ).difference(DateTime.parse(params['start']!)),
              const Duration(days: 30),
            );
            return fixtureResponse(body);
          }),
        );
        final result = await service.dailyBars(localUrl, ' aapl ');
        final bar = result.bars.single;
        expect(bar.adjustment, PriceAdjustment.raw);
        expect(bar.volume, 1000);
        expect(bar.timestamp.isUtc, isTrue);
        expect(bar.tradingDate, twelve ? isNotNull : isNull);
        expect(bar.exchangeTimezone, twelve ? 'America/New_York' : null);
      },
    );
  }

  test('empty history is a valid unavailable result', () async {
    final body = barsFixture()..['count'] = 0;
    body['data'] = [];
    final service = LocalMarketDataService(
      client: MockClient((_) async => fixtureResponse(body)),
    );
    expect((await service.dailyBars(localUrl, 'AAPL')).bars, isEmpty);
  });

  for (final twelve in [false, true]) {
    for (final invalid in ['duplicate', 'reversed', 'future retrieval']) {
      test('chart rejects $invalid daily history ($twelve)', () async {
        final body = barsFixture(twelve: twelve);
        final data = body['data'] as List;
        final first = Map<String, Object?>.from(data.single as Map);
        if (invalid == 'future retrieval') {
          first['retrievedAt'] = DateTime.now()
              .toUtc()
              .add(const Duration(days: 1))
              .toIso8601String();
          body['data'] = [first];
        } else {
          final second = Map<String, Object?>.from(first);
          if (invalid == 'reversed') {
            final day = DateTime.parse(
              first['timestamp'] as String,
            ).subtract(const Duration(days: 1));
            second['timestamp'] = day.toIso8601String();
            if (twelve) {
              second['tradingDate'] = day.toIso8601String().substring(0, 10);
            }
          }
          body['data'] = [first, second];
          body['count'] = 2;
        }
        final service = LocalMarketDataService(
          client: MockClient((_) async => fixtureResponse(body)),
        );
        await expectLater(service.dailyBars(localUrl, 'AAPL'), invalidResponse);
      });
    }
  }

  test(
    'remote URLs, credentials and malformed tickers never issue requests',
    () async {
      var calls = 0;
      final service = LocalMarketDataService(
        client: MockClient((_) async {
          calls++;
          return fixtureResponse(quoteFixture());
        }),
      );
      for (final url in [
        'https://127.0.0.1:8765',
        'http://example.com',
        'http://127.0.0.1.evil.test',
        'http://user:secret@localhost',
        'http://192.168.68.66',
        'invalid',
        'http://[::2]:8765',
      ]) {
        await expectLater(
          service.quote(url, 'AAPL'),
          throwsA(isA<LocalMarketDataException>()),
        );
        await expectLater(
          service.dailyBars(url, 'AAPL'),
          throwsA(isA<LocalMarketDataException>()),
        );
      }
      for (final ticker in [
        '',
        'AAPL&apikey=secret',
        'TOO-LONG-SYMBOL-123',
        'A/B',
      ]) {
        await expectLater(
          service.quote(localUrl, ticker),
          throwsA(isA<LocalMarketDataException>()),
        );
      }
      expect(calls, 0);
    },
  );

  test('IPv6 loopback is supported', () async {
    final service = LocalMarketDataService(
      client: MockClient((_) async => fixtureResponse(quoteFixture())),
    );
    expect(
      (await service.quote('http://[::1]:8765', 'AAPL')).quote.symbol,
      'AAPL',
    );
  });

  final mutations = <String, void Function(Map<String, Object?>)>{
    'unknown provider': (json) => json['provider'] = 'ALPACA',
    'unknown feed': (json) => json['feed'] = 'bogus',
    'missing coverage': (json) => json.remove('coverage'),
    'wrong data shape': (json) => json['data'] = [],
    'wrong symbol': (json) => _quoteData(json)['symbol'] = 'MSFT',
    'unnormalized symbol': (json) => _quoteData(json)['symbol'] = 'aapl',
    'mismatched provider': (json) =>
        _quoteData(json)['provider'] = 'twelveData',
    'mismatched feed': (json) => _quoteData(json)['feed'] = 'sip',
    'numeric string': (json) => _quoteData(json)['lastPrice'] = '123.5',
    'negative price': (json) => _quoteData(json)['lastPrice'] = -1,
    'missing bid': (json) => _quoteData(json).remove('bidPrice'),
    'invalid bid': (json) => _quoteData(json)['bidPrice'] = {},
    'missing retrieved timestamp': (json) =>
        _quoteData(json).remove('retrievedAt'),
    'timezone missing': (json) =>
        _quoteData(json)['lastTradeAt'] = '2026-10-11T19:59:50',
    'overflow date': (json) =>
        _quoteData(json)['lastTradeAt'] = '2026-02-30T19:59:50Z',
    'overflow hour': (json) =>
        _quoteData(json)['lastTradeAt'] = '2026-10-11T25:59:50Z',
    'overflow offset': (json) =>
        _quoteData(json)['lastTradeAt'] = '2026-10-11T19:59:50+01:99',
    'unknown freshness': (json) => _quoteData(json)['freshness'] = 'live',
    'no source timestamp': (json) => _quoteData(json)['lastTradeAt'] = null,
    'bid without quote time': (json) => _quoteData(json)['bidPrice'] = 123,
  };
  for (final mutation in mutations.entries) {
    test('rejects malformed quote: ${mutation.key}', () async {
      final body = quoteFixture();
      mutation.value(body);
      final service = LocalMarketDataService(
        client: MockClient((_) async => fixtureResponse(body)),
      );
      await expectLater(service.quote(localUrl, 'AAPL'), invalidResponse);
    });
  }

  final barMutations = <String, void Function(Map<String, Object?>)>{
    'count mismatch': (json) => json['count'] = 2,
    'missing count': (json) => json.remove('count'),
    'wrong list': (json) => json['data'] = {},
    'wrong symbol': (json) => _barData(json)['symbol'] = 'MSFT',
    'fractional volume': (json) => _barData(json)['volume'] = 1.5,
    'negative volume': (json) => _barData(json)['volume'] = -1,
    'inconsistent OHLC': (json) => _barData(json)['high'] = 1,
    'unknown adjustment': (json) => _barData(json)['adjustment'] = 'bogus',
    'nonraw adjustment': (json) => _barData(json)['adjustment'] = 'split',
    'missing retrieval': (json) => _barData(json).remove('retrievedAt'),
    'missing optional field': (json) => _barData(json).remove('tradeCount'),
    'outside range': (json) =>
        _barData(json)['timestamp'] = '2000-01-01T00:00:00Z',
    'invalid trading date': (json) =>
        _barData(json)['tradingDate'] = '2026-02-30',
    'missing timezone': (json) => _barData(json).remove('exchangeTimezone'),
    'missing semantics': (json) => _barData(json).remove('timestampSemantics'),
    'untrusted timezone': (json) =>
        _barData(json)['exchangeTimezone'] = 'secret-token',
  };
  for (final mutation in barMutations.entries) {
    test('rejects malformed bars: ${mutation.key}', () async {
      final body = barsFixture(twelve: true);
      mutation.value(body);
      final service = LocalMarketDataService(
        client: MockClient((_) async => fixtureResponse(body)),
      );
      await expectLater(service.dailyBars(localUrl, 'AAPL'), invalidResponse);
    });
  }

  test('error bodies and transport exceptions cannot leak secrets', () async {
    for (final status in [400, 403, 404, 429, 500, 503, 302]) {
      final service = LocalMarketDataService(
        client: MockClient(
          (_) async =>
              fixtureResponse({'error': 'apikey=secret-token'}, status),
        ),
      );
      await expectLater(
        service.quote(localUrl, 'AAPL'),
        throwsA(
          isA<LocalMarketDataException>().having(
            (e) => e.message,
            'sanitized',
            isNot(contains('secret-token')),
          ),
        ),
      );
    }
    final service = LocalMarketDataService(
      client: MockClient(
        (_) async => throw http.ClientException('secret-token'),
      ),
    );
    await expectLater(
      service.quote(localUrl, 'AAPL'),
      throwsA(
        isA<LocalMarketDataException>().having(
          (e) => e.message,
          'sanitized',
          isNot(contains('secret-token')),
        ),
      ),
    );
  });

  test(
    '429 uses generic cooldown wording and preserves status for queue policy',
    () async {
      final service = LocalMarketDataService(
        client: MockClient(
          (_) async => fixtureResponse({
            'error': 'private provider/local limit details',
          }, 429),
        ),
      );
      await expectLater(
        service.dailyBars(localUrl, 'AAPL'),
        throwsA(
          isA<LocalMarketDataException>()
              .having((error) => error.statusCode, 'status', 429)
              .having(
                (error) => error.message,
                'safe generic cooldown',
                'Market-data request limit or provider cooldown reached. Wait at least 60 seconds before refreshing.',
              ),
        ),
      );
    },
  );

  for (final body in ['not-json secret-token', '[]', '{}', '{"error":{}}']) {
    test('malformed error shape is safe: $body', () async {
      final service = LocalMarketDataService(
        client: MockClient((_) async => http.Response(body, 500)),
      );
      await expectLater(service.quote(localUrl, 'AAPL'), invalidResponse);
    });
  }

  test('injected HTTP client remains caller owned', () async {
    final client = _TrackedClient();
    final service = LocalMarketDataService(client: client);
    service.close();
    expect(client.closed, isFalse);
    await service.quote(localUrl, 'AAPL');
    client.close();
    expect(client.closed, isTrue);
  });
}

Map<String, Object?> _quoteData(Map<String, Object?> body) =>
    body['data']! as Map<String, Object?>;
Map<String, Object?> _barData(Map<String, Object?> body) =>
    (body['data']! as List).single as Map<String, Object?>;

class _TrackedClient extends MockClient {
  _TrackedClient() : super((_) async => fixtureResponse(quoteFixture()));
  bool closed = false;
  @override
  void close() {
    closed = true;
    super.close();
  }
}
