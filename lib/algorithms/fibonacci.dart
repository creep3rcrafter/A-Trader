/// Single-file algorithm: metadata, evolvable parameters, and decisions.
library;

import 'dart:math' as math;

import '../strategy_api.dart';
import 'helpers.dart';

class FibonacciStrategy extends BuiltinStrategy {
  FibonacciStrategy()
    : super(
        id: 'fibonacci',
        name: 'Fibonacci retracement',
        description:
            'Find a confirmed upward price swing, then buy if a pullback into '
            'the 38.2%–61.8% retracement zone recovers. The swing low is the '
            'stop and the swing high or an extension is the target.',
        warmupBars: 14,
        parameters: [
          strategyParameter('pivotWindow', 'bars', 3, 1, 10),
          strategyParameter('retracementLevel', 'ratio', .5, .382, .618),
          strategyParameter('extension', 'x', 1.618, 1, 3),
        ],
        rule: (c) {
          final window = c.parameter('pivotWindow', 3).round();
          final bars = c.candles;
          if (bars.length < window * 2 + 5) {
            return const StrategySignal(
              TradeAction.wait,
              'Waiting for confirmed swing pivots.',
            );
          }
          final end = bars.length - window;
          var lowIndex = -1;
          for (var i = math.max(window, end - 24); i < end; i++) {
            final low = bars[i].low;
            final confirmed =
                bars.skip(i - window).take(window).every((b) => low <= b.low) &&
                bars.skip(i + 1).take(window).every((b) => low <= b.low);
            if (confirmed) lowIndex = i;
          }
          if (lowIndex < 0 || lowIndex >= bars.length - 2) {
            return const StrategySignal(
              TradeAction.wait,
              'No confirmed upward swing is available yet.',
            );
          }
          var highIndex = -1;
          for (var i = lowIndex + 1; i < bars.length - window; i++) {
            final high = bars[i].high;
            final confirmed =
                bars
                    .skip(i - window)
                    .take(window)
                    .every((b) => high >= b.high) &&
                bars.skip(i + 1).take(window).every((b) => high > b.high);
            if (confirmed && (highIndex < 0 || high > bars[highIndex].high)) {
              highIndex = i;
            }
          }
          if (highIndex < 0) {
            return const StrategySignal(
              TradeAction.wait,
              'The swing high is not confirmed by later candles.',
            );
          }
          final low = bars[lowIndex].low;
          final high = bars[highIndex].high;
          final swing = high - low;
          if (swing <= 0) {
            return const StrategySignal(
              TradeAction.wait,
              'The swing high is not confirmed by later bars.',
            );
          }
          final retracement = c.parameter('retracementLevel', .5);
          final level = high - swing * retracement;
          final previous = bars[bars.length - 2];
          final current = bars.last;
          final zoneLow = high - swing * .618;
          final zoneHigh = high - swing * .382;
          final recovered =
              previous.low <= zoneHigh &&
              previous.low >= zoneLow &&
              current.close > previous.close &&
              current.close >= level;
          if (c.hasPosition && current.close < low) {
            return StrategySignal(
              TradeAction.sell,
              'Price invalidated the confirmed swing low.',
            );
          }
          if (!c.hasPosition &&
              recovered &&
              current.close <= high - swing * .382) {
            return StrategySignal(
              TradeAction.buy,
              'Pullback recovered through the ${(retracement * 100).round()}% retracement zone.',
              stop: low,
              target: high + swing * (c.parameter('extension', 1.618) - 1),
              measurements: {
                'swingLow': low,
                'swingHigh': high,
                'retracement': level,
                'zoneLow': zoneLow,
                'zoneHigh': zoneHigh,
              },
            );
          }
          return StrategySignal(
            TradeAction.wait,
            'Waiting for recovery at the 38.2%, 50%, or 61.8% pullback zone.',
            measurements: {
              'swingLow': low,
              'swingHigh': high,
              'retracement': level,
              'zoneLow': zoneLow,
              'zoneHigh': zoneHigh,
            },
          );
        },
      );
}
