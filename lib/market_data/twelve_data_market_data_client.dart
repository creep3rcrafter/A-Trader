import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:a_trade/market_data/alpaca_market_data_client.dart';
import 'package:a_trade/market_data/market_data.dart';

class TwelveDataCreditUsage {
  const TwelveDataCreditUsage({this.used, this.left});

  final int? used;
  final int? left;

  Map<String, Object?> toJson() => {'used': used, 'left': left};
}

class TwelveDataMarketDataClient implements MarketDataRepository {
  TwelveDataMarketDataClient({
    required String apiKey,
    required File quotaLedger,
    MarketDataTransport? transport,
    DateTime Function()? clock,
  }) : _apiKey = apiKey.trim(),
       _transport = transport ?? IoMarketDataTransport(),
       _clock = clock ?? DateTime.now,
       _quota = TwelveDataQuotaLedger(
         ledgerFile: quotaLedger,
         clock: clock ?? DateTime.now,
       ) {
    if (_apiKey.isEmpty) {
      throw ArgumentError('Twelve Data API key must be set');
    }
  }

  static const _maximumMinuteCredits = 7;
  static const _maximumDailyCredits = 750;
  static const _maximumDailyBars = 5000;
  static const _allowedUsMicCodes = {
    'ARCX',
    'BATS',
    'BATY',
    'EDGA',
    'EDGX',
    'IEXG',
    'XASE',
    'XCHI',
    'XNAS',
    'XNYS',
    'XPHL',
  };

  final String _apiKey;
  final MarketDataTransport _transport;
  final DateTime Function() _clock;
  final TwelveDataQuotaLedger _quota;
  final Map<String, Future<MarketQuote?>> _quoteRequests = {};
  final Map<String, Future<List<MarketBar>>> _barsRequests = {};
  TwelveDataCreditUsage? _lastCreditUsage;

  TwelveDataCreditUsage? get lastCreditUsage => _lastCreditUsage;

  @override
  Future<MarketQuote?> latestQuote(String symbol) {
    final normalizedSymbol = _normalizeSymbol(symbol);
    final pending = _quoteRequests[normalizedSymbol];
    if (pending != null) return pending;

    final request = _loadQuote(normalizedSymbol);
    _quoteRequests[normalizedSymbol] = request;
    return request.whenComplete(() {
      _quoteRequests.remove(normalizedSymbol);
    });
  }

  Future<MarketQuote?> _loadQuote(String symbol) async {
    final response = await _getJson(
      Uri.https('api.twelvedata.com', '/quote', {
        'symbol': symbol,
        'country': 'United States',
      }),
    );
    try {
      _validateIdentity(
        symbol: symbol,
        responseSymbol: response['symbol'],
        name: response['name'],
        requireName: true,
        exchange: response['exchange'],
        micCode: response['mic_code'],
        currency: response['currency'],
        type: response['type'],
        requireType: false,
        country: response['country'],
      );
      final price = _positiveNumber(response['close'], 'quote close');
      final lastQuoteAt = response['last_quote_at'];
      if (lastQuoteAt is! int || lastQuoteAt <= 0) {
        throw const FormatException('last_quote_at must be integer seconds');
      }
      return MarketQuote(
        symbol: symbol,
        provider: MarketDataProvider.twelveData,
        feed: MarketDataFeed.twelveDataUsEquityUnverified,
        retrievedAt: _clock().toUtc(),
        lastPrice: price,
        quoteAt: DateTime.fromMillisecondsSinceEpoch(
          lastQuoteAt * 1000,
          isUtc: true,
        ),
      );
    } on FormatException {
      throw const MarketDataException(
        'Twelve Data returned malformed or unsupported quote data.',
      );
    } on ArgumentError {
      throw const MarketDataException(
        'Twelve Data returned malformed or unsupported quote data.',
      );
    }
  }

