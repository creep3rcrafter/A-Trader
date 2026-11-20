/// US listed-equity regular-session calendar for live aggregation and strategy
/// cutoffs. The standard federal/NYSE holiday and early-close rules are used;
/// exceptional exchange closures must be refreshed from Schwab market-hours
/// data before a production run.
library;

class EquitySession {
  const EquitySession({
    required this.date,
    required this.openMinute,
    required this.closeMinute,
    required this.elapsedMinutes,
  });

  final DateTime date;
  final int openMinute;
  final int closeMinute;
  final int elapsedMinutes;

  int get durationMinutes => closeMinute - openMinute;
}

class UsEquityCalendar {
  UsEquityCalendar._();

  static const int openMinute = 9 * 60 + 30;
  static const int regularCloseMinute = 16 * 60;

  static EquitySession? sessionAt(DateTime timestamp) {
    final session = forDate(timestamp);
    if (session == null ||
        session.elapsedMinutes < 0 ||
        session.elapsedMinutes >= session.durationMinutes) {
      return null;
    }
    return session;
  }

  static final Map<int, ({DateTime date, int? closeMinute})> _days = {};

  static EquitySession? forDate(DateTime timestamp) {
    final eastern = toEastern(timestamp);
    final key = eastern.year * 10000 + eastern.month * 100 + eastern.day;
    final day = _days[key] ??= () {
      final date = DateTime(eastern.year, eastern.month, eastern.day);
      final closed =
          eastern.weekday == DateTime.saturday ||
          eastern.weekday == DateTime.sunday ||
          _isHoliday(date);
      return (date: date, closeMinute: closed ? null : _earlyCloseMinute(date));
    }();
    final close = day.closeMinute;
    if (close == null) return null;
    final minute = eastern.hour * 60 + eastern.minute;
    return EquitySession(
      date: day.date,
      openMinute: openMinute,
      closeMinute: close,
      elapsedMinutes: minute - openMinute,
    );
  }

  static DateTime toEastern(DateTime value) {
    final utc = value.toUtc();
    final daylightStart = _transitionUtc(utc.year, 3, 2, 7);
    final standardStart = _transitionUtc(utc.year, 11, 1, 6);
    final daylight =
        !utc.isBefore(daylightStart) && utc.isBefore(standardStart);
    return utc.add(Duration(hours: daylight ? -4 : -5));
  }

  static DateTime easternToUtc(DateTime eastern) {
    final daylightStart = DateTime(
      eastern.year,
      3,
      _nthWeekday(eastern.year, 3, DateTime.sunday, 2),
      2,
    );
    final standardStart = DateTime(
      eastern.year,
      11,
      _nthWeekday(eastern.year, 11, DateTime.sunday, 1),
      2,
    );
    final daylight =
        !eastern.isBefore(daylightStart) && eastern.isBefore(standardStart);
    return DateTime.utc(
      eastern.year,
      eastern.month,
      eastern.day,
      eastern.hour + (daylight ? 4 : 5),
      eastern.minute,
      eastern.second,
      eastern.millisecond,
    );
  }

  static int _earlyCloseMinute(DateTime date) {
    if (date.month == 11 &&
        date.weekday == DateTime.friday &&
        date.day == _nthWeekday(date.year, 11, DateTime.thursday, 4) + 1) {
      return 13 * 60;
    }
    if (date.month == 12 && date.day == 24) return 13 * 60;
    if (date.month == 7 && date.day == 3) return 13 * 60;
    return regularCloseMinute;
  }

  static bool _isHoliday(DateTime date) {
    final year = date.year;
    final holidays = <DateTime>[
      _observed(DateTime(year, 1, 1)),
      DateTime(year, 1, _nthWeekday(year, 1, DateTime.monday, 3)),
      DateTime(year, 2, _nthWeekday(year, 2, DateTime.monday, 3)),
      _easterSunday(year).subtract(const Duration(days: 2)),
      DateTime(year, 5, _lastWeekday(year, 5, DateTime.monday)),
      if (year >= 2022) _observed(DateTime(year, 6, 19)),
      _observed(DateTime(year, 7, 4)),
      DateTime(year, 9, _nthWeekday(year, 9, DateTime.monday, 1)),
      DateTime(year, 11, _nthWeekday(year, 11, DateTime.thursday, 4)),
      _observed(DateTime(year, 12, 25)),
    ];
    if (holidays.any((holiday) => _sameDay(date, holiday))) return true;
    if (date.month == 12 && date.day == 31 && date.weekday == DateTime.friday) {
      return _observed(DateTime(year + 1, 1, 1)).year == year;
    }
    return false;
  }

  static DateTime _observed(DateTime holiday) {
    if (holiday.weekday == DateTime.saturday) {
      return holiday.subtract(const Duration(days: 1));
    }
    if (holiday.weekday == DateTime.sunday) {
      return holiday.add(const Duration(days: 1));
    }
    return holiday;
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
    return DateTime(year, month, day);
  }

  static int _nthWeekday(int year, int month, int weekday, int occurrence) {
    final first = DateTime(year, month, 1);
    final offset = (weekday - first.weekday) % 7;
    return 1 + offset + 7 * (occurrence - 1);
  }

  static int _lastWeekday(int year, int month, int weekday) {
    final lastDay = DateTime(year, month + 1, 0);
    final offset = (lastDay.weekday - weekday) % 7;
    return lastDay.day - offset;
  }

  static DateTime _transitionUtc(
    int year,
    int month,
    int occurrence,
    int hour,
  ) => DateTime.utc(
    year,
    month,
    _nthWeekday(year, month, DateTime.sunday, occurrence),
    hour,
  );

  static bool _sameDay(DateTime first, DateTime second) =>
      first.year == second.year &&
      first.month == second.month &&
      first.day == second.day;
}
