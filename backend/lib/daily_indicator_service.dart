import 'dart:async';
import 'dart:io';

import 'package:a_trade/market_data/alpaca_market_data_client.dart';
import 'package:a_trade/market_data/daily_indicators.dart';
import 'package:a_trade/market_data/market_data.dart';

const int dailyIndicatorHistoryCalendarDays = 120;
const int dailyIndicatorLookbackSessions = 20;
const int dailyIndicatorRsiPeriod = 14;
const int dailyIndicatorLagSessions = 1;
const Duration dailyIndicatorMaximumRetrievalAge = Duration(minutes: 5);
const String dailyIndicatorCoverageSummary =
    'Bounded US regular-equity daily-session analysis; data.coverage, when '
    'available, reports observed versus expected sessions.';

class UsEquitySessionCalendar {
  const UsEquitySessionCalendar._();

  static const int firstSupportedYear = 2025;
  static const int lastSupportedYear = 2030;
  static const String limitation =
      'Expected dates use a bounded US regular-equity holiday calendar '
      '(2025-2030), not an authoritative exchange calendar; unscheduled '
      'closures can appear as missing sessions.';

  static List<String> expectedSessionDates({
    required DateTime start,
    required DateTime end,
  }) {
    final first = DateTime.utc(start.year, start.month, start.day);
    final last = DateTime.utc(end.year, end.month, end.day);
    if (first.isAfter(last) ||
        first.year < firstSupportedYear ||
        last.year > lastSupportedYear) {
      throw const FormatException(
        'US equity session calendar is unavailable for this date range.',
      );
    }
    final holidays = _holidays(first.year - 1, last.year + 1);
    final dates = <String>[];
    for (
      var date = first;
      !date.isAfter(last);
      date = date.add(const Duration(days: 1))
    ) {
      if (_isSession(date, holidays)) dates.add(_dateString(date));
    }
    return List.unmodifiable(dates);
  }

  static String? latestCompletedSessionDate({
    required DateTime cutoff,
    required MarketDataProvider provider,
  }) {
    final current = DateTime.utc(cutoff.year, cutoff.month, cutoff.day);
    if (current.year < firstSupportedYear || current.year > lastSupportedYear) {
      return null;
    }
    final holidays = _holidays(current.year - 1, current.year + 1);
    for (
      var date = current;
      date.year >= firstSupportedYear;
      date = date.subtract(const Duration(days: 1))
    ) {
      if (!_isSession(date, holidays)) continue;
      final availabilityDate = provider == MarketDataProvider.twelveData
          ? _nextSession(date, holidays)
          : date.add(const Duration(days: 1));
      if (availabilityDate == null) return null;
      final availableAt = DateTime.utc(
        availabilityDate.year,
        availabilityDate.month,
        availabilityDate.day,
        6,
      );
      if (!cutoff.isBefore(availableAt)) return _dateString(date);
    }
    return null;
  }