  @override
  Future<List<MarketBar>> dailyBars(
    String symbol, {
    required DateTime start,
    required DateTime end,
    PriceAdjustment adjustment = PriceAdjustment.raw,
  }) {
    final normalizedSymbol = _normalizeSymbol(symbol);
    final startDate = _dateOnly(start);
    final endDate = _dateOnly(end);
    if (startDate.isAfter(endDate)) {
      throw ArgumentError('start must not be later than end');
    }
    final maximumEnd = DateTime.utc(
      startDate.year + 10,
      startDate.month,
      startDate.day,
    );
    if (endDate.isAfter(maximumEnd)) {
      throw ArgumentError('Twelve Data date range cannot exceed 10 years');
    }
    final adjust = switch (adjustment) {
      PriceAdjustment.raw => 'none',
      PriceAdjustment.split => 'splits',
      PriceAdjustment.dividend => 'dividends',
      PriceAdjustment.all => 'all',
      PriceAdjustment.unknown => throw ArgumentError(
        'Unknown price adjustment is not supported.',
      ),
    };
    final cacheKey = [
      normalizedSymbol,
      _formatDate(startDate),
      _formatDate(endDate),
      adjust,
    ].join('|');
    final pending = _barsRequests[cacheKey];
    if (pending != null) return pending;

    final request = _loadDailyBars(
      normalizedSymbol,
      start: startDate,
      end: endDate,
      adjust: adjust,
      adjustment: adjustment,
    );
    _barsRequests[cacheKey] = request;
    return request.whenComplete(() {
      _barsRequests.remove(cacheKey);
    });
  }

  Future<List<MarketBar>> _loadDailyBars(
    String symbol, {
    required DateTime start,
    required DateTime end,
    required String adjust,
    required PriceAdjustment adjustment,
  }) async {
    final response = await _getJson(
      Uri.https('api.twelvedata.com', '/time_series', {
        'symbol': symbol,
        'country': 'United States',
        'interval': '1day',
        'start_date': _formatDate(start),
        'end_date': _formatDate(end),
        'outputsize': '5000',
        'order': 'asc',
        'adjust': adjust,
      }),
    );
    try {
      final meta = response['meta'];
      final values = response['values'];
      if (meta is! Map<String, dynamic> || values is! List) {
        throw const FormatException('Missing daily series metadata or values');
      }
      _validateIdentity(
        symbol: symbol,
        responseSymbol: meta['symbol'],
        name: meta['name'],
        requireName: false,
        exchange: meta['exchange'],
        micCode: meta['mic_code'],
        currency: meta['currency'],
        type: meta['type'],
        requireType: true,
        country: meta['country'],
      );
      final timezone = meta['exchange_timezone'];
      if (timezone is! String || timezone.trim().isEmpty) {
        throw const FormatException('Missing exchange timezone');
      }
      if (values.length >= _maximumDailyBars) {
        throw const MarketDataException(
          'Twelve Data returned its 5000-bar limit; narrow the date range.',
        );
      }

      final retrievedAt = _clock().toUtc();
      final bars = <MarketBar>[];
      DateTime? previousDate;
      for (final value in values) {
        if (value is! Map<String, dynamic>) {
          throw const FormatException('Daily bar must be an object');
        }
        final tradingDate = _parseTradingDate(value['datetime']);
        if (tradingDate.isBefore(start) || tradingDate.isAfter(end)) {
          throw const FormatException(
            'Daily bar date is outside the requested range',
          );
        }
        if (previousDate != null && !tradingDate.isAfter(previousDate)) {
          throw const FormatException(
            'Daily bar dates must be strictly ascending',
          );
        }
        previousDate = tradingDate;
        final rawVolume = value['volume'];
        if (rawVolume is! String ||
            !RegExp(r'^\d+$').hasMatch(rawVolume.trim())) {
          throw const FormatException(
            'Daily bar volume must be a non-negative integer string',
          );
        }
        final volume = int.tryParse(rawVolume.trim());
        if (volume == null) {
          throw const FormatException('Daily bar volume is invalid');
        }
        bars.add(
          MarketBar(
            symbol: symbol,
            provider: MarketDataProvider.twelveData,
            feed: MarketDataFeed.endOfDay,
            timestamp: tradingDate,
            retrievedAt: retrievedAt,
            adjustment: adjustment,
            open: _positiveNumber(value['open'], 'daily open'),
            high: _positiveNumber(value['high'], 'daily high'),
            low: _positiveNumber(value['low'], 'daily low'),
            close: _positiveNumber(value['close'], 'daily close'),
            volume: volume,
            tradingDate: _formatDate(tradingDate),
            exchangeTimezone: timezone,
          ),
        );
      }
      return List.unmodifiable(bars);
    } on MarketDataException {
      rethrow;
    } on FormatException {
      throw const MarketDataException(
        'Twelve Data returned malformed or unsupported daily bars.',
      );
    } on ArgumentError {
      throw const MarketDataException(
        'Twelve Data returned malformed or unsupported daily bars.',
      );
    }
  }

