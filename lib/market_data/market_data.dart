enum MarketDataProvider { alpaca, schwab, twelveData }

enum MarketDataFeed {
  iex,
  sip,
  delayedSip,
  endOfDay,
  twelveDataUsEquityUnverified,
  unknown,
}

enum PriceAdjustment { raw, split, dividend, all, unknown }

enum MarketDataFreshness { fresh, delayed, stale, unavailable }

class MarketQuote {
  MarketQuote({
    required this.symbol,
    required this.provider,
    required this.feed,
    required this.retrievedAt,
    this.lastPrice,
    this.lastTradeAt,
    this.bidPrice,
    this.askPrice,
    this.quoteAt,
  }) {
    if (symbol.isEmpty || symbol != symbol.trim().toUpperCase()) {
      throw ArgumentError.value(
        symbol,
        'symbol',
        'Must be a normalized uppercase symbol',
      );
    }
    if (lastPrice != null && (!lastPrice!.isFinite || lastPrice! <= 0)) {
      throw ArgumentError.value(lastPrice, 'lastPrice', 'Must be positive');
    }
    if (bidPrice != null && (!bidPrice!.isFinite || bidPrice! < 0)) {
      throw ArgumentError.value(bidPrice, 'bidPrice', 'Must not be negative');
    }
    if (askPrice != null && (!askPrice!.isFinite || askPrice! < 0)) {
      throw ArgumentError.value(askPrice, 'askPrice', 'Must not be negative');
    }
    if (lastTradeAt == null && quoteAt == null) {
      throw ArgumentError('A quote must contain a provider timestamp');
    }
  }

  final String symbol;
  final MarketDataProvider provider;
  final MarketDataFeed feed;
  final DateTime retrievedAt;
  final double? lastPrice;
  final DateTime? lastTradeAt;
  final double? bidPrice;
  final double? askPrice;
  final DateTime? quoteAt;

  DateTime get sourceTimestamp {
    if (lastTradeAt == null) return quoteAt!;
    if (quoteAt == null || lastTradeAt!.isAfter(quoteAt!)) {
      return lastTradeAt!;
    }
    return quoteAt!;
  }

  Map<String, Object?> toJson({DateTime? now, Duration? maximumAge}) => {
    'symbol': symbol,
    'provider': provider.name,
    'feed': feed.name,
    'retrievedAt': retrievedAt.toUtc().toIso8601String(),
    'lastPrice': lastPrice,
    'lastTradeAt': lastTradeAt?.toUtc().toIso8601String(),
    'bidPrice': bidPrice,
    'askPrice': askPrice,
    'quoteAt': quoteAt?.toUtc().toIso8601String(),
    if (now != null && maximumAge != null)
      'freshness': freshnessAt(now: now, maximumAge: maximumAge).name,
  };

  MarketDataFreshness freshnessAt({
    required DateTime now,
    required Duration maximumAge,
  }) {
    if (feed == MarketDataFeed.delayedSip || feed == MarketDataFeed.endOfDay) {
      return MarketDataFreshness.delayed;
    }
    if (feed == MarketDataFeed.unknown ||
        feed == MarketDataFeed.twelveDataUsEquityUnverified) {
      return MarketDataFreshness.unavailable;
    }

    final age = now.difference(sourceTimestamp);
    if (age.isNegative) return MarketDataFreshness.unavailable;
    if (age > maximumAge) return MarketDataFreshness.stale;
    return MarketDataFreshness.fresh;
  }

  MarketQuote merge(MarketQuote other) {
    if (symbol != other.symbol ||
        provider != other.provider ||
        feed != other.feed) {
      throw ArgumentError('Quotes must share symbol, provider, and feed');
    }

    return MarketQuote(
      symbol: symbol,
      provider: provider,
      feed: feed,
      retrievedAt: retrievedAt.isAfter(other.retrievedAt)
          ? retrievedAt
          : other.retrievedAt,
      lastPrice: other.lastPrice ?? lastPrice,
      lastTradeAt: other.lastTradeAt ?? lastTradeAt,
      bidPrice: other.bidPrice ?? bidPrice,
      askPrice: other.askPrice ?? askPrice,
      quoteAt: other.quoteAt ?? quoteAt,
    );
  }
}

