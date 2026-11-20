/// Single-file algorithm: metadata, evolvable parameters, and decisions.
library;

import 'dart:math' as math;

import '../strategy_api.dart';
import 'helpers.dart';

class RuleSelectorStrategy extends BuiltinStrategy {
  RuleSelectorStrategy()
    : super(
        id: 'rule_selector',
        name: 'Rule-based strategy selector',
        description:
            'Use fixed trend and volatility thresholds to select a market regime. '
            'Trend and breakout regimes may open trades; mean-reversion and cash '
            'selections do not open new positions.',
        warmupBars: 22,
        parameters: [
          strategyParameter('trendThresholdPercent', '%', 2, 0, 30),
          strategyParameter('volatilityThresholdPercent', '%', 5, .1, 50),
        ],
        rule: (c) {
          final trend = priceReturn(c.candles, 20);
          final volatility =
              standardDeviation(
                c.candles
                    .skip(c.candles.length - 20)
                    .map((b) => b.close)
                    .toList(),
              ) /
              math.max(.01, c.current.close) *
              100;
          final selected = trend > c.parameter('trendThresholdPercent', 2) / 100
              ? 'trend'
              : volatility > c.parameter('volatilityThresholdPercent', 5)
              ? 'breakout'
              : trend < 0
              ? 'mean reversion'
              : 'cash';
          final previous = c.candles[c.candles.length - 2];
          if (!c.hasPosition &&
              selected == 'trend' &&
              c.current.close > previous.close) {
            return StrategySignal(
              TradeAction.buy,
              'Rule selected trend: positive 20-bar return and rising close.',
              stop: c.current.close * .97,
              measurements: {
                'return20Percent': trend * 100,
                'volatilityPercent': volatility.toDouble(),
              },
            );
          }
          if (!c.hasPosition &&
              selected == 'breakout' &&
              c.current.close > previous.high) {
            return StrategySignal(
              TradeAction.buy,
              'Rule selected breakout: volatility threshold and prior-high break.',
              stop: previous.low,
              measurements: {
                'return20Percent': trend * 100,
                'volatilityPercent': volatility,
              },
            );
          }
          if (c.hasPosition &&
              (selected == 'cash' ||
                  c.current.close < (c.entryPrice ?? c.current.close) * .97)) {
            return StrategySignal(
              TradeAction.sell,
              'Rule selected $selected; exit the existing long position.',
            );
          }
          return StrategySignal(
            TradeAction.wait,
            'Rule selected $selected; no eligible entry.',
            measurements: {
              'return20Percent': trend * 100,
              'volatilityPercent': volatility,
            },
          );
        },
      );
}
