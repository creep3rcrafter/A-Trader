/// Single-file algorithm: metadata, evolvable parameters, and decisions.
library;

import 'dart:math' as math;

import '../strategy_api.dart';
import 'helpers.dart';

class BollingerReversionLongShortStrategy extends BuiltinStrategy {
  BollingerReversionLongShortStrategy()
    : super(
        id: 'bollinger_reversion_long_short',
        name: 'Bollinger reversion (long/short)',
        description:
            'In a weak trend, go LONG after a close back inside the lower band '
            'and SHORT after a close back inside the upper band. Exit at the '
            'middle band or after the holding limit. Shorts require short '
            'selling enabled in Risk.',
        warmupBars: 22,
        parameters: [
          strategyParameter('period', 'bars', 20, 5, 100),
          strategyParameter('deviations', 'standard deviations', 2, 1, 4),
          strategyParameter('maximumHoldBars', 'bars', 30, 1, 500),
          strategyParameter('trendLimitPercent', '%', 8, .5, 50),
        ],
        rule: _bollingerReversionLongShort,
      );
}

StrategySignal _bollingerReversionLongShort(StrategyContext c) {
  final bars = c.candles;
  final period = c.parameter('period', 20).round();
  if (bars.length < period + 1) throw RangeError('period');
  final closes = bars.skip(bars.length - period).map((b) => b.close).toList();
  final mid = mean(closes);
  final width = c.parameter('deviations', 2) * standardDeviation(closes);
  final lower = mid - width;
  final upper = mid + width;
  final close = bars.last.close;
  final prior = bars[bars.length - 2].close;
  final measurements = {
    'lowerBand': lower,
    'middleBand': mid,
    'upperBand': upper,
  };
  if (c.hasPosition) {
    final short = c.positionSide == PositionSide.short;
    final timedOut = c.barsHeld >= c.parameter('maximumHoldBars', 30).round();
    if (timedOut || (short ? close <= mid : close >= mid)) {
      return closePosition(
        c,
        'Mean-reversion target reached or holding time limit elapsed.',
      );
    }
    return StrategySignal(
      TradeAction.wait,
      'Holding ${short ? 'short' : 'long'} toward the middle band.',
      measurements: measurements,
    );
  }
  final weakTrend =
      priceReturn(bars, period).abs() * 100 <
      c.parameter('trendLimitPercent', 8);
  if (weakTrend && prior < lower && close >= lower && close < mid) {
    return longEntry(
      'Close re-entered the lower band in a weak-trend regime.',
      target: mid,
      measurements: measurements,
    );
  }
  if (weakTrend && prior > upper && close <= upper && close > mid) {
    return shortEntry(
      'Close re-entered the upper band in a weak-trend regime.',
      stop: math.max(bars.last.high, prior) + width * .25,
      target: mid,
      measurements: measurements,
    );
  }
  return StrategySignal(
    TradeAction.wait,
    weakTrend
        ? 'Waiting for a band re-entry.'
        : 'Trend is too strong for mean reversion.',
    measurements: measurements,
  );
}
