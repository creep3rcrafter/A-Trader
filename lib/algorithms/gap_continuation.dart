/// Single-file algorithm: metadata, evolvable parameters, and decisions.
library;

import 'dart:math' as math;

import '../strategy_api.dart';
import 'helpers.dart';

class GapContinuationStrategy extends BuiltinStrategy {
  GapContinuationStrategy()
    : super(
        id: 'gap_continuation',
        name: 'Gap-up continuation',
        description:
            'Compare the session open with a prior close observed during this '
            'run. Buy if a large enough gap holds above the open and breaks the '
            'early-session range.',
        warmupBars: 3,
        parameters: [
          strategyParameter('minimumGapPercent', '%', 1, 0, 20),
          strategyParameter('rangeBars', 'bars', 5, 1, 30),
        ],
        rule: (c) {
          final bars = c.candles;
          final start = sessionStartIndex(bars);
          if (start == 0 || bars.length <= start) {
            return const StrategySignal(
              TradeAction.wait,
              'Waiting for a prior close captured during this run and session open.',
            );
          }
          final priorClose = bars[start - 1].close;
          final gap = bars[start].open / priorClose - 1;
          if (bars.length < start + c.parameter('rangeBars', 5).round()) {
            return StrategySignal(
              TradeAction.wait,
              'Waiting for prior close and early-session range.',
              measurements: {'gapPercent': gap * 100},
            );
          }
          final early = bars
              .skip(start)
              .take(c.parameter('rangeBars', 5).round())
              .toList();
          final high = early.map((b) => b.high).reduce(math.max);
          if (!c.hasPosition &&
              gap >= c.parameter('minimumGapPercent', 1) / 100 &&
              bars.last.close > high &&
              bars.last.close > bars[start].open) {
            return StrategySignal(
              TradeAction.buy,
              'Qualifying gap held above its open and broke the early range.',
              stop: bars[start].open,
              measurements: {'gapPercent': gap * 100, 'earlyRangeHigh': high},
            );
          }
          return StrategySignal(
            TradeAction.wait,
            'Waiting for a qualifying gap to hold and break the early range.',
            measurements: {'gapPercent': gap * 100, 'earlyRangeHigh': high},
          );
        },
      );
}