  static bool isExpectedSession(String date) {
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date)) return false;
    final year = int.tryParse(date.substring(0, 4));
    final month = int.tryParse(date.substring(5, 7));
    final day = int.tryParse(date.substring(8, 10));
    if (year == null ||
        month == null ||
        day == null ||
        year < firstSupportedYear ||
        year > lastSupportedYear) {
      return false;
    }
    final parsed = DateTime.utc(year, month, day);
    if (parsed.year != year || parsed.month != month || parsed.day != day) {
      return false;
    }
    return _isSession(parsed, _holidays(year - 1, year + 1));
  }

  static DateTime? _nextSession(DateTime date, Set<DateTime> holidays) {
    for (
      var next = date.add(const Duration(days: 1));
      ;
      next = next.add(const Duration(days: 1))
    ) {
      if (next.year > lastSupportedYear + 1) return null;
      if (_isSession(next, holidays)) return next;
    }
  }

  static bool _isSession(DateTime date, Set<DateTime> holidays) =>
      date.weekday >= DateTime.monday &&
      date.weekday <= DateTime.friday &&
      !holidays.contains(DateTime.utc(date.year, date.month, date.day));

  static Set<DateTime> _holidays(int firstYear, int lastYear) {
    final holidays = <DateTime>{DateTime.utc(2025, 1, 9)};
    for (var year = firstYear; year <= lastYear; year++) {
      void addFixed(int month, int day) {
        final date = DateTime.utc(year, month, day);
        holidays.add(_observed(date));
      }

      final newYear = DateTime.utc(year, 1, 1);
      if (newYear.weekday == DateTime.sunday) {
        holidays.add(newYear.add(const Duration(days: 1)));
      } else if (newYear.weekday != DateTime.saturday) {
        holidays.add(newYear);
      }
      holidays.add(_nthWeekday(year, 1, DateTime.monday, 3));
      holidays.add(_nthWeekday(year, 2, DateTime.monday, 3));
      holidays.add(_easterSunday(year).subtract(const Duration(days: 2)));
      holidays.add(_lastWeekday(year, 5, DateTime.monday));
      addFixed(6, 19);
      addFixed(7, 4);
      holidays.add(_nthWeekday(year, 9, DateTime.monday, 1));
      holidays.add(_nthWeekday(year, 11, DateTime.thursday, 4));
      addFixed(12, 25);
    }
    return holidays;
  }

  static DateTime _observed(DateTime date) => switch (date.weekday) {
    DateTime.saturday => date.subtract(const Duration(days: 1)),
    DateTime.sunday => date.add(const Duration(days: 1)),
    _ => date,
  };

  static DateTime _nthWeekday(
    int year,
    int month,
    int weekday,
    int occurrence,
  ) {
    final first = DateTime.utc(year, month, 1);
    final offset = (weekday - first.weekday + 7) % 7;
    return first.add(Duration(days: offset + (occurrence - 1) * 7));
  }

  static DateTime _lastWeekday(int year, int month, int weekday) {
    final last = DateTime.utc(year, month + 1, 0);
    final offset = (last.weekday - weekday + 7) % 7;
    return last.subtract(Duration(days: offset));
  }

  static DateTime _easterSunday(int year) {
    final a = year % 19;
    final b = year ~/ 100;
    final c = year % 100;
    final d = b ~/ 4;
    final e = b % 4;
    final f = (b + 8) ~/ 25;
    final g = (b - f + 1) ~/ 3;
    final h = (19 * a + b - d - g + 15) % 30;
    final i = c ~/ 4;
    final k = c % 4;
    final l = (32 + 2 * e + 2 * i - h - k) % 7;
    final m = (a + 11 * h + 22 * l) ~/ 451;
    final month = (h + l - 7 * m + 114) ~/ 31;
    final day = (h + l - 7 * m + 114) % 31 + 1;
    return DateTime.utc(year, month, day);
  }

  static String _dateString(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
}

