import 'package:atrader/historical_replay.dart';
import 'package:atrader/live_runtime.dart';
import 'package:atrader/local_backend.dart';
import 'package:atrader/mountain_time.dart';
import 'package:atrader/schwab_api.dart';
import 'package:atrader/simulator.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records what the strategy could see at each decision and buys once.
class _LookAheadSpy implements TradingStrategy {
  _LookAheadSpy(this.clock);

  final ReplayClock clock;
  final List<({DateTime lastCandle, DateTime now, double close})> seen = [];

  @override
  String get id => 'spy';
  @override
  String get name => 'Spy';
  @override
  String get description => 'Test-only look-ahead detector.';
  @override
  int get warmupBars => 1;
  @override
  List<StrategyParameter> get parameters => const [];

  @override
  StrategySignal evaluate(StrategyContext context) {
    final last = context.candles.last;
    seen.add((lastCandle: last.time, now: clock.now, close: last.close));
    return context.hasPosition
        ? const StrategySignal(TradeAction.wait, 'Holding.')
        : const StrategySignal(TradeAction.buy, 'Spy entry.');
  }
}

// 2026-11-16 is a regular session; 09:30 ET = 14:30 UTC (standard time).
final _sessionOpen = DateTime.utc(2026, 11, 16, 14, 30);

MinuteBar _minute(int index, {DateTime? at}) {
  final open = 100.0 + index * 10;
  return MinuteBar(
    symbol: 'SOXL',
    openTime: at ?? _sessionOpen.add(Duration(minutes: index)),
    open: open,
    high: open + 3,
    low: open - 3,
    close: open + 1,
    volume: 100,
  );
}

