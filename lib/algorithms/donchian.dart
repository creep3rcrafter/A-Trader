/// Single-file algorithm: metadata, evolvable parameters, and decisions.
library;

import 'dart:math' as math;

import '../strategy_api.dart';
import 'helpers.dart';

class DonchianStrategy extends BuiltinStrategy {
  DonchianStrategy()
    : super(
        id: 'donchian',
        name: 'Donchian channel breakout',
        description:
            'Buy when a close breaks above the highest price of the prior '
            'lookback window. Exit if a close falls below the shorter exit '
            'channel; the current bar is excluded from the breakout threshold.',
        warmupBars: 21,
        parameters: [
          strategyParameter('lookback', 'bars', 20, 2, 100),
          strategyParameter('exitLookback', 'bars', 10, 2, 50),
        ],
        rule: (c) {
          final bars = c.candles;
          final lookback = c.parameter('lookback', 20).round();
          final prior = bars
              .skip(bars.length - lookback - 1)
              .take(lookback)
              .toList();
          final high = prior.map((b) => b.high).reduce(math.max);
          final exitCount = c.parameter('exitLookback', 10).round();
          final exitBars = bars
              .skip(math.max(0, bars.length - exitCount - 1))
              .take(exitCount)
              .toList();
          final low = exitBars.map((b) => b.low).reduce(math.min);
          if (!c.hasPosition && bars.last.close > high) {
            return StrategySignal(
              TradeAction.buy,
              'Close broke above the prior Donchian high.',
              stop: low,
              measurements: {'priorChannelHigh': high, 'exitChannelLow': low},
            );
          }
          if (c.hasPosition && bars.last.close < low) {
            return const StrategySignal(
              TradeAction.sell,
              'Close broke below the shorter exit channel.',
            );
          }
          return StrategySignal(
            TradeAction.wait,
            'Waiting for a prior-channel breakout.',
            measurements: {'priorChannelHigh': high},
          );
        },
      );
}
