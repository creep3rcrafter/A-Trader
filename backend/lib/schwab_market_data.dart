import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:a_trade/market_data/alpaca_market_data_client.dart';
import 'package:a_trade/market_data/market_data.dart';
import 'package:http/http.dart' as http;

import 'schwab_oauth.dart';

const schwabCoverage =
    'Schwab equity REST; realtime/quoteType are provider metadata, not verified '
    'SIP entitlement. Daily adjustment and exchange timezone are unknown; '
    'daily indicators and economic returns are unavailable.';

/// Read-only, single-symbol REST. No retries, accounts, orders or streaming.
class SchwabMarketDataClient implements MarketDataRepository {
  SchwabMarketDataClient({
    required this.oauth,
    http.Client? client,
    DateTime Function()? clock,
    this.timeout = const Duration(seconds: 15),
  }) : _http = client ?? http.Client(),
       _clock = clock ?? DateTime.now;

  final SchwabOAuthClient oauth;
  final http.Client _http;
  final DateTime Function() _clock;
  final Duration timeout;
  final List<DateTime> _requests = [];
  DateTime? _blockedUntil;
  bool _reauthorize = false;

  void close() => _http.close();

  static String _symbol(String value) {
    final symbol = value.trim().toUpperCase();
    if (!RegExp(r'^[A-Z0-9.-]{1,15}$').hasMatch(symbol)) {
      throw const FormatException('Unsupported equity symbol.');
    }
    return symbol;
  }

  Future<Map<String, dynamic>> _get(
    String path,
    Map<String, String> query, {
    required int maximumBytes,
  }) async {
    final now = _clock().toUtc();
    if (_reauthorize) {
      throw const MarketDataException(
        'Schwab authorization rejected; reauthorize explicitly and restart.',
        statusCode: 503,
      );
    }
    _requests.removeWhere(
      (time) => !time.isAfter(now.subtract(const Duration(minutes: 1))),
    );
    if ((_blockedUntil != null && now.isBefore(_blockedUntil!)) ||
        _requests.length >= 10) {
      throw const MarketDataException(
        'Schwab local request limit/cooldown; no retry or provider switch.',
        statusCode: 429,
      );
    }
    _requests.add(now);
    final abort = Completer<void>();
    try {
      final tokens = await oauth.validTokens();
      final request =
          http.AbortableRequest(
              'GET',
              Uri.https('api.schwabapi.com', '/marketdata/v1/$path', query),
              abortTrigger: abort.future,
            )
            ..followRedirects = false
            ..maxRedirects = 0
            ..headers.addAll({
              'Authorization': 'Bearer ${tokens.accessToken}',
              'Accept': 'application/json',
            });
      final response = await _http.send(request).timeout(timeout);
      if (response.statusCode != 200) {
        // Cancel without decoding or logging provider error bodies.
        await response.stream.listen(null).cancel();
        if (response.statusCode == 401) _reauthorize = true;
        if (response.statusCode == 403 || response.statusCode == 429) {
          _blockedUntil = _clock().toUtc().add(const Duration(minutes: 1));
        }
        throw MarketDataException(switch (response.statusCode) {
          401 => 'Schwab authorization rejected; reauthorize and restart.',
          403 =>
            'Schwab denied market-data access; check app permissions. Cooldown active.',
          429 => 'Schwab rate limit reached; cooldown active, no retries.',
          413 => 'Schwab response/request size rejected.',
          _ => 'Schwab market-data request rejected.',
        }, statusCode: response.statusCode == 401 ? 503 : response.statusCode);
      }
      final bytes = <int>[];
      await (() async {
        await for (final chunk in response.stream) {
          if (bytes.length + chunk.length > maximumBytes) {
            throw const MarketDataException(
              'Schwab response exceeded size limit.',
            );
          }
          bytes.addAll(chunk);
        }
      })().timeout(timeout);
      final value = jsonDecode(utf8.decode(bytes));
      if (value is! Map<String, dynamic>) throw const FormatException();
      return value;
    } on SchwabAuthException {
      throw MarketDataException(
        oauth.reauthorizationRequired
            ? 'Schwab consent expired/revoked; explicitly reauthorize and restart.'
            : 'Schwab private authorization unavailable; check storage/consent.',
        statusCode: 503,
      );
    } on MarketDataException {
      rethrow;
    } on FormatException {
      throw const MarketDataException('Invalid Schwab market-data response.');
    } on TimeoutException {
      throw const MarketDataException('Schwab market-data request timed out.');
    } on http.ClientException {
      throw const MarketDataException('Schwab market-data transport failed.');
    } on IOException {
      throw const MarketDataException(
        'Schwab market-data transport/storage failed.',
      );
    } finally {
      if (!abort.isCompleted) abort.complete();
    }
  }

