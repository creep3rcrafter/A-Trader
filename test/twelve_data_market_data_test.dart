import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:a_trade/market_data/alpaca_market_data_client.dart';
import 'package:a_trade/market_data/market_data.dart';
import 'package:a_trade/market_data/twelve_data_market_data_client.dart';

void main() {
  final retrievedAt = DateTime.utc(2026, 10, 9, 20);
  late Directory tempDirectory;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp('twelve-data-test-');
  });

  tearDown(() async {
    await tempDirectory.delete(recursive: true);
  });

  TwelveDataMarketDataClient client(
    MarketDataTransport transport, {
    DateTime Function()? clock,
  }) => TwelveDataMarketDataClient(
    apiKey: 'test-api-key',
    quotaLedger: File(
      '${tempDirectory.path}${Platform.pathSeparator}quota.json',
    ),
    transport: transport,
    clock: clock ?? () => retrievedAt,
  );

  test(
    'sends quote key in Authorization header and parses conservative feed',
    () async {
      final transport = _FakeTransport((uri, headers) async {
        expect(uri.host, 'api.twelvedata.com');
        expect(uri.path, '/quote');
        expect(uri.queryParameters, {
          'symbol': 'AAPL',
          'country': 'United States',
        });
        expect(uri.query, isNot(contains('test-api-key')));
        expect(headers, {'Authorization': 'apikey test-api-key'});
        return _response(
          quoteFixture(),
          headers: {'api-credits-used': '1', 'api-credits-left': '799'},
        );
      });
      final marketData = client(transport);

      final quote = await marketData.latestQuote(' aapl ');

      expect(quote?.symbol, 'AAPL');
      expect(quote?.provider, MarketDataProvider.twelveData);
      expect(quote?.feed, MarketDataFeed.twelveDataUsEquityUnverified);
      expect(quote?.lastPrice, 171.29);
      expect(
        quote?.quoteAt,
        DateTime.fromMillisecondsSinceEpoch(1791576000 * 1000, isUtc: true),
      );
      expect(
        quote?.freshnessAt(
          now: retrievedAt,
          maximumAge: const Duration(minutes: 1),
        ),
        MarketDataFreshness.unavailable,
      );
      expect(marketData.lastCreditUsage?.used, 1);
      expect(marketData.lastCreditUsage?.left, 799);
    },
  );

  test(
    'requests date-only ascending bars and preserves exchange date metadata',
    () async {
      final transport = _FakeTransport((uri, headers) async {
        expect(uri.path, '/time_series');
        expect(uri.queryParameters, {
          'symbol': 'AAPL',
          'country': 'United States',
          'interval': '1day',
          'start_date': '2026-10-01',
          'end_date': '2026-10-10',
          'outputsize': '5000',
          'order': 'asc',
          'adjust': 'splits',
        });
        expect(headers['Authorization'], 'apikey test-api-key');
        return _response(seriesFixture());
      });
      final marketData = client(transport);

      final bars = await marketData.dailyBars(
        'AAPL',
        start: DateTime.utc(2026, 10, 1),
        end: DateTime.utc(2026, 10, 10),
        adjustment: PriceAdjustment.split,
      );

      final bar = bars.single;
      expect(bar.close, 171.21);
      expect(bar.volume, 51861083);
      expect(bar.adjustment, PriceAdjustment.split);
      expect(bar.provider, MarketDataProvider.twelveData);
      expect(bar.feed, MarketDataFeed.endOfDay);
      expect(bar.timestamp, DateTime.utc(2026, 10, 9));
      expect(bar.toJson()['tradingDate'], '2026-10-09');
      expect(bar.toJson()['exchangeTimezone'], 'America/New_York');
      expect(bar.toJson()['timestampSemantics'], 'exchangeTradingDate');
    },
  );

  test('coalesces concurrent quote requests without caching', () async {
    final response = Completer<MarketDataHttpResponse>();
    final requestStarted = Completer<void>();
    final transport = _FakeTransport((uri, headers) {
      if (!requestStarted.isCompleted) requestStarted.complete();
      return response.future;
    });
    final marketData = client(transport);

    final first = marketData.latestQuote('AAPL');
    final second = marketData.latestQuote('aapl');
    await requestStarted.future;
    expect(transport.uris, hasLength(1));
    response.complete(_response(quoteFixture()));

    expect(await first, isNotNull);
    expect(await second, isNotNull);
    await marketData.latestQuote('AAPL');
    expect(transport.uris, hasLength(2));
  });

  test(
    'rejects mismatched identity, unsupported currencies, and malformed prices',
    () async {
      final mismatch = client(
        _FakeTransport((uri, headers) async {
          return _response(quoteFixture()..['symbol'] = 'MSFT');
        }),
      );
      await expectLater(
        mismatch.latestQuote('AAPL'),
        throwsA(isA<MarketDataException>()),
      );

      final nonUsd = client(
        _FakeTransport((uri, headers) async {
          return _response(quoteFixture()..['currency'] = 'CAD');
        }),
      );
      await expectLater(
        nonUsd.latestQuote('AAPL'),
        throwsA(isA<MarketDataException>()),
      );

      final missingTimestamp = client(
        _FakeTransport((uri, headers) async {
          return _response(quoteFixture()..remove('last_quote_at'));
        }),
      );
      await expectLater(
        missingTimestamp.latestQuote('AAPL'),
        throwsA(isA<MarketDataException>()),
      );
    },
  );

  test(
    'validates daily numeric data, volume, order, dates, and range cap',
    () async {
      final malformedBars = [
        {
          'datetime': '2026-10-09',
          'open': 'NaN',
          'high': '2',
          'low': '1',
          'close': '2',
          'volume': '1',
        },
        {
          'datetime': '2026-10-09',
          'open': '1',
          'high': '2',
          'low': '1',
          'close': '2',
          'volume': '1.5',
        },
        {
          'datetime': '2026-10-11',
          'open': '1',
          'high': '2',
          'low': '1',
          'close': '2',
          'volume': '1',
        },
      ];
      for (final invalidBar in malformedBars) {
        final response = seriesFixture();
        response['values'] = [invalidBar];
        await expectLater(
          client(
            _FakeTransport((uri, headers) async => _response(response)),
          ).dailyBars(
            'AAPL',
            start: DateTime.utc(2026, 10, 1),
            end: DateTime.utc(2026, 10, 10),
          ),
          throwsA(isA<MarketDataException>()),
        );
      }

      final validValues = seriesFixture()['values'] as List<Object?>;
      final outOfOrder = seriesFixture()
        ..['values'] = [validValues.single, validValues.single];
      await expectLater(
        client(
          _FakeTransport((uri, headers) async => _response(outOfOrder)),
        ).dailyBars(
          'AAPL',
          start: DateTime.utc(2026, 10, 1),
          end: DateTime.utc(2026, 10, 10),
        ),
        throwsA(isA<MarketDataException>()),
      );

      expect(
        () =>
            client(
              _FakeTransport(
                (uri, headers) async => _response(seriesFixture()),
              ),
            ).dailyBars(
              'AAPL',
              start: DateTime.utc(2010, 1, 1),
              end: DateTime.utc(2020, 1, 2),
            ),
        throwsArgumentError,
      );
    },
  );

  test('sanitizes provider errors and halts after a provider 429', () async {
    final transport = _FakeTransport((uri, headers) async {
      return _response({
        'status': 'error',
        'code': 429,
        'message': 'test-api-key must never be returned',
      });
    });
    final marketData = client(transport);

    await expectLater(
      marketData.latestQuote('AAPL'),
      throwsA(
        isA<MarketDataException>()
            .having((error) => error.statusCode, 'status', 429)
            .having(
              (error) => error.message,
              'sanitized message',
              isNot(contains('test-api-key')),
            )
            .having(
              (error) => error.message,
              'sanitized message',
              isNot(contains('must never be returned')),
            ),
      ),
    );
    await expectLater(
      marketData.latestQuote('MSFT'),
      throwsA(
        isA<MarketDataException>()
            .having((error) => error.statusCode, 'status', 429)
            .having(
              (error) => error.message,
              'halted locally',
              contains('next UTC day'),
            ),
      ),
    );
    expect(transport.uris, hasLength(1));
  });

  test(
    'maps HTTP authentication, entitlement, and not-found responses safely',
    () async {
      for (final statusCode in [
        HttpStatus.unauthorized,
        HttpStatus.forbidden,
        HttpStatus.notFound,
      ]) {
        final marketData = client(
          _FakeTransport(
            (uri, headers) async => MarketDataHttpResponse(
              statusCode: statusCode,
              body: '{"message":"private upstream response test-api-key"}',
            ),
          ),
        );
        await expectLater(
          marketData.latestQuote('AAPL'),
          throwsA(
            isA<MarketDataException>()
                .having((error) => error.statusCode, 'status', statusCode)
                .having(
                  (error) => error.message,
                  'sanitized',
                  isNot(contains('private upstream response')),
                )
                .having(
                  (error) => error.message,
                  'sanitized',
                  isNot(contains('test-api-key')),
                ),
          ),
        );
      }
    },
  );

  test('rejects malformed JSON and mismatched daily-series symbols', () async {
    final malformedJson = client(
      _FakeTransport(
        (uri, headers) async =>
            const MarketDataHttpResponse(statusCode: 200, body: '{'),
      ),
    );
    await expectLater(
      malformedJson.latestQuote('AAPL'),
      throwsA(
        isA<MarketDataException>().having(
          (error) => error.message,
          'malformed JSON',
          contains('invalid JSON'),
        ),
      ),
    );

    final series = seriesFixture();
    (series['meta'] as Map<String, Object?>)['symbol'] = 'MSFT';
    await expectLater(
      client(
        _FakeTransport((uri, headers) async => _response(series)),
      ).dailyBars(
        'AAPL',
        start: DateTime.utc(2026, 10, 1),
        end: DateTime.utc(2026, 10, 10),
      ),
      throwsA(isA<MarketDataException>()),
    );
  });

  test(
    'sanitizes transport failures and rejects the provider bar limit',
    () async {
      final transportFailure = client(
        _FakeTransport(
          (uri, headers) async =>
              throw const SocketException('private transport detail'),
        ),
      );
      await expectLater(
        transportFailure.latestQuote('AAPL'),
        throwsA(
          isA<MarketDataException>()
              .having(
                (error) => error.message,
                'safe transport message',
                contains('unreachable'),
              )
              .having(
                (error) => error.message,
                'safe transport message',
                isNot(contains('private transport detail')),
              ),
        ),
      );

      final fullResponse = seriesFixture();
      final bar = (fullResponse['values'] as List<Object?>).single;
      fullResponse['values'] = List<Object?>.filled(5000, bar);
      await expectLater(
        client(
          _FakeTransport((uri, headers) async => _response(fullResponse)),
        ).dailyBars(
          'AAPL',
          start: DateTime.utc(2026, 10, 1),
          end: DateTime.utc(2026, 10, 10),
        ),
        throwsA(
          isA<MarketDataException>().having(
            (error) => error.message,
            'provider response cap',
            contains('5000-bar limit'),
          ),
        ),
      );
    },
  );
}

