/// Single-file algorithm: metadata, evolvable parameters, and decisions.
library;

import '../strategy_api.dart';
import 'helpers.dart';

class FirstHalfHourStrategy extends BuiltinStrategy {
  FirstHalfHourStrategy()
    : super(
        id: 'first_half_hour',
        name: 'First-half-hour momentum',
        description:
            'Measure the first 30 minutes against a prior close captured during '
            'the run. In the final 30 minutes, buy if that move was strong '
            'enough and price continues higher.',
        warmupBars: 31,
        parameters: [strategyParameter('minimumMovePercent', '%', .5, 0, 10)],
        rule: (c) {
          final bars = c.candles;
          final start = sessionStartIndex(bars);
          final elapsed = c.sessionElapsedMinutes;
          final sessionLength = c.sessionLengthMinutes;
          if (start == 0 ||
              elapsed == null ||
              sessionLength == null ||
              elapsed < 30 ||
              bars.length <= start) {
            return const StrategySignal(
              TradeAction.wait,
              'Waiting for a prior close captured during this run and first-half-hour data.',
            );
          }
          final firstHalfBars = (30 / c.intervalMinutes).ceil();
          if (bars.length < start + firstHalfBars) {
            return const StrategySignal(
              TradeAction.wait,
              'Waiting for first-half-hour bars and the session close window.',
            );
          }
          final move =
              bars[start + firstHalfBars - 1].close / bars[start - 1].close - 1;
          final inFinalWindow = elapsed >= sessionLength - 30;
          if (!c.hasPosition &&
              inFinalWindow &&
              move >= c.parameter('minimumMovePercent', .5) / 100 &&
              bars.last.close > bars[start + firstHalfBars - 1].close) {
            return StrategySignal(
              TradeAction.buy,
              'First-half-hour strength confirmed in the final 30 session minutes.',
              stop: bars[start + firstHalfBars - 1].close,
            );
          }
          if (c.hasPosition && elapsed >= sessionLength) {
            return const StrategySignal(
              TradeAction.sell,
              'Session cutoff reached.',
            );
          }
          return StrategySignal(
            TradeAction.wait,
            inFinalWindow
                ? 'Waiting for continuation of first-half-hour strength.'
                : 'Outside the final-30-minute entry window.',
            measurements: {'firstHalfHourReturnPercent': move * 100},
          );
        },
      );
}