class DailyIndicatorService {
  DailyIndicatorService({
    required this.marketData,
    required this.provider,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final MarketDataRepository? marketData;
  final MarketDataProvider provider;
  final DateTime Function() _clock;

  Future<Map<String, Object?>> analyze({required String symbol}) async {
    if (!_isNormalizedSymbol(symbol)) {
      return _unavailable('Symbol must be a normalized uppercase ticker.');
    }
    final repository = marketData;
    if (provider == MarketDataProvider.schwab) {
      return _unavailable(
        'Schwab daily indicators unavailable: corporate-action adjustment and exchange-session timezone are unverified.',
      );
    }
    if (repository == null) {
      return _unavailable('Market data is disabled or unavailable.');
    }
    final feed = _feedFor(provider);
    if (feed == null) {
      return _unavailable('The selected market-data provider is unsupported.');
    }

    final requestTime = _clock().toUtc();
    final requestStart = DateTime.utc(
      requestTime.year,
      requestTime.month,
      requestTime.day,
    ).subtract(const Duration(days: dailyIndicatorHistoryCalendarDays - 1));
    final requestLatest = UsEquitySessionCalendar.latestCompletedSessionDate(
      cutoff: requestTime,
      provider: provider,
    );
    if (requestLatest == null ||
        requestStart.year < UsEquitySessionCalendar.firstSupportedYear) {
      return _unavailable(
        'The requested date range is outside the supported session calendar.',
      );
    }
    final requestEnd = _parseDate(requestLatest);

    try {
      final bars = await repository.dailyBars(
        symbol,
        start: requestStart,
        end: requestEnd,
        adjustment: PriceAdjustment.raw,
      );
      final cutoff = _clock().toUtc();
      if (bars.isEmpty) {
        return _unavailable('No completed daily bars are available.');
      }
      if (bars.length > dailyIndicatorHistoryCalendarDays) {
        return _unavailable(
          'Daily-bar response exceeded the 120-record bound.',
        );
      }
      final latestCompleted =
          UsEquitySessionCalendar.latestCompletedSessionDate(
            cutoff: cutoff,
            provider: provider,
          );
      if (latestCompleted == null) {
        return _unavailable(
          'The latest completed session is outside the supported calendar.',
        );
      }
      final expectedDates = UsEquitySessionCalendar.expectedSessionDates(
        start: requestStart,
        end: _parseDate(latestCompleted),
      );
      if (expectedDates.isEmpty) {
        return _unavailable('No expected sessions are available.');
      }
      _validateBars(
        bars: bars,
        symbol: symbol,
        feed: feed,
        start: requestStart,
        latestRequestedSession: requestLatest,
        latestCompleted: latestCompleted,
        cutoff: cutoff,
        expectedDates: expectedDates.toSet(),
      );
      final config = DailyIndicatorConfig(
        symbol: symbol,
        provider: provider,
        feed: feed,
        adjustment: PriceAdjustment.raw,
        analysisCutoff: cutoff,
        latestCompletedSessionDate: latestCompleted,
        maximumRetrievalAge: dailyIndicatorMaximumRetrievalAge,
        lookback: dailyIndicatorLookbackSessions,
        trendLag: dailyIndicatorLagSessions,
        rsiPeriod: dailyIndicatorRsiPeriod,
        expectedSessionDates: expectedDates,
        corporateActionComparabilityConfirmed: false,
      );
      final result = DailyIndicatorEngine.calculate(config: config, bars: bars);
      return {
        'status': 'ok',
        'data': result.toJson(),
        'coverage': dailyIndicatorCoverageSummary,
        'sources': [
          _source(
            symbol: symbol,
            publishedAt: _sessionDate(bars.last),
            retrievedAt: bars.last.retrievedAt,
          ),
        ],
        'limitations': [
          UsEquitySessionCalendar.limitation,
          'Session availability uses a conservative 06:00 UTC proxy after '
              'the next calendar day (Alpaca) or next expected session '
              '(Twelve Data).',
          'SMA, SMA trend, EMA and RSI describe arithmetic prices as supplied, '
              'including raw prices without a comparability gate; they are not '
              'economic metrics, and unverified corporate actions may distort '
              'them. Only closeReturn requires raw-price comparability confirmation.',
          'No provider fallback, live API request beyond the configured '
              'repository, or model inference is used.',
        ],
      };
    } on MarketDataException catch (error) {
      return _unavailable(
        error.statusCode == 429
            ? 'Market-data quota reached; no retry or provider switch.'
            : 'Configured market-data provider failed; no provider switch.',
      );
    } on TimeoutException {
      return _unavailable('Market-data request timed out; no provider switch.');
    } on SocketException {
      return _unavailable(
        'Market-data provider is unreachable; no provider switch.',
      );
    } on HttpException {
      return _unavailable(
        'Market-data HTTP request failed; no provider switch.',
      );
    } on DailyIndicatorValidationException {
      return _unavailable('Daily-bar identity or session coverage is invalid.');
    } on FormatException {
      return _unavailable('Daily-bar session calendar is unavailable.');
    } on ArgumentError {
      return _unavailable('Daily-bar identity or values are invalid.');
    }
  }

  void _validateBars({
    required List<MarketBar> bars,
    required String symbol,
    required MarketDataFeed feed,
    required DateTime start,
    required String latestRequestedSession,
    required String latestCompleted,
    required DateTime cutoff,
    required Set<String> expectedDates,
  }) {
    String? previousDate;
    for (final bar in bars) {
      final date = _sessionDate(bar);
      final session = _parseDate(date);
      if (bar.symbol != symbol ||
          bar.provider != provider ||
          bar.feed != feed ||
          bar.adjustment != PriceAdjustment.raw ||
          !expectedDates.contains(date) ||
          session.isBefore(start) ||
          date.compareTo(latestRequestedSession) > 0 ||
          date.compareTo(latestCompleted) > 0 ||
          (previousDate != null && date.compareTo(previousDate) <= 0) ||
          bar.timestamp.toUtc().isAfter(cutoff) ||
          bar.retrievedAt.toUtc().isAfter(cutoff)) {
        throw const DailyIndicatorValidationException(
          'Daily bars do not match the requested identity or completed sessions.',
        );
      }
      if (bar.tradingDate == null &&
          (provider != MarketDataProvider.alpaca ||
              bar.exchangeTimezone != null)) {
        throw const DailyIndicatorValidationException(
          'A source session date is required for this provider.',
        );
      }
      if (bar.tradingDate != null &&
          (bar.exchangeTimezone == null ||
              bar.exchangeTimezone!.trim().isEmpty)) {
        throw const DailyIndicatorValidationException(
          'Exchange session dates require a timezone.',
        );
      }
      previousDate = date;
    }
  }

  String _sessionDate(MarketBar bar) {
    final date =
        bar.tradingDate ??
        '${bar.timestamp.toUtc().year.toString().padLeft(4, '0')}-'
            '${bar.timestamp.toUtc().month.toString().padLeft(2, '0')}-'
            '${bar.timestamp.toUtc().day.toString().padLeft(2, '0')}';
    if (!UsEquitySessionCalendar.isExpectedSession(date)) {
      throw const DailyIndicatorValidationException(
        'Daily bar does not identify a supported US equity session.',
      );
    }
    return date;
  }

  Map<String, Object?> _source({
    required String symbol,
    required String publishedAt,
    required DateTime retrievedAt,
  }) {
    final url = switch (provider) {
      MarketDataProvider.alpaca => Uri.https(
        'data.alpaca.markets',
        '/v2/stocks/$symbol/bars',
        {'timeframe': '1Day', 'feed': 'iex'},
      ).toString(),
      MarketDataProvider.twelveData => Uri.https(
        'api.twelvedata.com',
        '/time_series',
        {'symbol': symbol, 'interval': '1day'},
      ).toString(),
      MarketDataProvider.schwab => '',
    };
    return {
      'title': '${provider.name} daily bars for $symbol',
      'url': url,
      'publishedAt': publishedAt,
      'retrievedAt': retrievedAt.toUtc().toIso8601String(),
    };
  }

  Map<String, Object?> _unavailable(String reason) => {
    'status': 'unavailable',
    'data': null,
    'coverage': dailyIndicatorCoverageSummary,
    'sources': <Map<String, Object?>>[],
    'limitations': [reason],
  };

  static MarketDataFeed? _feedFor(MarketDataProvider provider) =>
      switch (provider) {
        MarketDataProvider.alpaca => MarketDataFeed.iex,
        MarketDataProvider.twelveData => MarketDataFeed.endOfDay,
        MarketDataProvider.schwab => null,
      };

  static bool _isNormalizedSymbol(String symbol) =>
      symbol == symbol.trim().toUpperCase() &&
      RegExp(r'^[A-Z0-9.-]{1,15}$').hasMatch(symbol);

  static DateTime _parseDate(String value) => DateTime.utc(
    int.parse(value.substring(0, 4)),
    int.parse(value.substring(5, 7)),
    int.parse(value.substring(8, 10)),
  );
}