class MarketBar {
  MarketBar({
    required this.symbol,
    required this.provider,
    required this.feed,
    required this.timestamp,
    required this.retrievedAt,
    required this.adjustment,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    required this.volume,
    this.tradeCount,
    this.volumeWeightedPrice,
    this.tradingDate,
    this.exchangeTimezone,
  }) {
    if (symbol.isEmpty || symbol != symbol.trim().toUpperCase()) {
      throw ArgumentError.value(
        symbol,
        'symbol',
        'Must be a normalized uppercase symbol',
      );
    }
    final prices = [open, high, low, close];
    if (prices.any((price) => !price.isFinite || price <= 0)) {
      throw ArgumentError('OHLC values must be finite and positive');
    }
    if (low > open ||
        low > close ||
        high < open ||
        high < close ||
        low > high) {
      throw ArgumentError('OHLC values are inconsistent');
    }
    if (volume < 0 || (tradeCount != null && tradeCount! < 0)) {
      throw ArgumentError('Volume and trade count must not be negative');
    }
    if (volumeWeightedPrice != null &&
        (!volumeWeightedPrice!.isFinite || volumeWeightedPrice! <= 0)) {
      throw ArgumentError.value(
        volumeWeightedPrice,
        'volumeWeightedPrice',
        'Must be positive',
      );
    }
  }

  final String symbol;
  final MarketDataProvider provider;
  final MarketDataFeed feed;
  final DateTime timestamp;
  final DateTime retrievedAt;
  final PriceAdjustment adjustment;
  final double open;
  final double high;
  final double low;
  final double close;
  final int volume;
  final int? tradeCount;
  final double? volumeWeightedPrice;
  final String? tradingDate;
  final String? exchangeTimezone;

  Map<String, Object?> toJson() => {
    'symbol': symbol,
    'provider': provider.name,
    'feed': feed.name,
    'timestamp': timestamp.toUtc().toIso8601String(),
    'retrievedAt': retrievedAt.toUtc().toIso8601String(),
    'adjustment': adjustment.name,
    'open': open,
    'high': high,
    'low': low,
    'close': close,
    'volume': volume,
    'tradeCount': tradeCount,
    'volumeWeightedPrice': volumeWeightedPrice,
    if (tradingDate != null) 'tradingDate': tradingDate,
    if (exchangeTimezone != null) 'exchangeTimezone': exchangeTimezone,
    if (tradingDate != null) 'timestampSemantics': 'exchangeTradingDate',
  };
}

abstract interface class MarketDataRepository {
  Future<MarketQuote?> latestQuote(String symbol);

  Future<List<MarketBar>> dailyBars(
    String symbol, {
    required DateTime start,
    required DateTime end,
    PriceAdjustment adjustment = PriceAdjustment.raw,
  });
}

class AlpacaMarketDataNormalizer {
  const AlpacaMarketDataNormalizer._();

  static MarketQuote? latestTrade({
    required String symbol,
    required Map<String, dynamic> response,
    required DateTime retrievedAt,
  }) {
    final normalizedSymbol = _normalizeSymbol(symbol);
    final trade = _symbolRecord(response, 'trade', 'trades', normalizedSymbol);
    if (trade == null) return null;

    final timestamp = _timestamp(trade['t'], 'trade timestamp');
    final price = _number(trade['p'], 'trade price');
    if (price <= 0) throw const FormatException('Trade price must be positive');

    return MarketQuote(
      symbol: normalizedSymbol,
      provider: MarketDataProvider.alpaca,
      feed: MarketDataFeed.iex,
      retrievedAt: retrievedAt,
      lastPrice: price,
      lastTradeAt: timestamp,
    );
  }

  static MarketQuote? latestQuote({
    required String symbol,
    required Map<String, dynamic> response,
    required DateTime retrievedAt,
  }) {
    final normalizedSymbol = _normalizeSymbol(symbol);
    final quote = _symbolRecord(response, 'quote', 'quotes', normalizedSymbol);
    if (quote == null) return null;

    final timestamp = _timestamp(quote['t'], 'quote timestamp');
    final bid = _optionalPositiveNumber(quote['bp']);
    final ask = _optionalPositiveNumber(quote['ap']);

    return MarketQuote(
      symbol: normalizedSymbol,
      provider: MarketDataProvider.alpaca,
      feed: MarketDataFeed.iex,
      retrievedAt: retrievedAt,
      bidPrice: bid,
      askPrice: ask,
      quoteAt: timestamp,
    );
  }

