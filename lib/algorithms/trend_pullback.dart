/// Single-file algorithm: metadata, evolvable parameters, and decisions.
library;

import '../strategy_api.dart';
import 'helpers.dart';

class TrendPullbackStrategy extends BuiltinStrategy {
  TrendPullbackStrategy()
    : super(
        id: 'trend_pullback',
        name: 'Trend pullback',
        description:
            'Look for a rising trend and buy when price recovers above a fast '
            'moving average after a pullback. Exit if price falls below the '
            'average-based risk level.',
        warmupBars: 12,
        parameters: [
          strategyParameter('fastPeriod', 'bars', 5, 2, 30),
          strategyParameter('trendPeriod', 'bars', 10, 4, 60),
        ],
        rule: (c) {
          final bars = c.candles;
          final fast = c.parameter('fastPeriod', 5).round();
          final trend = c.parameter('trendPeriod', 10).round();
          final ma = mean(bars.skip(bars.length - fast).map((b) => b.close));
          final oldMa = mean(
            bars.skip(bars.length - trend - 1).take(trend).map((b) => b.close),
          );
          final rising = ma > oldMa;
          if (!c.hasPosition &&
              rising &&
              bars[bars.length - 2].close < ma &&
              bars.last.close > ma) {
            return StrategySignal(
              TradeAction.buy,
              'Rising trend recovered above the fast moving average.',
              stop: ma * .97,
            );
          }
          if (c.hasPosition && bars.last.close < ma * .97) {
            return const StrategySignal(
              TradeAction.sell,
              'Pullback broke the fast-average risk level.',
            );
          }
          return StrategySignal(
            TradeAction.wait,
            rising
                ? 'Trend is rising; waiting for pullback recovery.'
                : 'Trend filter is not rising.',
            measurements: {'fastAverage': ma},
          );
        },
      );
}