Map<String, Object?> quoteFixture() => {
  'symbol': 'AAPL',
  'name': 'Apple Inc',
  'exchange': 'NASDAQ',
  'mic_code': 'XNAS',
  'currency': 'USD',
  'type': 'Common Stock',
  'country': 'United States',
  'close': '171.29',
  'last_quote_at': 1791576000,
};

Map<String, Object?> seriesFixture() => {
  'meta': {
    'symbol': 'AAPL',
    'name': 'Apple Inc',
    'exchange': 'NASDAQ',
    'mic_code': 'XNAS',
    'currency': 'USD',
    'type': 'Common Stock',
    'country': 'United States',
    'exchange_timezone': 'America/New_York',
  },
  'values': [
    {
      'datetime': '2026-10-09',
      'open': '172.02',
      'high': '173.07',
      'low': '170.341',
      'close': '171.21',
      'volume': '51861083',
    },
  ],
};

MarketDataHttpResponse _response(
  Map<String, Object?> body, {
  int statusCode = HttpStatus.ok,
  Map<String, String> headers = const {},
}) => MarketDataHttpResponse(
  statusCode: statusCode,
  body: jsonEncode(body),
  headers: headers,
);

class _FakeTransport implements MarketDataTransport {
  _FakeTransport(this.handler);

  final Future<MarketDataHttpResponse> Function(
    Uri uri,
    Map<String, String> headers,
  )
  handler;
  final List<Uri> uris = [];

  @override
  Future<MarketDataHttpResponse> get(
    Uri uri, {
    required Map<String, String> headers,
  }) {
    uris.add(uri);
    return handler(uri, headers);
  }
}
