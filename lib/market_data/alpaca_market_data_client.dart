import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'market_data.dart';

class MarketDataException implements Exception {
  const MarketDataException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class MarketDataHttpResponse {
  const MarketDataHttpResponse({
    required this.statusCode,
    required this.body,
    this.headers = const {},
  });

  final int statusCode;
  final String body;
  final Map<String, String> headers;
}

class MarketDataRateLimit {
  const MarketDataRateLimit({
    required this.limit,
    required this.remaining,
    required this.resetAt,
  });

  final int? limit;
  final int? remaining;
  final DateTime? resetAt;

  Map<String, Object?> toJson() => {
    'limit': limit,
    'remaining': remaining,
    'resetAt': resetAt?.toUtc().toIso8601String(),
  };
}

abstract interface class MarketDataTransport {
  Future<MarketDataHttpResponse> get(
    Uri uri, {
    required Map<String, String> headers,
  });
}

class IoMarketDataTransport implements MarketDataTransport {
  IoMarketDataTransport({HttpClient? client})
    : _client = client ?? HttpClient();

  final HttpClient _client;

  @override
  Future<MarketDataHttpResponse> get(
    Uri uri, {
    required Map<String, String> headers,
  }) async {
    final request = await _client
        .getUrl(uri)
        .timeout(const Duration(seconds: 10));
    request.followRedirects = false;
    for (final header in headers.entries) {
      request.headers.set(header.key, header.value);
    }

    final response = await request.close().timeout(const Duration(seconds: 10));
    final body = await utf8.decoder
        .bind(response)
        .join()
        .timeout(const Duration(seconds: 10));
    return MarketDataHttpResponse(
      statusCode: response.statusCode,
      body: body,
      headers: {
        for (final name in [
          'x-ratelimit-limit',
          'x-ratelimit-remaining',
          'x-ratelimit-reset',
          'api-credits-used',
          'api-credits-left',
        ])
          name: ?response.headers.value(name),
      },
    );
  }

  void close() => _client.close(force: true);
}

class AlpacaMarketDataClient implements MarketDataRepository {
  AlpacaMarketDataClient({
    required String apiKeyId,
    required String apiSecretKey,
    MarketDataTransport? transport,
    DateTime Function()? clock,
    this.allowCaching = false,
  }) : _apiKeyId = apiKeyId.trim(),
       _apiSecretKey = apiSecretKey.trim(),
       _transport = transport ?? IoMarketDataTransport(),
       _clock = clock ?? DateTime.now {
    if (_apiKeyId.isEmpty || _apiSecretKey.isEmpty) {
      throw ArgumentError('Alpaca API key ID and secret must both be set');
    }
  }

  static const _historicalPageLimit = 10000;
  static const _maximumHistoricalPages = 5;
  static const _requestWindow = Duration(minutes: 1);
  static const _maximumRequestsPerWindow = 180;
  static const _quoteCacheDuration = Duration(seconds: 10);
  static const _barsCacheDuration = Duration(minutes: 10);

  final String _apiKeyId;
  final String _apiSecretKey;
  final MarketDataTransport _transport;
  final DateTime Function() _clock;
  final bool allowCaching;
  final Queue<DateTime> _recentRequests = Queue<DateTime>();
  final Map<String, _CacheEntry<MarketQuote?>> _quoteCache = {};
  final Map<String, Future<MarketQuote?>> _quoteRequests = {};
  final Map<String, _CacheEntry<List<MarketBar>>> _barsCache = {};
  final Map<String, Future<List<MarketBar>>> _barsRequests = {};
  MarketDataRateLimit? _lastRateLimit;

  MarketDataRateLimit? get lastRateLimit => _lastRateLimit;

  @override
  Future<MarketQuote?> latestQuote(String symbol) {
    final normalizedSymbol = _normalizeSymbol(symbol);
    final cacheKey = normalizedSymbol;
    final now = _clock();
    if (allowCaching) {
      final cached = _quoteCache[cacheKey];
      if (cached != null && cached.expiresAt.isAfter(now)) {
        return Future.value(cached.value);
      }
    }

    final pending = _quoteRequests[cacheKey];
    if (pending != null) return pending;

    final request = _loadQuote(normalizedSymbol);
    _quoteRequests[cacheKey] = request;
    return request
        .then((quote) {
          if (allowCaching) {
            _quoteCache[cacheKey] = _CacheEntry(
              value: quote,
              expiresAt: _clock().add(_quoteCacheDuration),
            );
          }
          return quote;
        })
        .whenComplete(() {
          _quoteRequests.remove(cacheKey);
        });
  }

  Future<MarketQuote?> _loadQuote(String symbol) async {
    final tradeUri = _uri('/v2/stocks/$symbol/trades/latest', {'feed': 'iex'});
    final quoteUri = _uri('/v2/stocks/$symbol/quotes/latest', {'feed': 'iex'});
    final responses = await Future.wait([
      _getJson(tradeUri),
      _getJson(quoteUri),
    ]);
    final retrievedAt = _clock().toUtc();
    late final MarketQuote? trade;
    late final MarketQuote? quote;
    try {
      trade = AlpacaMarketDataNormalizer.latestTrade(
        symbol: symbol,
        response: responses[0],
        retrievedAt: retrievedAt,
      );
      quote = AlpacaMarketDataNormalizer.latestQuote(
        symbol: symbol,
        response: responses[1],
        retrievedAt: retrievedAt,
      );
    } on FormatException {
      throw const MarketDataException(
        'Alpaca returned malformed quote or trade data.',
      );
    }
    if (trade == null) return quote;
    if (quote == null) return trade;
    return trade.merge(quote);
  }