  @override
  Future<MarketQuote?> latestQuote(String symbol) async {
    final normalized = _symbol(symbol);
    final json = await _get('quotes', {
      'symbols': normalized,
      'fields': 'quote',
      'indicative': 'false',
    }, maximumBytes: 1024 * 1024);
    try {
      final value = json[normalized];
      if (value == null && json.isEmpty) return null;
      if (json.length != 1 ||
          value is! Map<String, dynamic> ||
          value['symbol'] != normalized ||
          value['assetMainType'] != 'EQUITY') {
        throw const FormatException();
      }
      final quote = value['quote'];
      if (quote is! Map<String, dynamic>) throw const FormatException();
      final now = _clock().toUtc();
      final realtime = value['realtime'];
      final quoteType = value['quoteType'];
      if ((realtime != null && realtime is! bool) ||
          (quoteType != null &&
              (quoteType is! String ||
                  !RegExp(r'^[A-Z_]{1,32}$').hasMatch(quoteType)))) {
        throw const FormatException();
      }
      final last = _optionalPrice(quote['lastPrice']);
      final bid = _optionalPrice(quote['bidPrice']);
      final ask = _optionalPrice(quote['askPrice']);
      final tradeAt = quote['tradeTime'] == null
          ? null
          : _time(quote['tradeTime'], now);
      final quoteAt = quote['quoteTime'] == null
          ? null
          : _time(quote['quoteTime'], now);
      if ((last != null && tradeAt == null) ||
          ((bid != null || ask != null) && quoteAt == null) ||
          (last == null && bid == null && ask == null) ||
          (bid != null && ask != null && bid > ask)) {
        throw const FormatException();
      }
      final volume = quote['totalVolume'];
      if (volume != null && (volume is! int || volume < 0)) {
        throw const FormatException();
      }
      return MarketQuote(
        symbol: normalized,
        provider: MarketDataProvider.schwab,
        feed: MarketDataFeed.schwabEquity,
        retrievedAt: now,
        lastPrice: last,
        lastTradeAt: tradeAt,
        bidPrice: bid,
        askPrice: ask,
        quoteAt: quoteAt,
        realtime: realtime as bool?,
        quoteType: quoteType as String?,
        totalVolume: volume as int?,
      );
    } on FormatException {
      throw const MarketDataException('Invalid Schwab equity quote.');
    } on ArgumentError {
      throw const MarketDataException('Invalid Schwab equity quote.');
    }
  }

