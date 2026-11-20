import 'package:atrader/simulator.dart';
import 'package:atrader/strategy_tuning.dart';
import 'package:flutter_test/flutter_test.dart';

// 9:30 a.m. New York during daylight time.
final _open = DateTime.utc(2026, 5, 4, 13, 30);

List<Candle> _bars(List<num> values, {String symbol = 'SOXL'}) {
  final closes = [for (final value in values) value.toDouble()];
  return [
    for (var index = 0; index < closes.length; index++)
      Candle(
        symbol: symbol,
        time: _open.add(Duration(minutes: index)),
        open: closes[index],
        high: closes[index] + 1,
        low: closes[index] - 1,
        close: closes[index],
        volume: 1000,
      ),
  ];
}

StrategySignal _evaluate(
  String id,
  List<Candle> bars,
  Map<String, double> parameters, {
  PositionSide? held,
}) => StrategyRegistry.byId(id).evaluate(
  StrategyContext(
    candles: bars,
    watchlist: {'SOXL': bars},
    parameters: parameters,
    hasPosition: held != null,
    entryPrice: held == null ? null : bars.last.close,
    positionSide: held ?? PositionSide.long,
    sessionElapsedMinutes: bars.length,
  ),
);

List<double> _mirror(List<num> closes) => [
  for (final close in closes) 200 - close.toDouble(),
];

