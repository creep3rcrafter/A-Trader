import 'dart:async';
import 'dart:math';

import 'package:atrader/auto_research.dart';
import 'package:atrader/historical_replay.dart';
import 'package:atrader/simulator.dart';
import 'package:flutter_test/flutter_test.dart';

class _FirstChoice implements Random {
  @override
  int nextInt(int max) => 0;

  @override
  bool nextBool() => false;

  @override
  double nextDouble() => 0;
}

Future<void> _waitUntil(bool Function() condition) async {
  final elapsed = Stopwatch()..start();
  while (!condition()) {
    if (elapsed.elapsed > const Duration(seconds: 10)) {
      fail('Research did not reach the expected state.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  final strategy = StrategySettings(
    strategyId: 'ma_crossover_long_short',
    label: 'MA',
    intervalMinutes: 30,
  );
  final configuration = {
    'watchlist': ['SOXL'],
    'strategies': [
      {
        'strategyId': strategy.strategyId,
        'label': strategy.label,
        'intervalMinutes': 5,
        'enabled': true,
        'parameters': <String, double>{},
      },
    ],
  };
  final now = DateTime.utc(2026, 5, 6, 12);

  test('samples usable history repeatedly and reuses the download', () async {
    var requests = 0;
    final research = AutoResearch(
      clock: () => now,
      random: _FirstChoice(),
      cycleDelay: const Duration(milliseconds: 20),
      fetch: ({required symbol, required startUtc, required endUtc}) async {
        requests++;
        expect(symbol, 'SOXL');
        expect(endUtc, DateTime.utc(2026, 5, 6));
        expect(startUtc, endUtc.subtract(const Duration(days: 28)));
        return [
          for (final day in [4, 5])
            for (var i = 0; i < 200; i++)
              MinuteBar(
                symbol: symbol,
                openTime: DateTime.utc(2026, 5, day, 13, 30 + i),
                open: 100 + sin(i / 4),
                high: 102,
                low: 98,
                close: 100 + sin((i + 1) / 4),
                volume: 1000,
              ),
        ];
      },
    );
    addTearDown(research.stop);
    research.start(
      runName: 'Source',
      configuration: configuration,
      strategies: [strategy],
      generations: 2,
    );
    await _waitUntil(() => (research.status['cycles'] as int) >= 2);
    expect(research.status['interval'], 1);
    expect(research.status['candidatesTested'], greaterThan(29));
    final result = (research.status['lastResults'] as List).single as Map;
    expect(result['intervalMinutes'], 1);
    final training = (result['currentTraining'] as Map)['returnPercent'] as num;
    final selection =
        (result['currentSelection'] as Map)['returnPercent'] as num;
    expect(
      result['currentDevelopmentReturn'],
      closeTo(((1 + training / 100) * (1 + selection / 100) - 1) * 100, 1e-9),
    );
    expect(requests, 1);
    expect((configuration['strategies']!.single as Map)['intervalMinutes'], 5);
    research.stop();
    await _waitUntil(() => research.status['message'] == 'Stopped');
  });

  test('stopping during download discards the pending cycle', () async {
    final first = Completer<List<MinuteBar>>();
    final second = Completer<List<MinuteBar>>();
    final research = AutoResearch(
      clock: () => now,
      fetch: ({required symbol, required startUtc, required endUtc}) =>
          symbol == 'SOXL' ? first.future : second.future,
    );
    expect(research.status['phase'], 'ready');
    research.start(
      runName: 'Source',
      configuration: {
        ...configuration,
        'watchlist': ['SOXL', 'QQQ'],
      },
      strategies: [
        StrategySettings(
          strategyId: strategy.strategyId,
          label: strategy.label,
          intervalMinutes: 5,
        ),
      ],
      generations: 0,
    );
    expect(research.status['interval'], 1);
    expect(research.status['phase'], 'downloading');
    expect(research.status['progress'], 0);
    expect(research.status['detail'], contains('SOXL'));
    first.complete([]);
    await _waitUntil(() => research.status['progress'] == .5);
    expect(research.status['detail'], contains('QQQ'));
    research.stop();
    expect(research.status['stopping'], isTrue);
    expect(research.status['phase'], 'stopping');
    expect(research.status['progress'], isNull);
    second.complete([]);
    await _waitUntil(() => research.status['message'] == 'Stopped');
    expect(research.status['phase'], 'stopped');
    expect(research.status['cycles'], 0);
  });

  test(
    'historical research fetches and replays only the selected range',
    () async {
      final start = DateTime.utc(2026, 5, 5, 16);
      final end = start.add(const Duration(minutes: 2));
      var requests = 0;
      final research = AutoResearch(
        clock: () => now,
        cycleDelay: const Duration(milliseconds: 20),
        fetch: ({required symbol, required startUtc, required endUtc}) async {
          requests++;
          expect(startUtc, start);
          expect(endUtc, end);
          return [
            for (var i = -150; i < 150; i++)
              MinuteBar(
                symbol: symbol,
                openTime: start.add(Duration(minutes: i)),
                open: 100,
                high: 101,
                low: 99,
                close: 100,
                volume: 1000,
              ),
          ];
        },
      );
      addTearDown(research.stop);
      research.start(
        runName: 'Source',
        configuration: configuration,
        strategies: [strategy],
        generations: 0,
        historicalRange: (startUtc: start, endUtc: end, label: 'Chosen hours'),
      );
      await _waitUntil(() => (research.status['cycles'] as int) >= 2);
      expect(research.status['rangeLabel'], 'Chosen hours');
      expect(research.status['start'], start.toIso8601String());
      expect(research.status['end'], end.toIso8601String());
      expect(research.status['candidatesTested'], 0);
      final result = (research.status['lastResults'] as List).single as Map;
      expect(result['message'], contains('collected 2'));
      expect(requests, 1);
      research.stop();
      await _waitUntil(() => research.status['message'] == 'Stopped');
    },
  );
}