void main() {
  test('minute bars become time-ordered quotes; volume lands at close', () {
    final quotes = quotesFromMinuteBars({
      'SOXL': [
        _minute(1),
        _minute(0),
        // Pre-market bars are ignored.
        _minute(0, at: DateTime.utc(2026, 11, 16, 14)),
      ],
    });
    expect(quotes, hasLength(10));
    for (var index = 1; index < quotes.length; index++) {
      expect(quotes[index].time.isAfter(quotes[index - 1].time), isTrue);
    }
    expect(quotes.first.time, _sessionOpen);
    expect(quotes.map((quote) => quote.last).take(5), [100, 100, 97, 103, 101]);
    expect(quotes.take(4).every((quote) => quote.volume == 0), isTrue);
    expect(quotes[4].volume, 100);
  });

  test(
    'historical replay decides only on finished candles and fills later',
    () async {
      final clock = ReplayClock();
      final spy = _LookAheadSpy(clock);
      final runtime = LiveSimulationRuntime(
        watchlist: const ['SOXL'],
        strategies: [StrategySettings(strategyId: 'spy', label: 'Spy')],
        startingCash: 10000,
        spreadBps: 0,
        slippageBps: 0,
        feePerShare: 0,
        strategyOverrides: {'spy': spy},
        clock: clock.call,
      );
      final replay = HistoricalReplay(
        runtime: runtime,
        clock: clock,
        quotes: quotesFromMinuteBars({
          'SOXL': [for (var index = 0; index < 4; index++) _minute(index)],
        }),
        rangeLabel: 'test',
      );
      await replay.run();

      expect(replay.finished, isTrue);
      expect(runtime.running, isFalse);
      expect(spy.seen, isNotEmpty);
      for (final view in spy.seen) {
        // A candle is evaluated only once its minute has ended.
        expect(view.now.isBefore(view.lastCandle), isFalse);
      }
      // First decision: minute 0 (close 101), seen at minute 1's open.
      expect(spy.seen.first.close, 101);
      final account = runtime.engines[1]!.accounts['Spy']!;
      final fill = account.events.firstWhere((event) => event.kind == 'fill');
      final signal = account.events.firstWhere(
        (event) => event.kind == 'signal' && event.action == TradeAction.buy,
      );
      expect(fill.time.isAfter(signal.time), isTrue);
      // Fills at minute 1's open (110), not at any minute-0 price or the low.
      expect(fill.price, 110);
      // The last minute never completes because no later quote exists.
      expect(runtime.engines[1]!.candles['SOXL']!.last.close, 121);
    },
  );

  test('stop ends a replay and reports where it stopped', () async {
    final clock = ReplayClock();
    final runtime = LiveSimulationRuntime(
      watchlist: const ['SOXL'],
      strategies: const [],
      startingCash: 1000,
      clock: clock.call,
    );
    final replay = HistoricalReplay(
      runtime: runtime,
      clock: clock,
      quotes: quotesFromMinuteBars({
        'SOXL': [for (var index = 0; index < 30; index++) _minute(index)],
      }),
      rangeLabel: 'test',
      quotesPerSlice: 10,
    );
    final running = replay.run();
    await Future<void>.delayed(Duration.zero);
    runtime.running = false;
    await running;
    expect(replay.processed, lessThan(replay.quotes.length));
    expect(runtime.runStatus, contains('stopped'));
    expect(runtime.runStatus, matches(RegExp(r'2026-11-16 7:\d{2} AM MST')));
  });

  test('historical date range rejects future and reversed dates', () {
    final now = DateTime.utc(2026, 11, 16, 18);
    final range = LocalBackend.historicalRange(
      '2026-11-10',
      '2026-11-16',
      nowUtc: now,
    );
    expect(range.startUtc, DateTime.utc(2026, 11, 10, 5));
    expect(range.endUtc, now);
    expect(
      () =>
          LocalBackend.historicalRange('2026-11-16', '2026-11-17', nowUtc: now),
      throwsArgumentError,
    );
    expect(
      () =>
          LocalBackend.historicalRange('2026-11-12', '2026-11-10', nowUtc: now),
      throwsArgumentError,
    );
  });

  test('historical range honors Eastern start and end times', () {
    final now = DateTime.utc(2026, 11, 16, 22);
    final range = LocalBackend.historicalRange(
      '2026-11-10',
      '2026-11-13',
      startTime: '10:00',
      endTime: '14:30',
      nowUtc: now,
    );
    // Eastern standard time is UTC-5.
    expect(range.startUtc, DateTime.utc(2026, 11, 10, 15));
    expect(range.endUtc, DateTime.utc(2026, 11, 13, 19, 30));
    expect(range.label, '2026-11-10 10:00 ET to 2026-11-13 14:30 ET');
    expect(
      () => LocalBackend.historicalRange(
        '2026-11-10',
        '2026-11-10',
        startTime: '11:00',
        endTime: '10:00',
        nowUtc: now,
      ),
      throwsArgumentError,
    );
    expect(
      () => LocalBackend.historicalRange(
        '2026-11-10',
        '2026-11-10',
        startTime: '25:00',
        nowUtc: now,
      ),
      throwsArgumentError,
    );
  });

  test('Mountain replay times convert to the correct UTC span', () {
    final range = LocalBackend.historicalRange(
      '2026-11-10',
      '2026-11-13',
      startTime: '08:30',
      endTime: '14:30',
      timeZone: MountainTime.zoneId,
      nowUtc: DateTime.utc(2026, 11, 16, 22),
    );
    expect(range.startUtc, DateTime.utc(2026, 11, 10, 15, 30));
    expect(range.endUtc, DateTime.utc(2026, 11, 13, 21, 30));
    expect(range.label, '2026-11-10 8:30 AM MST to 2026-11-13 2:30 PM MST');
  });

  test('Mountain replay spans account for DST at each boundary', () {
    final range = LocalBackend.historicalRange(
      '2026-03-06',
      '2026-03-09',
      startTime: '08:30',
      endTime: '14:00',
      timeZone: MountainTime.zoneId,
      nowUtc: DateTime.utc(2026, 3, 10, 22),
    );
    expect(range.startUtc, DateTime.utc(2026, 3, 6, 15, 30));
    expect(range.endUtc, DateTime.utc(2026, 3, 9, 20));
    expect(range.label, '2026-03-06 8:30 AM MST to 2026-03-09 2:00 PM MDT');

    final springDay = LocalBackend.historicalRange(
      '2026-03-08',
      '2026-03-08',
      timeZone: MountainTime.zoneId,
      nowUtc: DateTime.utc(2026, 3, 10),
    );
    expect(springDay.startUtc, DateTime.utc(2026, 3, 8, 7));
    expect(springDay.endUtc, DateTime.utc(2026, 3, 9, 6));
    expect(springDay.endUtc.difference(springDay.startUtc).inHours, 23);

    final fallDay = LocalBackend.historicalRange(
      '2026-11-01',
      '2026-11-01',
      timeZone: MountainTime.zoneId,
      nowUtc: DateTime.utc(2026, 11, 3),
    );
    expect(fallDay.startUtc, DateTime.utc(2026, 11, 1, 6));
    expect(fallDay.endUtc, DateTime.utc(2026, 11, 2, 7));
    expect(fallDay.endUtc.difference(fallDay.startUtc).inHours, 25);
  });

  test('Mountain replay validates dates and ambiguous or missing times', () {
    final now = DateTime.utc(2026, 11, 17, 1);
    final today = LocalBackend.historicalRange(
      '2026-11-16',
      '2026-11-16',
      timeZone: MountainTime.zoneId,
      nowUtc: now,
    );
    expect(today.endUtc, now);
    expect(
      () => LocalBackend.historicalRange(
        '2026-11-17',
        '2026-11-17',
        timeZone: MountainTime.zoneId,
        nowUtc: now,
      ),
      throwsArgumentError,
    );
    expect(
      () => LocalBackend.historicalRange(
        '2026-11-01',
        '2026-11-01',
        startTime: '01:30',
        timeZone: MountainTime.zoneId,
        nowUtc: now,
      ),
      throwsA(
        isA<ArgumentError>().having(
          (error) => error.message,
          'message',
          contains('occurs twice'),
        ),
      ),
    );
    expect(
      () => LocalBackend.historicalRange(
        '2026-03-08',
        '2026-03-08',
        startTime: '02:30',
        timeZone: MountainTime.zoneId,
        nowUtc: now,
      ),
      throwsA(
        isA<ArgumentError>().having(
          (error) => error.message,
          'message',
          contains('does not exist'),
        ),
      ),
    );
    expect(
      () => LocalBackend.historicalRange(
        '2026-02-30',
        '2026-03-01',
        timeZone: MountainTime.zoneId,
        nowUtc: now,
      ),
      throwsArgumentError,
    );
    expect(
      () => LocalBackend.historicalRange(
        '2026-11-10',
        '2026-11-10',
        timeZone: 'unsupported',
        nowUtc: now,
      ),
      throwsArgumentError,
    );
  });

  test('Schwab price history parses bar-open times', () {
    final bars = SchwabApi.parsePriceHistory(
      'SOXL',
      '{"candles":[{"open":1,"high":2,"low":0.5,"close":1.5,"volume":10,'
          '"datetime":${_sessionOpen.millisecondsSinceEpoch}}],"empty":false}',
    );
    expect(bars.single.openTime, _sessionOpen);
    expect(bars.single.close, 1.5);
  });
}
