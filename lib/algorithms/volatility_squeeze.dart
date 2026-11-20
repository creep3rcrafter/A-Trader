/// Single-file algorithm: metadata, evolvable parameters, and decisions.
library;

import 'dart:math' as math;

import '../strategy_api.dart';
import 'helpers.dart';

class VolatilitySqueezeStrategy extends BuiltinStrategy {
  VolatilitySqueezeStrategy()
    : super(
        id: 'volatility_squeeze',
        name: 'Volatility squeeze',
        description:
            'Look for a period of contracting price ranges, then buy an upside '
            'breakout when the current bar expands enough. Use the prior high '
            'as the stop.',
        warmupBars: 21,
        parameters: [
          strategyParameter('contractionBars', 'bars', 10, 3, 50),
          strategyParameter('expansionRatio', 'x', 1.3, 1, 5),
          strategyParameter('maxHoldBars', 'bars', 20, 1, 200),
        ],
        rule: (c) {
          final bars = c.candles;
          final count = c.parameter('contractionBars', 10).round();
          if (c.hasPosition &&
              c.barsHeld >= c.parameter('maxHoldBars', 20).round()) {
            return const StrategySignal(
              TradeAction.sell,
              'Maximum holding time reached after the volatility breakout.',
            );
          }
          if (c.hasPosition &&
              c.positionStop != null &&
              bars.last.close <= c.positionStop!) {
            return const StrategySignal(
              TradeAction.sell,
              'Close fell back to the breakout level; exiting the squeeze trade.',
            );
          }
          if (bars.length < count * 2 + 1) {
            return StrategySignal(
              TradeAction.wait,
              'Collecting ${count * 2 + 1} bars to compare ranges '
              '(${bars.length} so far).',
            );
          }
          final recent = bars
              .skip(bars.length - count - 1)
              .take(count)
              .toList();
          final priorRange = mean(recent.map((b) => b.high - b.low));
          final currentRange = bars.last.high - bars.last.low;
          final high = recent.map((b) => b.high).reduce(math.max);
          final contracted =
              priorRange <
              mean(
                bars
                    .skip(bars.length - count * 2)
                    .take(count)
                    .map((b) => b.high - b.low),
              );
          if (!c.hasPosition &&
              contracted &&
              bars.last.close > high &&
              currentRange > priorRange * c.parameter('expansionRatio', 1.3)) {
            return StrategySignal(
              TradeAction.buy,
              'Upside breakout expanded from a contracted range.',
              stop: high,
              measurements: {
                'priorHigh': high,
                'rangeExpansion': currentRange / math.max(.01, priorRange),
              },
            );
          }
          return const StrategySignal(
            TradeAction.wait,
            'Waiting for range contraction followed by an expanding upside break.',
          );
        },
      );
}