  Future<Map<String, dynamic>> _getJson(Uri uri) async {
    await _quota.reserveCredit(
      maximumPerMinute: _maximumMinuteCredits,
      maximumPerDay: _maximumDailyCredits,
    );
    late final MarketDataHttpResponse response;
    try {
      response = await _transport.get(
        uri,
        headers: {'Authorization': 'apikey $_apiKey'},
      );
    } on SocketException {
      throw const MarketDataException('Twelve Data is unreachable.');
    } on TimeoutException {
      throw const MarketDataException('Twelve Data request timed out.');
    } on HttpException {
      throw const MarketDataException('Twelve Data HTTP request failed.');
    } on IOException {
      throw const MarketDataException('Twelve Data transport failed.');
    }
    _recordCreditUsage(response.headers);

    if (response.statusCode != HttpStatus.ok) {
      if (response.statusCode == HttpStatus.tooManyRequests) {
        await _quota.haltUntilNextUtcDay();
      }
      throw _providerError(response.statusCode);
    }

    late final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw const MarketDataException('Twelve Data returned invalid JSON.');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const MarketDataException(
        'Twelve Data returned an invalid response shape.',
      );
    }
    final providerStatus = decoded['status'];
    final code = _providerCode(decoded['code']);
    if (providerStatus == 'error' || (code != null && code >= 400)) {
      if (code == HttpStatus.tooManyRequests) {
        await _quota.haltUntilNextUtcDay();
      }
      throw _providerError(code ?? HttpStatus.badGateway);
    }
    return decoded;
  }

  MarketDataException _providerError(int statusCode) {
    final message = switch (statusCode) {
      HttpStatus.unauthorized =>
        'Twelve Data rejected authentication. Check the server-side API key.',
      HttpStatus.forbidden =>
        'Twelve Data denied access. Check the account plan and market-data terms.',
      HttpStatus.notFound =>
        'Twelve Data has no data for this supported US equity or ETF symbol.',
      HttpStatus.tooManyRequests =>
        'Twelve Data rate limit reached. Requests are halted until the next UTC day.',
      _ => 'Twelve Data market-data request failed (HTTP $statusCode).',
    };
    return MarketDataException(message, statusCode: statusCode);
  }

  void _recordCreditUsage(Map<String, String> headers) {
    _lastCreditUsage = TwelveDataCreditUsage(
      used: int.tryParse(headers['api-credits-used'] ?? ''),
      left: int.tryParse(headers['api-credits-left'] ?? ''),
    );
  }

  static void _validateIdentity({
    required String symbol,
    required Object? responseSymbol,
    required Object? name,
    required bool requireName,
    required Object? exchange,
    required Object? micCode,
    required Object? currency,
    required Object? type,
    required bool requireType,
    required Object? country,
  }) {
    if (responseSymbol is! String ||
        _normalizeSymbol(responseSymbol) != symbol) {
      throw const FormatException('Response symbol does not match request');
    }
    if (requireName && (name is! String || name.trim().isEmpty)) {
      throw const FormatException('Missing instrument name');
    }
    if (exchange is! String || exchange.trim().isEmpty) {
      throw const FormatException('Missing instrument exchange');
    }
    if (micCode is! String ||
        !_allowedUsMicCodes.contains(micCode.trim().toUpperCase())) {
      throw const FormatException('Unsupported US market identifier');
    }
    if (currency is! String || currency.trim().toUpperCase() != 'USD') {
      throw const FormatException('Instrument currency is not USD');
    }
    const supportedTypes = {
      'AMERICAN DEPOSITARY RECEIPT',
      'COMMON STOCK',
      'DEPOSITARY RECEIPT',
      'ETF',
      'GLOBAL DEPOSITARY RECEIPT',
      'PREFERRED STOCK',
      'REIT',
    };
    if (requireType && type is! String) {
      throw const FormatException('Missing instrument type');
    }
    if (type != null &&
        (type is! String ||
            !supportedTypes.contains(type.trim().toUpperCase()))) {
      throw const FormatException(
        'Instrument is not a US listed equity or ETF',
      );
    }
    if (country != null &&
        (country is! String ||
            !const {
              'US',
              'USA',
              'UNITED STATES',
            }.contains(country.trim().toUpperCase()))) {
      throw const FormatException('Instrument is not listed in the US');
    }
  }

  static int? _providerCode(Object? value) {
    if (value is int) return value;
    if (value is String) return int.tryParse(value);
    return null;
  }

  static double _positiveNumber(Object? value, String field) {
    final number = value is num
        ? value.toDouble()
        : value is String
        ? double.tryParse(value.trim())
        : null;
    if (number == null || !number.isFinite || number <= 0) {
      throw FormatException('$field must be finite and positive');
    }
    return number;
  }

  static DateTime _parseTradingDate(Object? value) {
    if (value is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
      throw const FormatException('Daily datetime must be a date only');
    }
    final parts = value.split('-').map(int.parse).toList(growable: false);
    final parsed = DateTime.utc(parts[0], parts[1], parts[2]);
    if (_formatDate(parsed) != value) {
      throw const FormatException('Daily trading date is invalid');
    }
    return parsed;
  }

  static DateTime _dateOnly(DateTime value) =>
      DateTime.utc(value.year, value.month, value.day);

  static String _formatDate(DateTime value) {
    final year = value.year.toString().padLeft(4, '0');
    final month = value.month.toString().padLeft(2, '0');
    final day = value.day.toString().padLeft(2, '0');
    return '$year-$month-$day';
  }

  static String _normalizeSymbol(String symbol) {
    final normalized = symbol.trim().toUpperCase();
    if (!RegExp(r'^[A-Z0-9.-]{1,15}$').hasMatch(normalized)) {
      throw FormatException('Invalid stock symbol: $symbol');
    }
    return normalized;
  }
}