void main() {
  test('new short and long/short strategies are registered', () {
    for (final id in [
      'donchian_breakdown_short',
      'vwap_rejection_short',
      'opening_range_breakdown_short',
      'ma_crossover_long_short',
      'bollinger_reversion_long_short',
      'momentum_long_short',
    ]) {
      final strategy = StrategyRegistry.byId(id);
      expect(strategy.description, isNotEmpty);
      expect(strategy.parameters, isNotEmpty);
    }
  });

  test('moving-average long/short opens both sides and covers on cross', () {
    const parameters = {'fastPeriod': 2.0, 'slowPeriod': 4.0};
    final down = [100.0, 100, 100, 100, 100, 98];
    final short = _evaluate('ma_crossover_long_short', _bars(down), parameters);
    expect(short.action, TradeAction.sell);
    expect(short.side, PositionSide.short);
    expect(short.positionEffect, PositionEffect.open);
    expect(short.stop, greaterThan(98));

    final long = _evaluate(
      'ma_crossover_long_short',
      _bars(_mirror(down)),
      parameters,
    );
    expect(long.action, TradeAction.buy);
    expect(long.side, PositionSide.long);

    final cover = _evaluate(
      'ma_crossover_long_short',
      _bars(_mirror(down)),
      parameters,
      held: PositionSide.short,
    );
    expect(cover.action, TradeAction.buy);
    expect(cover.positionEffect, PositionEffect.close);
  });

  test('momentum long/short follows direction with bracketed exits', () {
    const parameters = {'lookback': 3.0, 'thresholdPercent': 1.0};
    final rising = [100.0, 100, 101, 102, 103, 104];
    final long = _evaluate('momentum_long_short', _bars(rising), parameters);
    expect(long.action, TradeAction.buy);
    expect(long.stop, lessThan(104));
    expect(long.target, greaterThan(104));

    final short = _evaluate(
      'momentum_long_short',
      _bars(_mirror(rising)),
      parameters,
    );
    expect(short.action, TradeAction.sell);
    expect(short.side, PositionSide.short);
    expect(short.stop, greaterThan(96));
    expect(short.target, lessThan(96));
  });

  test('Donchian breakdown shorts below the prior low and covers above', () {
    const parameters = {'lookback': 3.0, 'exitLookback': 2.0};
    final entry = _evaluate(
      'donchian_breakdown_short',
      _bars([100, 100, 100, 100, 95]),
      parameters,
    );
    expect(entry.action, TradeAction.sell);
    expect(entry.side, PositionSide.short);
    expect(entry.stop, greaterThan(95));

    final cover = _evaluate(
      'donchian_breakdown_short',
      _bars([90, 90, 90, 90, 95]),
      parameters,
      held: PositionSide.short,
    );
    expect(cover.action, TradeAction.buy);
    expect(cover.positionEffect, PositionEffect.close);
  });

  test('engine opens and covers simulated shorts with closed P&L', () {
    final engine = SimulatorEngine(
      watchlist: const ['SOXL'],
      strategies: [
        StrategySettings(
          strategyId: 'ma_crossover_long_short',
          label: 'MA L/S',
          parameters: const {'fastPeriod': 2, 'slowPeriod': 4},
        ),
      ],
      startingCash: 10000,
      enableShortSelling: true,
      includeBenchmarks: false,
    );
    final closes = [
      ...List.filled(24, 100.0),
      98, 96, 94, 92, 90, // Falling: fast crosses below slow.
      92, 95, 98, 101, 104, // Rising: cover the short.
    ];
    _bars(closes).forEach(engine.process);
    final account = engine.accounts['MA L/S']!;
    expect(account.closedTradeCount, greaterThan(0));
    expect(account.closedPnl.first, isNot(0));
  });

  group('strategy tuner', () {
    List<Candle> wave(int count) => [
      for (var index = 0; index < count; index++)
        Candle(
          symbol: 'SOXL',
          time: _open.add(Duration(minutes: index)),
          open: 100 + 8 * _triangle(index - 1),
          high: 101 + 8 * _triangle(index),
          low: 99 + 8 * _triangle(index),
          close: 100 + 8 * _triangle(index),
          volume: 1000,
        ),
    ];

    StrategyTuner tuner(
      int bars,
      List<StrategySettings> strategies, {
      int generations = 2,
      int minimumTrainingTrades = 2,
      Map<String, List<Map<String, double>>> previousTrials = const {},
    }) => StrategyTuner(
      candlesByInterval: {
        1: {'SOXL': wave(bars)},
      },
      watchlist: const ['SOXL'],
      strategies: strategies,
      risk: const TuningRisk(enableShortSelling: true),
      randomCandidates: 4,
      generations: generations,
      minimumTrainingTrades: minimumTrainingTrades,
      previousTrials: previousTrials,
    );

    final maLongShort = StrategySettings(
      strategyId: 'ma_crossover_long_short',
      label: 'MA L/S',
    );

    test(
      'later generations can show a fresh tested candidate without promoting it',
      () {
        final first = tuner(400, [
          maLongShort,
        ], minimumTrainingTrades: 10000).run().single;
        final next = tuner(
          400,
          [maLongShort],
          minimumTrainingTrades: 10000,
          previousTrials: {
            maLongShort.label: [first.candidateParameters!],
          },
        ).run().single;
        expect(next.status, 'kept');
        expect(next.tunedParameters, first.tunedParameters);
        expect(next.candidateParameters, isNot(first.candidateParameters));
        expect(next.tunedValidation!.endingEquity, isA<double>());
      },
    );

    test('skips LM selector and reports insufficient data', () {
      final results = tuner(20, [
        maLongShort,
        StrategySettings(strategyId: 'lm_selector', label: 'LM'),
      ]).run();
      expect(results[0].status, 'insufficient');
      expect(results[0].tunedParameters, results[0].currentParameters);
      expect(
        results[0].candidateParameters,
        isNot(results[0].currentParameters),
      );
      expect(results[1].status, 'skipped');
      expect(results[1].candidateParameters, isNull);
    });

    test('tests candidates deterministically on held-out data', () {
      final progress = <TuningProgress>[];
      final first = tuner(400, [
        maLongShort,
      ]).run(onProgress: progress.add).single;
      final second = tuner(400, [maLongShort]).run().single;
      expect(first.status, anyOf('improved', 'kept'));
      expect(first.candidatesTested, greaterThan(5));
      final initial = tuner(400, [maLongShort], generations: 0).run().single;
      expect(first.candidatesTested, greaterThan(initial.candidatesTested));
      expect(first.currentSelection, isNotNull);
      expect(first.currentValidation, isNotNull);
      expect(first.toJson(), second.toJson());
      expect(progress.first, (fraction: 0.0, remainingSeconds: null));
      expect(progress.last, (fraction: 1.0, remainingSeconds: 0));
      if (first.status == 'kept') {
        expect(first.tunedParameters, first.currentParameters);
      }
    });

    test('a quiet final holdout cannot select a different candidate', () {
      const count = 600;
      final active = tuner(count, [maLongShort]);
      final quiet = tuner(count, [maLongShort]);
      final bars = quiet.candlesByInterval[1]!['SOXL']!;
      final lastPrice = bars[479].close;
      for (var i = 480; i < bars.length; i++) {
        bars[i] = Candle(
          symbol: bars[i].symbol,
          time: bars[i].time,
          open: lastPrice,
          high: lastPrice,
          low: lastPrice,
          close: lastPrice,
          volume: bars[i].volume,
        );
      }
      final withActiveHoldout = active.run().single;
      final withQuietHoldout = quiet.run().single;
      expect(
        withQuietHoldout.tunedTraining!.toJson(),
        withActiveHoldout.tunedTraining!.toJson(),
      );
      expect(
        withQuietHoldout.tunedSelection!.toJson(),
        withActiveHoldout.tunedSelection!.toJson(),
      );
      expect(withQuietHoldout.tunedValidation!.trades, lessThan(2));
      expect(withQuietHoldout.status, 'kept');
      expect(
        withQuietHoldout.candidateParameters,
        isNot(withQuietHoldout.currentParameters),
      );
      expect(
        withQuietHoldout.tunedParameters,
        withQuietHoldout.currentParameters,
      );
    });
  });
}

/// Triangle wave between -1 and 1 with a 40-bar period.
double _triangle(int index) {
  final phase = (index % 40) / 40;
  return phase < .5 ? phase * 4 - 1 : 3 - phase * 4;
}
