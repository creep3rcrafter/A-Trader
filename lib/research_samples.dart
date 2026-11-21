import 'dart:math';

import 'exchange_calendar.dart';
import 'historical_replay.dart';
import 'mountain_time.dart';

const minimumResearchMinutes = 180;

typedef ResearchSample = ({
  HistoricalRange range,
  Map<String, List<MinuteBar>> history,
});

/// Index only minutes present for every selected symbol. Multi-day samples
/// use the same Mountain clock window on each included trading day.
class ResearchSamples {
  ResearchSamples(HistoricalRange bounds, Map<String, List<MinuteBar>> history)
    : _history = history {
    final start = MountainTime.at(bounds.startUtc);
    final end = MountainTime.at(bounds.endUtc);
    final firstMinute = start.hour * 60 + start.minute;
    final lastMinute = end.hour == 0 && end.minute == 0
        ? 1440
        : end.hour * 60 + end.minute;
    final coverage = <DateTime, Map<int, int>>{};
    for (final bars in history.values) {
      final seen = <DateTime>{};
      for (final bar in bars) {
        final time = bar.openTime.toUtc();
        if (!seen.add(time) ||
            time.isBefore(bounds.startUtc) ||
            time.add(const Duration(minutes: 1)).isAfter(bounds.endUtc) ||
            UsEquityCalendar.sessionAt(time) == null) {
          continue;
        }
        final local = MountainTime.at(time);
        final minute = local.hour * 60 + local.minute;
        if (minute < firstMinute || minute >= lastMinute) continue;
        final day = DateTime.utc(local.year, local.month, local.day);
        final counts = coverage.putIfAbsent(day, () => {});
        counts.update(minute, (count) => count + 1, ifAbsent: () => 1);
      }
    }
    final days = coverage.keys.toList()..sort();
    for (var first = 0; first < days.length; first++) {
      Set<int>? shared;
      for (var last = first; last < min(days.length, first + 5); last++) {
        if (last > first && !_adjacent(days[last - 1], days[last])) break;
        final available = {
          for (final entry in coverage[days[last]]!.entries)
            if (entry.value == history.length) entry.key,
        };
        shared = shared?.intersection(available) ?? available;
        final minutes = shared.toList()..sort();
        final windows = <(int, int)>[];
        for (var i = 0; i < minutes.length;) {
          final from = minutes[i++];
          while (i < minutes.length && minutes[i] == minutes[i - 1] + 1) {
            i++;
          }
          final until = minutes[i - 1] + 1;
          if (until - from >= minimumResearchMinutes) {
            windows.add((from, until));
          }
        }
        if (windows.isEmpty) break;
        _choices.add((days: days.sublist(first, last + 1), windows: windows));
      }
    }
    if (_choices.isEmpty) {
      throw StateError(
        'No trading day has 3 consecutive hours of saved 1-minute candles '
        'for every watchlist symbol within the selected dates and times.',
      );
    }
  }

  final Map<String, List<MinuteBar>> _history;
  final _choices = <({List<DateTime> days, List<(int, int)> windows})>[];

  static bool _adjacent(DateTime first, DateTime last) {
    for (
      var day = first.add(const Duration(days: 1));
      day.isBefore(last);
      day = day.add(const Duration(days: 1))
    ) {
      if (UsEquityCalendar.forDate(day.add(const Duration(hours: 18))) !=
          null) {
        return false;
      }
    }
    return true;
  }

  ResearchSample choose(Random random) {
    final choice = _choices[random.nextInt(_choices.length)];
    final (from, until) = choice.windows[random.nextInt(choice.windows.length)];
    final start =
        from + random.nextInt(until - from - minimumResearchMinutes + 1);
    final end =
        start +
        minimumResearchMinutes +
        random.nextInt(until - start - minimumResearchMinutes + 1);
    DateTime utc(DateTime day, int minute) =>
        MountainTime.toUtc(day.add(Duration(minutes: minute)));
    final windows = [
      for (final day in choice.days) (utc(day, start), utc(day, end)),
    ];
    final first = choice.days.first;
    final last = choice.days.last;
    final dates = first == last
        ? MountainTime.formatDate(first)
        : '${MountainTime.formatDate(first)} to ${MountainTime.formatDate(last)}';
    return (
      range: (
        startUtc: windows.first.$1,
        endUtc: windows.last.$2,
        label:
            '$dates · ${MountainTime.formatClock(start ~/ 60, start % 60)}'
            '–${MountainTime.formatClock(end ~/ 60, end % 60)} MT'
            ' · ${choice.days.length} trading session(s)',
      ),
      history: {
        for (final entry in _history.entries)
          entry.key: [
            for (final bar in entry.value)
              if (windows.any(
                (window) =>
                    !bar.openTime.isBefore(window.$1) &&
                    bar.openTime.isBefore(window.$2),
              ))
                bar,
          ],
      },
    );
  }
}
