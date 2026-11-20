import 'package:timezone/data/latest.dart' as timezone_data;
import 'package:timezone/timezone.dart' as timezone;

import 'exchange_calendar.dart';

/// Mountain time in the Denver time zone, including daylight saving changes.
class MountainTime {
  MountainTime._();

  static const zoneId = 'America/Denver';

  static final timezone.Location _location = () {
    timezone_data.initializeTimeZones();
    return timezone.getLocation(zoneId);
  }();

  static timezone.TZDateTime at(DateTime instant) =>
      timezone.TZDateTime.from(instant.toUtc(), _location);

  /// Latest regular 7:30 AM–2:00 PM session whose close has passed.
  static DateTime lastFullTradingDate(DateTime now) {
    final local = at(now);
    var date = DateTime.utc(local.year, local.month, local.day);
    if (local.hour < 14) date = date.subtract(const Duration(days: 1));
    while (true) {
      final midday = toUtc(DateTime.utc(date.year, date.month, date.day, 12));
      if (UsEquityCalendar.forDate(midday)?.closeMinute ==
          UsEquityCalendar.regularCloseMinute) {
        return DateTime(date.year, date.month, date.day);
      }
      date = date.subtract(const Duration(days: 1));
    }
  }

  /// Interprets [wallTime]'s calendar fields as Mountain time, not an instant.
  static DateTime toUtc(DateTime wallTime) {
    final resolved = timezone.TZDateTime(
      _location,
      wallTime.year,
      wallTime.month,
      wallTime.day,
      wallTime.hour,
      wallTime.minute,
      wallTime.second,
      wallTime.millisecond,
      wallTime.microsecond,
    );
    final label =
        '${formatDate(wallTime)} '
        '${formatClock(wallTime.hour, wallTime.minute)}';
    if (!_sameWallTime(resolved, wallTime)) {
      throw ArgumentError(
        '$label does not exist in Mountain Time because of daylight saving '
        'time. Choose a different time.',
      );
    }

    final utc = resolved.toUtc();
    for (final offset in const [Duration(hours: -1), Duration(hours: 1)]) {
      if (_sameWallTime(at(utc.add(offset)), wallTime)) {
        throw ArgumentError(
          '$label occurs twice in Mountain Time because of daylight saving '
          'time. Choose a different time.',
        );
      }
    }
    return utc;
  }

  static bool _sameWallTime(DateTime first, DateTime second) =>
      first.year == second.year &&
      first.month == second.month &&
      first.day == second.day &&
      first.hour == second.hour &&
      first.minute == second.minute &&
      first.second == second.second &&
      first.millisecond == second.millisecond &&
      first.microsecond == second.microsecond;

  static String formatDate(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  static String formatClock(int hour, int minute, {int? second}) {
    final clockHour = hour % 12 == 0 ? 12 : hour % 12;
    final seconds = second == null
        ? ''
        : ':${second.toString().padLeft(2, '0')}';
    final period = hour < 12 ? 'AM' : 'PM';
    return '$clockHour:${minute.toString().padLeft(2, '0')}$seconds $period';
  }

  static String format(DateTime instant, {bool includeSeconds = true}) {
    final local = at(instant);
    return '${formatDate(local)} '
        '${formatClock(local.hour, local.minute, second: includeSeconds ? local.second : null)} '
        '${local.timeZoneName}';
  }
}