  @override
  Future<List<MarketBar>> dailyBars(
    String symbol, {
    required DateTime start,
    required DateTime end,
    PriceAdjustment adjustment = PriceAdjustment.raw,
  }) async {
    final normalized = _symbol(symbol);
    final first = start.toUtc();
    final last = end.toUtc();
    final now = _clock().toUtc();
    if (first.isAfter(last) ||
        last.isAfter(now) ||
        DateTime.utc(last.year, last.month, last.day)
                .difference(DateTime.utc(first.year, first.month, first.day))
                .inDays >=
            120) {
      throw const FormatException(
        'Schwab history requires a past window of at most 120 calendar days.',
      );
    }
    // Preserve the existing raw request default, but never certify raw output.
    if (adjustment != PriceAdjustment.raw &&
        adjustment != PriceAdjustment.unknown) {
      throw const FormatException(
        'Schwab corporate-action adjustment is unknown; adjusted history unavailable.',
      );
    }
    final json = await _get('pricehistory', {
      'symbol': normalized,
      'periodType': 'year',
      'frequencyType': 'daily',
      'frequency': '1',
      'startDate': '${first.millisecondsSinceEpoch}',
      'endDate': '${last.millisecondsSinceEpoch}',
      'needExtendedHoursData': 'false',
      'needPreviousClose': 'false',
    }, maximumBytes: 2 * 1024 * 1024);
    try {
      final candles = json['candles'];
      if (json['symbol'] != normalized ||
          json['empty'] is! bool ||
          candles is! List ||
          candles.length > 120 ||
          json['empty'] != candles.isEmpty) {
        throw const FormatException();
      }
      final retrieved = _clock().toUtc();
      DateTime? previous;
      String? previousDate;
      final dates = <String>{};
      return candles
          .map((value) {
            if (value is! Map<String, dynamic>) throw const FormatException();
            final timestamp = _time(value['datetime'], retrieved);
            final date = value['datetimeISO8601'];
            if (previous != null && !timestamp.isAfter(previous!)) {
              throw const FormatException();
            }
            if (date != null && (date is! String || !_date(date))) {
              throw const FormatException();
            }
            final day =
                date as String? ?? timestamp.toIso8601String().substring(0, 10);
            if (!dates.add(day) ||
                (previousDate != null && day.compareTo(previousDate!) <= 0) ||
                DateTime.parse(day)
                        .difference(
                          DateTime.utc(
                            timestamp.year,
                            timestamp.month,
                            timestamp.day,
                          ),
                        )
                        .inDays
                        .abs() >
                    1 ||
                day.compareTo(retrieved.toIso8601String().substring(0, 10)) >
                    0) {
              throw const FormatException();
            }
            previous = timestamp;
            previousDate = day;
            final volume = value['volume'];
            if (volume is! int || volume < 0) throw const FormatException();
            return MarketBar(
              symbol: normalized,
              provider: MarketDataProvider.schwab,
              feed: MarketDataFeed.schwabEquity,
              timestamp: timestamp,
              retrievedAt: retrieved,
              adjustment: PriceAdjustment.unknown,
              open: _price(value['open']),
              high: _price(value['high']),
              low: _price(value['low']),
              close: _price(value['close']),
              volume: volume,
              tradingDate: date,
              timestampSemantics: date == null
                  ? 'utcDateProxy'
                  : 'providerTradingDate',
            );
          })
          // Validate the entire response before trimming provider boundary bars.
          .toList(growable: false)
          .where(
            (bar) =>
                !bar.timestamp.isBefore(first) &&
                !bar.timestamp.isAfter(last) &&
                (bar.tradingDate ??
                            bar.timestamp.toIso8601String().substring(0, 10))
                        .compareTo(first.toIso8601String().substring(0, 10)) >=
                    0 &&
                (bar.tradingDate ??
                            bar.timestamp.toIso8601String().substring(0, 10))
                        .compareTo(last.toIso8601String().substring(0, 10)) <=
                    0,
          )
          .toList(growable: false);
    } on FormatException {
      throw const MarketDataException('Invalid Schwab daily history.');
    } on ArgumentError {
      throw const MarketDataException('Invalid Schwab daily history.');
    }
  }

  static bool _date(String date) =>
      RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date) &&
      DateTime.tryParse(date)?.toIso8601String().substring(0, 10) == date;

  static DateTime _time(Object? value, DateTime now) {
    if (value is! int || value <= 0 || value > now.millisecondsSinceEpoch) {
      throw const FormatException();
    }
    return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
  }

  static double _price(Object? value) {
    if (value is! num || !value.isFinite || value <= 0) {
      throw const FormatException();
    }
    return value.toDouble();
  }

  static double? _optionalPrice(Object? value) {
    if (value == null || value == 0) return null;
    return _price(value);
  }
}