class TwelveDataQuotaLedger {
  TwelveDataQuotaLedger({required File ledgerFile, DateTime Function()? clock})
    : _ledgerFile = ledgerFile,
      _lockFile = File('${ledgerFile.path}.lock'),
      _clock = clock ?? DateTime.now;

  static const _window = Duration(minutes: 1);
  final File _ledgerFile;
  final File _lockFile;
  final DateTime Function() _clock;
  Future<void>? _directoryReady;

  Future<void> reserveCredit({
    required int maximumPerMinute,
    required int maximumPerDay,
  }) async {
    await _withLockedLedger((ledger) {
      final now = _clock().toUtc();
      final today = _utcDate(now);
      final recordedDay = ledger['utcDate'] as String?;
      if (recordedDay != null && recordedDay.compareTo(today) > 0) {
        throw const MarketDataException(
          'Local Twelve Data quota is paused because the UTC clock moved backwards.',
          statusCode: HttpStatus.tooManyRequests,
        );
      }

      final isNewDay = recordedDay != today;
      final dailyCredits = isNewDay
          ? 0
          : _readNonNegativeInt(ledger['dailyCredits'], 'daily credits');
      final haltedUntil = isNewDay ? null : ledger['haltedUntilMs'] as int?;
      if (haltedUntil != null && now.millisecondsSinceEpoch < haltedUntil) {
        throw const MarketDataException(
          'Twelve Data provider limit is active until the next UTC day.',
          statusCode: HttpStatus.tooManyRequests,
        );
      }

      final timestamps = _readTimestamps(ledger['minuteCredits']);
      final cutoff = now.subtract(_window).millisecondsSinceEpoch;
      timestamps.removeWhere((timestamp) => timestamp <= cutoff);
      if (timestamps.length >= maximumPerMinute) {
        throw const MarketDataException(
          'Local Twelve Data limit is 7 credits per minute.',
          statusCode: HttpStatus.tooManyRequests,
        );
      }
      if (dailyCredits >= maximumPerDay) {
        throw const MarketDataException(
          'Local Twelve Data limit is 750 credits per UTC day.',
          statusCode: HttpStatus.tooManyRequests,
        );
      }

      timestamps.add(now.millisecondsSinceEpoch);
      return <String, Object?>{
        'utcDate': today,
        'dailyCredits': dailyCredits + 1,
        'minuteCredits': timestamps,
        'haltedUntilMs': haltedUntil ?? 0,
      };
    });
  }

