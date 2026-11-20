/// Single-file algorithm: metadata, evolvable parameters, and decisions.
library;

import 'dart:math' as math;

import '../strategy_api.dart';
import 'helpers.dart';

class OpeningRangeStrategy extends BuiltinStrategy {
  OpeningRangeStrategy()
    : super(
        id: 'opening_range',
        name: 'Opening-range breakout',
        description:
            'Record the opening range, then buy a close above it when volume '
            'is high enough compared with recent bars. Exit if the close falls '
            'back below the range high.',
        warmupBars: 8,
        parameters: [
          strategyParameter('rangeMinutes', 'minutes', 5, 1, 60),
          strategyParameter('relativeVolume', 'x', 1.2, .5, 5),
        ],
        rule: (c) {
          final bars = c.candles;
          final start = sessionStartIndex(bars);
          final rangeLength = c.parameter('rangeMinutes', 5).round();
          final rangeBars = (rangeLength / c.intervalMinutes).ceil();
          if (c.sessionElapsedMinutes == null ||
              c.sessionElapsedMinutes! < rangeLength ||
              bars.length - start < rangeBars) {
            return const StrategySignal(
              TradeAction.wait,
              'Building the regular-session opening range.',
            );
          }
          final range = bars.skip(start).take(rangeBars).toList();
          final high = range.map((bar) => bar.high).reduce(math.max);
          final relativeVolume =
              bars.last.volume /
              math.max(
                1,
                averageVolume(bars.take(bars.length - 1).toList(), 20),
              );
          if (!c.hasPosition &&
              bars.last.close > high &&
              relativeVolume >= c.parameter('relativeVolume', 1.2)) {
            return StrategySignal(
              TradeAction.buy,
              'Confirmed opening-range break with relative volume.',
              stop: range.map((bar) => bar.low).reduce(math.min),
              measurements: {
                'rangeHigh': high,
                'relativeVolume': relativeVolume,
              },
            );
          }
          if (c.hasPosition && bars.last.close < high) {
            return const StrategySignal(
              TradeAction.sell,
              'Failed break fell back inside the opening range.',
            );
          }
          return StrategySignal(
            TradeAction.wait,
            'Waiting for a volume-confirmed opening-range break.',
            measurements: {'rangeHigh': high, 'relativeVolume': relativeVolume},
          );
        },
      );
}
