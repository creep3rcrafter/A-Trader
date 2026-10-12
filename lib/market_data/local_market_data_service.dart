import 'dart:convert';

import 'package:http/http.dart' as http;

import '../providers/local_service_url.dart';
import 'market_data.dart';
import 'indicator_snapshot.dart';

class LocalMarketDataException implements Exception {
  const LocalMarketDataException(this.message);
  final String message;
}

String normalizeMarketSymbol(String input) {
  final symbol = input.trim().toUpperCase();
  if (!RegExp(r'^[A-Z0-9.-]{1,15}$').hasMatch(symbol)) {
    throw const LocalMarketDataException(
      'Enter a ticker using 1–15 letters, numbers, dots or hyphens.',
    );
  }
  return symbol;
}

String marketCoverage(MarketDataProvider provider) => switch (provider) {
  MarketDataProvider.alpaca =>
    'Supported US stocks/ETFs; IEX is single-exchange, not consolidated. OTC unavailable.',
  MarketDataProvider.twelveData =>
    'US realtime equity coverage is partial (about 5% volume), not consolidated. '
        'Daily volume completes after midnight ET on the next trading day. OTC unavailable.',
  MarketDataProvider.schwab => 'Coverage unverified; integration unavailable.',
};

class QuoteSnapshot {
  const QuoteSnapshot(this.quote, this.freshness);
  final MarketQuote quote;
  final MarketDataFreshness freshness;
}

class BarSnapshot {
  const BarSnapshot(this.bars, this.provider, this.feed);
  final List<MarketBar> bars;
  final MarketDataProvider provider;
  final MarketDataFeed feed;
}

class LocalMarketDataService {
  LocalMarketDataService({http.Client? client})
    : _client = client ?? http.Client(),
      _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;

  void close() {
    if (_ownsClient) _client.close();
  }

  Future<IndicatorSnapshot> indicators(String backendUrl, String input) async {
    final symbol = normalizeMarketSymbol(input);
    final json = await _request(backendUrl, 'indicators', {'symbol': symbol});
    try {
      return IndicatorSnapshot.parse(json, symbol);
    } on FormatException {
      throw const LocalMarketDataException('Invalid local indicator response.');
    }
  }

  Future<QuoteSnapshot> quote(String backendUrl, String input) async {
    final symbol = normalizeMarketSymbol(input);
    final json = await _request(backendUrl, 'quote', {'symbol': symbol});
    return _validate(() {
      final data = _object(json['data']);
      final provider = _enum(json['provider'], MarketDataProvider.values);
      final feed = _enum(json['feed'], MarketDataFeed.values);
      _supportedSource(provider, feed, bars: false);
      _identity(data, symbol, provider, feed);
      final quote = MarketQuote(
        symbol: symbol,
        provider: provider,
        feed: feed,
        retrievedAt: _timestamp(data['retrievedAt']),
        lastPrice: _optionalNumber(data, 'lastPrice'),
        bidPrice: _optionalNumber(data, 'bidPrice'),
        askPrice: _optionalNumber(data, 'askPrice'),
        lastTradeAt: _optionalTimestamp(data, 'lastTradeAt'),
        quoteAt: _optionalTimestamp(data, 'quoteAt'),
      );
      if ((quote.lastPrice != null && quote.lastTradeAt == null) ||
          ((quote.bidPrice != null || quote.askPrice != null) &&
              quote.quoteAt == null)) {
        throw const FormatException();
      }
      if (quote.lastPrice == null &&
          quote.bidPrice == null &&
          quote.askPrice == null) {
        throw const FormatException();
      }
      return QuoteSnapshot(
        quote,
        _enum(data['freshness'], MarketDataFreshness.values),
      );
    });
  }

  Future<BarSnapshot> dailyBars(String backendUrl, String input) async {
    final symbol = normalizeMarketSymbol(input);
    final now = DateTime.now().toUtc();
    final end = DateTime.utc(now.year, now.month, now.day);
    final start = end.subtract(const Duration(days: 30));
    final json = await _request(backendUrl, 'bars', {
      'symbol': symbol,
      'start': start.toIso8601String(),
      'end': end.toIso8601String(),
      'adjustment': 'raw',
    });
    return _validate(() {
      final provider = _enum(json['provider'], MarketDataProvider.values);
      final feed = _enum(json['feed'], MarketDataFeed.values);
      _supportedSource(provider, feed, bars: true);
      final data = json['data'];
      if (data is! List ||
          json['count'] is! int ||
          json['count'] != data.length) {
        throw const FormatException();
      }
      final bars = data
          .map((raw) {
            final bar = _object(raw);
            _identity(bar, symbol, provider, feed);
            final date = bar['tradingDate'];
            final timezone = bar['exchangeTimezone'];
            if (provider == MarketDataProvider.twelveData) {
              if (date is! String ||
                  !_validDate(date) ||
                  timezone != 'America/New_York' ||
                  bar['timestampSemantics'] != 'exchangeTradingDate') {
                throw const FormatException();
              }
            } else if (date != null ||
                timezone != null ||
                bar['timestampSemantics'] != null) {
              throw const FormatException();
            }
            final timestamp = _timestamp(bar['timestamp']);
            if (timestamp.isBefore(start) || timestamp.isAfter(end)) {
              throw const FormatException();
            }
            final adjustment = _enum(bar['adjustment'], PriceAdjustment.values);
            if (adjustment != PriceAdjustment.raw) {
              throw const FormatException();
            }
            if (!bar.containsKey('tradeCount') ||
                !bar.containsKey('volumeWeightedPrice')) {
              throw const FormatException();
            }
            if (date != null &&
                (timestamp.toIso8601String().substring(0, 10) != date ||
                    timestamp.hour != 0 ||
                    timestamp.minute != 0 ||
                    timestamp.second != 0)) {
              throw const FormatException();
            }
            return MarketBar(
              symbol: symbol,
              provider: provider,
              feed: feed,
              timestamp: timestamp,
              retrievedAt: _timestamp(bar['retrievedAt']),
              adjustment: adjustment,
              open: _number(bar['open']),
              high: _number(bar['high']),
              low: _number(bar['low']),
              close: _number(bar['close']),
              volume: _integer(bar['volume']),
              tradeCount: bar['tradeCount'] == null
                  ? null
                  : _integer(bar['tradeCount']),
              volumeWeightedPrice: bar['volumeWeightedPrice'] == null
                  ? null
                  : _number(bar['volumeWeightedPrice']),
              tradingDate: date as String?,
              exchangeTimezone: timezone as String?,
            );
          })
          .toList(growable: false);
      return BarSnapshot(bars, provider, feed);
    });
  }

