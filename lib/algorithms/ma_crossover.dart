/// Single-file algorithm: metadata, evolvable parameters, and decisions.
library;

import '../strategy_api.dart';
import 'helpers.dart';

class MaCrossoverStrategy extends BuiltinStrategy {
  MaCrossoverStrategy()
    : super(
        id: 'ma_crossover',
        name: 'Moving-average crossover',
        description:
            'Buy when the faster moving average crosses above the slower one. '
            'Exit when it crosses back below, or when a shared exit rule applies.',
        warmupBars: 22,
        parameters: [
          strategyParameter('fastPeriod', 'bars', 5, 2, 30),
          strategyParameter('slowPeriod', 'bars', 20, 4, 100),
        ],
        rule: (c) {
          final bars = c.candles;
          final fast = c.parameter('fastPeriod', 5).round();
          final slow = c.parameter('slowPeriod', 20).round();
          final currentFast = mean(
            bars.skip(bars.length - fast).map((b) => b.close),
          );
          final currentSlow = mean(
            bars.skip(bars.length - slow).map((b) => b.close),
          );
          final previousFast = mean(
            bars.skip(bars.length - fast - 1).take(fast).map((b) => b.close),
          );
          final previousSlow = mean(
            bars.skip(bars.length - slow - 1).take(slow).map((b) => b.close),
          );
          if (!c.hasPosition &&
              previousFast <= previousSlow &&
              currentFast > currentSlow) {
            return const StrategySignal(
              TradeAction.buy,
              'Fast average crossed above slow average.',
            );
          }
          if (c.hasPosition &&
              previousFast >= previousSlow &&
              currentFast < currentSlow) {
            return const StrategySignal(
              TradeAction.sell,
              'Fast average crossed below slow average.',
            );
          }
          return const StrategySignal(
            TradeAction.wait,
            'No new moving-average crossover.',
          );
        },
      );
}