  Future<void> haltUntilNextUtcDay() async {
    await _withLockedLedger((ledger) {
      final now = _clock().toUtc();
      final today = _utcDate(now);
      final recordedDay = ledger['utcDate'] as String?;
      if (recordedDay != null && recordedDay.compareTo(today) > 0) {
        throw const MarketDataException(
          'Local Twelve Data quota is paused because the UTC clock moved backwards.',
          statusCode: HttpStatus.tooManyRequests,
        );
      }
      final dailyCredits = recordedDay == today
          ? _readNonNegativeInt(ledger['dailyCredits'], 'daily credits')
          : 0;
      final timestamps = recordedDay == today
          ? _readTimestamps(ledger['minuteCredits'])
          : <int>[];
      final reset = DateTime.utc(now.year, now.month, now.day + 1);
      final currentHalt = recordedDay == today
          ? ledger['haltedUntilMs'] as int?
          : null;
      return <String, Object?>{
        'utcDate': today,
        'dailyCredits': dailyCredits,
        'minuteCredits': timestamps,
        'haltedUntilMs': currentHalt == null
            ? reset.millisecondsSinceEpoch
            : currentHalt > reset.millisecondsSinceEpoch
            ? currentHalt
            : reset.millisecondsSinceEpoch,
      };
    });
  }

  Future<void> _withLockedLedger(
    Map<String, Object?> Function(Map<String, dynamic>) update,
  ) async {
    _directoryReady ??= _ensureLedgerDirectory();
    await _directoryReady;
    final lock = await _lockFile.open(mode: FileMode.append);
    var locked = false;
    try {
      await _acquireLock(lock);
      locked = true;
      final ledger = await _readLedger();
      final updated = update(ledger);
      await _ledgerFile.writeAsString(jsonEncode(updated), flush: true);
    } finally {
      try {
        if (locked) await lock.unlock();
      } finally {
        await lock.close();
      }
    }
  }

  Future<void> _ensureLedgerDirectory() async {
    try {
      await _ledgerFile.parent.create(recursive: true);
    } on FileSystemException {
      if (!await _ledgerFile.parent.exists()) rethrow;
    }
  }

  Future<void> _acquireLock(RandomAccessFile file) async {
    final stopwatch = Stopwatch()..start();
    while (true) {
      try {
        await file.lock(FileLock.exclusive);
        return;
      } on FileSystemException catch (error) {
        final errorCode = error.osError?.errorCode;
        if (![11, 13, 33, 35].contains(errorCode) ||
            stopwatch.elapsed > const Duration(seconds: 10)) {
          rethrow;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }
  }

  Future<Map<String, dynamic>> _readLedger() async {
    if (!await _ledgerFile.exists()) return <String, dynamic>{};
    late final Object? decoded;
    try {
      decoded = jsonDecode(await _ledgerFile.readAsString());
    } on FormatException {
      throw const MarketDataException(
        'Twelve Data quota ledger is invalid; refusing provider requests.',
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw const MarketDataException(
        'Twelve Data quota ledger is invalid; refusing provider requests.',
      );
    }
    final recordedDay = decoded['utcDate'];
    if (recordedDay != null &&
        (recordedDay is! String ||
            !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(recordedDay))) {
      throw const MarketDataException(
        'Twelve Data quota ledger is invalid; refusing provider requests.',
      );
    }
    if (recordedDay is String) {
      try {
        TwelveDataMarketDataClient._parseTradingDate(recordedDay);
      } on FormatException {
        throw const MarketDataException(
          'Twelve Data quota ledger is invalid; refusing provider requests.',
        );
      }
    }
    if (decoded.containsKey('dailyCredits')) {
      _readNonNegativeInt(decoded['dailyCredits'], 'daily credits');
    }
    if (decoded.containsKey('minuteCredits')) {
      _readTimestamps(decoded['minuteCredits']);
    }
    if (decoded.containsKey('haltedUntilMs')) {
      _readNonNegativeInt(decoded['haltedUntilMs'], 'halt time');
    }
    return decoded;
  }

  static int _readNonNegativeInt(Object? value, String name) {
    if (value is! int || value < 0) {
      throw MarketDataException(
        'Twelve Data quota ledger has an invalid $name count.',
      );
    }
    return value;
  }

  static List<int> _readTimestamps(Object? value) {
    if (value == null) return <int>[];
    if (value is! List || value.any((item) => item is! int || item < 0)) {
      throw const MarketDataException(
        'Twelve Data quota ledger has invalid minute counters.',
      );
    }
    return value.cast<int>().toList(growable: true);
  }

  static String _utcDate(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';
}
