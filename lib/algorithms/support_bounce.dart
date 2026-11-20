/// Single-file algorithm: metadata, evolvable parameters, and decisions.
library;

import '../strategy_api.dart';
import 'helpers.dart';

class SupportBounceStrategy extends BuiltinStrategy {
  SupportBounceStrategy()
    : super(
        id: 'support_bounce',
        name: 'Support bounce',
        description:
            'Find a support level from a confirmed pivot low. Buy after price '
            'retests that level and recovers; exit if price closes below the '
            'support invalidation level.',
        warmupBars: 12,
        parameters: [
          strategyParameter('pivotWindow', 'bars', 3, 1, 10),
          strategyParameter('tolerancePercent', '%', .5, .1, 5),
        ],
        rule: (c) {
          final bars = c.candles;
          final window = c.parameter('pivotWindow', 3).round();
          final tolerance = c.parameter('tolerancePercent', .5) / 100;
          var supportIndex = -1;
          for (var index = window; index < bars.length - window; index++) {
            final candidate = bars[index].low;
            final left = bars.skip(index - window).take(window);
            final right = bars.skip(index + 1).take(window);
            if (left.every((bar) => candidate < bar.low) &&
                right.every((bar) => candidate <= bar.low)) {
              supportIndex = index;
            }
          }
          if (supportIndex < 0) {
            return const StrategySignal(
              TradeAction.wait,
              'Waiting for a support pivot to be confirmed by later candles.',
            );
          }
          final support = bars[supportIndex].low;
          final previous = bars[bars.length - 2];
          final retested =
              previous.low <= support * (1 + tolerance) &&
              previous.low >= support * (1 - tolerance);
          if (!c.hasPosition && retested && bars.last.close > previous.close) {
            return StrategySignal(
              TradeAction.buy,
              'Confirmed support retest recovered above the prior close.',
              stop: support * (1 - tolerance),
              measurements: {'support': support},
            );
          }
          if (c.hasPosition && bars.last.close < support * (1 - tolerance)) {
            return StrategySignal(
              TradeAction.sell,
              'Price closed below confirmed support invalidation.',
              measurements: {'support': support},
            );
          }
          return StrategySignal(
            TradeAction.wait,
            'Waiting for a retest and recovery at confirmed support.',
            measurements: {'support': support},
          );
        },
      );
}
