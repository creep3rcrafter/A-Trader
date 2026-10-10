import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:a_trade/market_data/alpaca_market_data_client.dart';
import 'package:a_trade/market_data/market_data.dart';

void main() {
  final retrievedAt = DateTime.parse('2026-10-09T20:00:01Z');

  test(
    'fetches IEX trade and quote with headers and caches duplicate reads',
    () async {
      final transport = _FakeTransport(
        {
          '/v2/stocks/AAPL/trades/latest': {
            'symbol': 'AAPL',
            'trade': {'p': 171.29, 't': '2026-10-09T20:00:00Z'},
          },
          '/v2/stocks/AAPL/quotes/latest': {
            'symbol': 'AAPL',
            'quote': {'bp': 171.20, 'ap': 171.30, 't': '2026-10-09T19:59:59Z'},
          },
        },
        responseHeaders: {
          'x-ratelimit-limit': '200',
          'x-ratelimit-remaining': '198',
          'x-ratelimit-reset': '1791576060',
        },
      );
      final client = AlpacaMarketDataClient(
        apiKeyId: 'test-key-id',
        apiSecretKey: 'test-secret',
        transport: transport,
        clock: () => retrievedAt,
        allowCaching: true,
      );

      final quote = await client.latestQuote(' aapl ');
      final cachedQuote = await client.latestQuote('AAPL');

      expect(quote?.lastPrice, 171.29);
      expect(quote?.bidPrice, 171.20);
      expect(cachedQuote?.askPrice, 171.30);
      expect(client.lastRateLimit?.limit, 200);
      expect(client.lastRateLimit?.remaining, 198);
      expect(transport.uris, hasLength(2));
      expect(
        transport.uris.every((uri) => uri.queryParameters['feed'] == 'iex'),
        isTrue,
      );
      expect(
        transport.uris.every((uri) => !uri.query.contains('test-secret')),
        isTrue,
      );
      expect(
        transport.headers.every(
          (headers) =>
              headers['APCA-API-KEY-ID'] == 'test-key-id' &&
              headers['APCA-API-SECRET-KEY'] == 'test-secret',
        ),
        isTrue,
      );
    },
  );

  test('requests raw IEX daily bars and normalizes the response', () async {
    final transport = _FakeTransport({
      '/v2/stocks/AAPL/bars': {
        'symbol': 'AAPL',
        'bars': [
          {
            't': '2026-10-09T04:00:00Z',
            'o': 172.02,
            'h': 173.07,
            'l': 170.341,
            'c': 171.21,
            'v': 51861083,
            'n': 535134,
            'vw': 171.599691,
          },
        ],
        'next_page_token': null,
      },
    });
    final client = AlpacaMarketDataClient(
      apiKeyId: 'test-key-id',
      apiSecretKey: 'test-secret',
      transport: transport,
      clock: () => retrievedAt,
    );

    final bars = await client.dailyBars(
      'AAPL',
      start: DateTime.utc(2026, 10, 1),
      end: DateTime.utc(2026, 10, 10),
    );

    expect(bars, hasLength(1));
    expect(bars.single.close, 171.21);
    expect(bars.single.adjustment, PriceAdjustment.raw);
    expect(transport.uris.single.queryParameters['feed'], 'iex');
    expect(transport.uris.single.queryParameters['adjustment'], 'raw');
    expect(transport.uris.single.queryParameters['timeframe'], '1Day');
  });

  test(
    'reports provider entitlement errors without exposing response bodies',
    () async {
      final transport = _FakeTransport(
        {},
        statusCode: 403,
        body: '{"message":"account details"}',
      );
      final client = AlpacaMarketDataClient(
        apiKeyId: 'test-key-id',
        apiSecretKey: 'test-secret',
        transport: transport,
        clock: () => retrievedAt,
      );

      await expectLater(
        client.latestQuote('AAPL'),
        throwsA(
          isA<MarketDataException>()
              .having((error) => error.statusCode, 'statusCode', 403)
              .having(
                (error) => error.message,
                'message',
                contains('IEX entitlement'),
              )
              .having(
                (error) => error.message,
                'does not leak response body',
                isNot(contains('account details')),
              ),
        ),
      );
    },
  );
}

class _FakeTransport implements MarketDataTransport {
  _FakeTransport(
    this.payloads, {
    this.statusCode = 200,
    this.body,
    this.responseHeaders = const {},
  });

  final Map<String, Map<String, Object?>> payloads;
  final int statusCode;
  final String? body;
  final Map<String, String> responseHeaders;
  final List<Uri> uris = [];
  final List<Map<String, String>> headers = [];

  @override
  Future<MarketDataHttpResponse> get(
    Uri uri, {
    required Map<String, String> headers,
  }) async {
    uris.add(uri);
    this.headers.add(headers);
    return MarketDataHttpResponse(
      statusCode: statusCode,
      body: body ?? jsonEncode(payloads[uri.path] ?? <String, Object?>{}),
      headers: responseHeaders,
    );
  }
}