  Future<Map<String, dynamic>> _request(
    String backendUrl,
    String route,
    Map<String, String> query,
  ) async {
    final uri = Uri.tryParse(backendUrl);
    if (uri == null || !isLocalServiceUri(uri)) {
      throw const LocalMarketDataException(
        'Use loopback or this web app\'s server URL and Save it in Settings.',
      );
    }
    late http.Response response;
    try {
      final request = http.Request(
        'GET',
        uri.replace(
          path: '/api/v1/market-data/$route',
          queryParameters: query,
          fragment: '',
        ),
      )..followRedirects = false;
      response = await http.Response.fromStream(
        await _client.send(request).timeout(const Duration(seconds: 15)),
      ).timeout(const Duration(seconds: 15));
    } on Exception {
      throw const LocalMarketDataException(
        'Could not reach the local service. Check its URL and browser origin configuration.',
      );
    }
    final json = _validate(() => _object(jsonDecode(response.body)));
    if (response.statusCode != 200) {
      if (json['error'] is! String || (json['error'] as String).isEmpty) {
        throw const LocalMarketDataException(
          'Invalid local market-data response.',
        );
      }
      // Never display arbitrary service text: it could contain credentials.
      throw LocalMarketDataException(switch (response.statusCode) {
        401 => 'Session expired. Reload this page to sign in again.',
        403 => 'Local service denied this browser origin.',
        404 => 'No market data is available for this ticker.',
        429 => 'Free market-data quota exhausted. Try again later.',
        503 =>
          'Selected provider unavailable. Check server credentials and terms.',
        _ =>
          'Local market-data request failed. Check the local service configuration.',
      });
    }
    if (json['coverage'] is! String || (json['coverage'] as String).isEmpty) {
      throw const LocalMarketDataException(
        'Invalid local market-data response.',
      );
    }
    return json;
  }
}

T _validate<T>(T Function() parse) {
  try {
    return parse();
  } on Object {
    throw const LocalMarketDataException('Invalid local market-data response.');
  }
}

Map<String, dynamic> _object(Object? value) {
  if (value is! Map<String, dynamic>) throw const FormatException();
  return value;
}

T _enum<T extends Enum>(Object? value, List<T> values) =>
    values.firstWhere((entry) => entry.name == value);

void _supportedSource(
  MarketDataProvider provider,
  MarketDataFeed feed, {
  required bool bars,
}) {
  if (provider == MarketDataProvider.alpaca && feed == MarketDataFeed.iex) {
    return;
  }
  if (provider == MarketDataProvider.twelveData &&
      feed ==
          (bars
              ? MarketDataFeed.endOfDay
              : MarketDataFeed.twelveDataUsEquityUnverified)) {
    return;
  }
  throw const FormatException();
}

void _identity(
  Map<String, dynamic> data,
  String symbol,
  MarketDataProvider provider,
  MarketDataFeed feed,
) {
  if (data['symbol'] != symbol ||
      data['provider'] != provider.name ||
      data['feed'] != feed.name) {
    throw const FormatException();
  }
}

double _number(Object? value) {
  if (value is! num || !value.toDouble().isFinite) {
    throw const FormatException();
  }
  return value.toDouble();
}

int _integer(Object? value) {
  if (value is! int || value < 0) throw const FormatException();
  return value;
}

double? _optionalNumber(Map<String, dynamic> data, String key) {
  if (!data.containsKey(key)) throw const FormatException();
  return data[key] == null ? null : _number(data[key]);
}

DateTime? _optionalTimestamp(Map<String, dynamic> data, String key) {
  if (!data.containsKey(key)) throw const FormatException();
  return data[key] == null ? null : _timestamp(data[key]);
}

bool _validDate(String value) {
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return false;
  final parsed = DateTime.tryParse(value);
  return parsed != null && parsed.toIso8601String().substring(0, 10) == value;
}

DateTime _timestamp(Object? value) {
  if (value is! String ||
      !RegExp(
        r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})$',
      ).hasMatch(value) ||
      !_validDate(value.substring(0, 10))) {
    throw const FormatException();
  }
  final parsed = DateTime.tryParse(value);
  final hour = int.parse(value.substring(11, 13));
  final minute = int.parse(value.substring(14, 16));
  final second = int.parse(value.substring(17, 19));
  if (parsed == null || hour > 23 || minute > 59 || second > 59) {
    throw const FormatException();
  }
  if (!value.endsWith('Z')) {
    final offset = value.substring(value.length - 5);
    if (int.parse(offset.substring(0, 2)) > 23 ||
        int.parse(offset.substring(3, 5)) > 59) {
      throw const FormatException();
    }
  }
  return parsed.toUtc();
}
