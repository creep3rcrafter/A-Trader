/// Single-file algorithm: metadata, evolvable parameters, and decisions.
library;

import 'dart:math' as math;

import '../strategy_api.dart';
import 'helpers.dart';
import '../exchange_calendar.dart';

class InverseFairValueGapStrategy extends BuiltinStrategy {
  InverseFairValueGapStrategy()
    : super(
        id: 'inverse_fair_value_gap',
        name: 'Inverse fair value gap',
        description:
            'Trade a later retest and rejection of an inverted, confirmed '
            'three-candle gap. Bullish inversions buy LONG; bearish inversions sell SHORT.',
        warmupBars: 5,
        parameters: [
          strategyParameter('minimumGapPercent', '%', .1, 0, 10),
          strategyParameter('expiryBars', 'bars', 30, 2, 200),
          strategyParameter('stopBufferPercent', '%', .1, 0, 5),
          strategyParameter('rewardRiskRatio', 'x', 2, .1, 10),
        ],
        rule: _inverseFairValueGap,
      );
}

StrategySignal _inverseFairValueGap(StrategyContext context) {
  if (context.hasPosition) {
    return const StrategySignal(
      TradeAction.wait,
      'Holding inverse-gap position.',
    );
  }
  final bars = context.candles;
  final last = bars.length - 1;
  final expiry = context.parameter('expiryBars', 30).round();
  for (
    var formation = math.max(2, last - expiry);
    formation <= last - 2;
    formation++
  ) {
    final first = bars[formation - 2];
    final third = bars[formation];
    final bullishGap = third.low > first.high;
    final bearishGap = third.high < first.low;
    if (!bullishGap && !bearishGap) continue;
    final lower = bullishGap ? first.high : third.high;
    final upper = bullishGap ? third.low : first.low;
    if ((upper - lower) / first.close * 100 <
        context.parameter('minimumGapPercent', .1)) {
      continue;
    }
    int? inversion;
    for (var index = formation + 1; index <= last; index++) {
      final candle = bars[index];
      if (sessionDate(UsEquityCalendar.toEastern(candle.time)) !=
          sessionDate(UsEquityCalendar.toEastern(third.time))) {
        break;
      }
      if (inversion == null) {
        if (bullishGap ? candle.close < lower : candle.close > upper) {
          inversion = index;
        }
        continue;
      }
      // Reclaiming the far edge invalidates the inverse zone.
      if (bullishGap ? candle.close > upper : candle.close < lower) break;
      final rejection = bullishGap
          ? candle.high >= lower &&
                candle.low <= upper &&
                candle.close < lower &&
                candle.close < candle.open
          : candle.low <= upper &&
                candle.high >= lower &&
                candle.close > upper &&
                candle.close > candle.open;
      if (!rejection) continue;
      if (index != last) break; // A zone is consumed by its first rejection.
      final short = bullishGap;
      final buffer =
          candle.close * context.parameter('stopBufferPercent', .1) / 100;
      final stop = short
          ? math.max(upper, candle.high) + buffer
          : math.min(lower, candle.low) - buffer;
      final risk = (candle.close - stop).abs();
      return StrategySignal(
        short ? TradeAction.sell : TradeAction.buy,
        'Confirmed inverse gap retest and rejection.',
        side: short ? PositionSide.short : PositionSide.long,
        positionEffect: PositionEffect.open,
        stop: stop,
        target:
            candle.close +
            (short ? -1 : 1) * risk * context.parameter('rewardRiskRatio', 2),
        measurements: {
          'gapLower': lower,
          'gapUpper': upper,
          'inversionBar': inversion.toDouble(),
        },
      );
    }
  }
  return const StrategySignal(
    TradeAction.wait,
    'Waiting for gap, later inversion, then later rejection.',
  );
}
