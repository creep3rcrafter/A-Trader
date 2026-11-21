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

  test(
    'continuous training samples cached intraday windows and resumes',
    () async {
      final start = DateTime.utc(2026, 5, 4, 14);
      final end = DateTime.utc(2026, 5, 5, 19);
      final range = (startUtc: start, endUtc: end, label: 'Two days');
      var loads = 0;
      final labels = <String>{};
      late final AutoResearch research;
      var stopAt = 4;
      research = AutoResearch(
        clock: () => now,
        random: Random(32),
        // Merely importing an algorithm must not make it a replay dependency.
        algorithmDefinitions: () => [
          {
            'kind': 'dart',
            'metadata': {'id': 'unused_dart'},
            'source': 'This unused import cannot compile.',
          },
        ],
        fetch: ({required symbol, required startUtc, required endUtc}) async {
          loads++;
          expect(startUtc, start);
          expect(endUtc, end);
          return [
            for (final day in [4, 5])
              for (var i = 0; i < 390; i++)
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
        onPreview: (_, engine, sample) {
          labels.add(sample.label);
          final perDay = <int, int>{};
          for (final candle in engine.candles['SOXL']!) {
            expect(candle.time.isAfter(start), true);
            expect(candle.time.isAfter(end), false);
            final minute = candle.time.hour * 60 + candle.time.minute;
            expect(minute, inInclusiveRange(14 * 60 + 1, 19 * 60));
            perDay.update(
              candle.time.day,
              (count) => count + 1,
              ifAbsent: () => 1,
            );
          }
          expect(perDay.values, everyElement(greaterThanOrEqualTo(180)));
          expect(perDay.values.toSet(), hasLength(1));
          if (research.status['cycles'] == stopAt) research.stop();
        },
      );
      addTearDown(research.stop);
      void startTraining([Map<String, dynamic>? resume]) => research.start(
        runName: 'Continuous',
        configuration: configuration,
        strategies: [strategy],
        generations: 1,
        continuous: true,
        historicalRange: range,
        resume: resume,
      );
      startTraining();
      await research.stopped.timeout(const Duration(seconds: 20));
      expect(
        research.status['cycles'],
        4,
        reason: '${research.status['message']}',
      );
      expect(labels.length, greaterThan(1));
      expect(loads, 1);
      final checkpoint = research.checkpoint();
      expect(checkpoint['rangeStart'], start.toIso8601String());
      expect(checkpoint['rangeEnd'], end.toIso8601String());
      expect(checkpoint['history'], isNull);
      expect(checkpoint['populations'], isNotEmpty);
      stopAt = 5;
      startTraining(checkpoint);
      await research.stopped.timeout(const Duration(seconds: 20));
      expect(
        research.status['cycles'],
        5,
        reason: '${research.status['message']}',
      );
      expect(loads, 2);
      final individuals = research.latestResults.single['individuals'] as List;
      expect(individuals.any((row) => (row as Map)['elite'] == true), true);
    },
  );

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