  static List<MarketBar> dailyBars({
    required String symbol,
    required Map<String, dynamic> response,
    required DateTime retrievedAt,
    PriceAdjustment adjustment = PriceAdjustment.raw,
  }) {
    final normalizedSymbol = _normalizeSymbol(symbol);
    final responseSymbol = response['symbol'];
    if (responseSymbol is String &&
        _normalizeSymbol(responseSymbol) != normalizedSymbol) {
      throw const FormatException('Bar response symbol does not match request');
    }

    final rawBars = response['bars'];
    if (rawBars is! List) {
      throw const FormatException('Bar response is missing a bars array');
    }

    return rawBars
        .map((rawBar) {
          if (rawBar is! Map<String, dynamic>) {
            throw const FormatException('Bar item must be a JSON object');
          }

          try {
            final volume = _integer(rawBar['v'], 'bar volume');
            final tradeCount = rawBar['n'] == null
                ? null
                : _integer(rawBar['n'], 'bar trade count');
            return MarketBar(
              symbol: normalizedSymbol,
              provider: MarketDataProvider.alpaca,
              feed: MarketDataFeed.iex,
              timestamp: _timestamp(rawBar['t'], 'bar timestamp'),
              retrievedAt: retrievedAt,
              adjustment: adjustment,
              open: _number(rawBar['o'], 'bar open'),
              high: _number(rawBar['h'], 'bar high'),
              low: _number(rawBar['l'], 'bar low'),
              close: _number(rawBar['c'], 'bar close'),
              volume: volume,
              tradeCount: tradeCount,
              volumeWeightedPrice: rawBar['vw'] == null
                  ? null
                  : _number(rawBar['vw'], 'bar volume-weighted price'),
            );
          } on ArgumentError catch (error) {
            throw FormatException('Invalid bar data: $error');
          }
        })
        .toList(growable: false);
  }

  static Map<String, dynamic>? _symbolRecord(
    Map<String, dynamic> response,
    String singleKey,
    String multiKey,
    String symbol,
  ) {
    final single = response[singleKey];
    if (single is Map<String, dynamic>) {
      final responseSymbol = response['symbol'];
      if (responseSymbol is String &&
          _normalizeSymbol(responseSymbol) != symbol) {
        throw FormatException('Response symbol does not match request');
      }
      return single;
    }

    final multiple = response[multiKey];
    if (multiple == null) return null;
    if (multiple is! Map<String, dynamic>) {
      throw FormatException('$multiKey must be a JSON object');
    }

    final record = multiple[symbol];
    if (record == null) return null;
    if (record is! Map<String, dynamic>) {
      throw FormatException('$multiKey.$symbol must be a JSON object');
    }
    return record;
  }

  static String _normalizeSymbol(String symbol) {
    final normalized = symbol.trim().toUpperCase();
    if (!RegExp(r'^[A-Z0-9.-]{1,15}$').hasMatch(normalized)) {
      throw FormatException('Invalid stock symbol: $symbol');
    }
    return normalized;
  }

  static double _number(Object? value, String field) {
    if (value is! num || !value.toDouble().isFinite) {
      throw FormatException('$field must be a finite number');
    }
    return value.toDouble();
  }

  static int _integer(Object? value, String field) {
    if (value is! int || value < 0) {
      throw FormatException('$field must be a non-negative integer');
    }
    return value;
  }

  static double? _optionalPositiveNumber(Object? value) {
    if (value == null) return null;
    final number = _number(value, 'quote price');
    if (number < 0) {
      throw const FormatException('Quote price cannot be negative');
    }
    return number == 0 ? null : number;
  }

  static DateTime _timestamp(Object? value, String field) {
    if (value is! String) throw FormatException('$field must be a string');
    final timestamp = DateTime.tryParse(value);
    if (timestamp == null) throw FormatException('$field is invalid');
    return timestamp.toUtc();
  }
}
