import 'package:atrader/mountain_time.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('default historical date skips open, weekend, and short sessions', () {
    expect(
      MountainTime.lastFullTradingDate(DateTime.utc(2026, 11, 16, 20)),
      DateTime(2026, 11, 13),
    );
    expect(
      MountainTime.lastFullTradingDate(DateTime.utc(2026, 11, 16, 21)),
      DateTime(2026, 11, 16),
    );
    expect(
      MountainTime.lastFullTradingDate(DateTime.utc(2026, 11, 28, 22)),
      DateTime(2026, 11, 25),
    );
  });
  test('formats midnight and noon in 12-hour Mountain time', () {
    expect(
      MountainTime.format(DateTime.utc(2026, 1, 1, 7)),
      '2026-01-01 12:00:00 AM MST',
    );
    expect(
      MountainTime.format(DateTime.utc(2026, 1, 1, 19, 5, 6)),
      '2026-01-01 12:05:06 PM MST',
    );
    expect(
      MountainTime.format(DateTime.utc(2026, 7, 1, 18, 5, 6)),
      '2026-07-01 12:05:06 PM MDT',
    );
    expect(MountainTime.formatClock(0, 7), '12:07 AM');
    expect(MountainTime.formatClock(12, 7), '12:07 PM');
    expect(MountainTime.formatClock(23, 7), '11:07 PM');
  });

  test('uses the correct offset on both sides of daylight saving changes', () {
    expect(
      MountainTime.format(DateTime.utc(2026, 3, 8, 8, 59)),
      '2026-03-08 1:59:00 AM MST',
    );
    expect(
      MountainTime.format(DateTime.utc(2026, 3, 8, 9)),
      '2026-03-08 3:00:00 AM MDT',
    );
    expect(
      MountainTime.format(DateTime.utc(2026, 11, 1, 7, 59)),
      '2026-11-01 1:59:00 AM MDT',
    );
    expect(
      MountainTime.format(DateTime.utc(2026, 11, 1, 8)),
      '2026-11-01 1:00:00 AM MST',
    );
  });

  test('converts Mountain wall times without using the device time zone', () {
    expect(
      MountainTime.toUtc(DateTime.utc(2026, 11, 16, 8, 30)),
      DateTime.utc(2026, 11, 16, 15, 30),
    );
    expect(
      MountainTime.toUtc(DateTime.utc(2026, 7, 16, 14)),
      DateTime.utc(2026, 7, 16, 20),
    );
    expect(
      MountainTime.format(DateTime.utc(2026, 1, 1, 6, 30)),
      '2025-12-31 11:30:00 PM MST',
    );
  });

  test('rejects nonexistent and ambiguous daylight saving wall times', () {
    expect(
      () => MountainTime.toUtc(DateTime.utc(2026, 3, 8, 2, 30)),
      throwsA(
        isA<ArgumentError>().having(
          (error) => error.message,
          'message',
          contains('does not exist'),
        ),
      ),
    );
    expect(
      () => MountainTime.toUtc(DateTime.utc(2026, 11, 1, 1, 30)),
      throwsA(
        isA<ArgumentError>().having(
          (error) => error.message,
          'message',
          contains('occurs twice'),
        ),
      ),
    );
  });
}