  @override
  Future<List<MarketBar>> dailyBars(
    String symbol, {
    required DateTime start,
    required DateTime end,
    PriceAdjustment adjustment = PriceAdjustment.raw,
  }) {
    final normalizedSymbol = _normalizeSymbol(symbol);
    if (!start.isBefore(end)) {
      throw ArgumentError('start must be earlier than end');
    }
    final cacheKey = [
      normalizedSymbol,
      start.toUtc().toIso8601String(),
      end.toUtc().toIso8601String(),
      adjustment.name,
    ].join('|');
    final now = _clock();
    if (allowCaching) {
      final cached = _barsCache[cacheKey];
      if (cached != null && cached.expiresAt.isAfter(now)) {
        return Future.value(cached.value);
      }
    }

    final pending = _barsRequests[cacheKey];
    if (pending != null) return pending;

    final request = _loadDailyBars(
      normalizedSymbol,
      start: start,
      end: end,
      adjustment: adjustment,
    );
    _barsRequests[cacheKey] = request;
    return request
        .then((bars) {
          if (allowCaching) {
            _barsCache[cacheKey] = _CacheEntry(
              value: bars,
              expiresAt: _clock().add(_barsCacheDuration),
            );
          }
          return bars;
        })
        .whenComplete(() {
          _barsRequests.remove(cacheKey);
        });
  }

  Future<List<MarketBar>> _loadDailyBars(
    String symbol, {
    required DateTime start,
    required DateTime end,
    required PriceAdjustment adjustment,
  }) async {
    final bars = <MarketBar>[];
    String? pageToken;
    var pageCount = 0;
    final retrievedAt = _clock().toUtc();

    do {
      if (pageCount == _maximumHistoricalPages) {
        throw const MarketDataException(
          'Historical response exceeded the safe page limit.',
        );
      }

      final query = <String, String>{
        'timeframe': '1Day',
        'start': start.toUtc().toIso8601String(),
        'end': end.toUtc().toIso8601String(),
        'limit': '$_historicalPageLimit',
        'feed': 'iex',
        'adjustment': adjustment.name,
        'page_token': ?pageToken,
      };
      final response = await _getJson(_uri('/v2/stocks/$symbol/bars', query));
      late final List<MarketBar> page;
      try {
        page = AlpacaMarketDataNormalizer.dailyBars(
          symbol: symbol,
          response: response,
          retrievedAt: retrievedAt,
          adjustment: adjustment,
        );
      } on FormatException {
        throw const MarketDataException(
          'Alpaca returned malformed historical bar data.',
        );
      }
      bars.addAll(page);
      final nextPageToken = response['next_page_token'];
      if (nextPageToken != null && nextPageToken is! String) {
        throw const MarketDataException('Invalid Alpaca pagination token.');
      }
      pageToken = nextPageToken as String?;
      pageCount++;
    } while (pageToken != null && pageToken.isNotEmpty);

    return List.unmodifiable(bars);
  }

  Uri _uri(String path, Map<String, String> query) =>
      Uri.https('data.alpaca.markets', path, query);

  Future<Map<String, dynamic>> _getJson(Uri uri) async {
    _checkRequestBudget();
    final response = await _transport.get(
      uri,
      headers: {
        'APCA-API-KEY-ID': _apiKeyId,
        'APCA-API-SECRET-KEY': _apiSecretKey,
      },
    );
    _recordRateLimit(response.headers);
    if (response.statusCode != HttpStatus.ok) {
      final message = switch (response.statusCode) {
        HttpStatus.unauthorized =>
          'Alpaca rejected authentication. Check the server-side credentials.',
        HttpStatus.forbidden =>
          'Alpaca denied access. Check the account plan and IEX entitlement.',
        HttpStatus.tooManyRequests =>
          'Alpaca rate limit reached. Wait for the provider reset before retrying.',
        400 || 422 => 'Alpaca rejected the market-data request.',
        _ => 'Alpaca market-data request failed (HTTP ${response.statusCode}).',
      };
      throw MarketDataException(message, statusCode: response.statusCode);
    }

    late final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw const MarketDataException('Alpaca returned invalid JSON.');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Alpaca response must be a JSON object');
    }
    return decoded;
  }

  void _recordRateLimit(Map<String, String> headers) {
    final limit = int.tryParse(headers['x-ratelimit-limit'] ?? '');
    final remaining = int.tryParse(headers['x-ratelimit-remaining'] ?? '');
    final resetSeconds = int.tryParse(headers['x-ratelimit-reset'] ?? '');
    _lastRateLimit = MarketDataRateLimit(
      limit: limit,
      remaining: remaining,
      resetAt: resetSeconds == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              resetSeconds * 1000,
              isUtc: true,
            ),
    );
  }

  void _checkRequestBudget() {
    final now = _clock();
    while (_recentRequests.isNotEmpty &&
        now.difference(_recentRequests.first) >= _requestWindow) {
      _recentRequests.removeFirst();
    }
    if (_recentRequests.length >= _maximumRequestsPerWindow) {
      throw const MarketDataException(
        'Local Alpaca request cap reached; retry after the rate window resets.',
        statusCode: HttpStatus.tooManyRequests,
      );
    }
    _recentRequests.addLast(now);
  }

  static String _normalizeSymbol(String symbol) {
    final normalized = symbol.trim().toUpperCase();
    if (!RegExp(r'^[A-Z0-9.-]{1,15}$').hasMatch(normalized)) {
      throw FormatException('Invalid stock symbol: $symbol');
    }
    return normalized;
  }

  void close() {
    if (_transport is IoMarketDataTransport) _transport.close();
  }
}

class _CacheEntry<T> {
  const _CacheEntry({required this.value, required this.expiresAt});

  final T value;
  final DateTime expiresAt;
}
