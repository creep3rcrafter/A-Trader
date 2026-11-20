/// Single-file algorithm: metadata, evolvable parameters, and decisions.
library;

import '../strategy_api.dart';
import 'helpers.dart';

class MomentumLongShortStrategy extends BuiltinStrategy {
  MomentumLongShortStrategy()
    : super(
        id: 'momentum_long_short',
        name: 'Momentum (long/short)',
        description:
            'Go LONG when the lookback return exceeds the threshold above '
            'estimated session VWAP, or SHORT when it falls below the negative '
            'threshold under VWAP. Exit when price crosses VWAP or after the '
            'holding limit. Shorts require short selling enabled in Risk.',
        warmupBars: 12,
        parameters: [
          strategyParameter('lookback', 'bars', 10, 2, 100),
          strategyParameter('thresholdPercent', '%', 1, .1, 10),
          strategyParameter('stopPercent', '%', 1, .1, 10),
          strategyParameter('rewardRiskRatio', 'x', 2, .5, 10),
          strategyParameter('maxHoldBars', 'bars', 20, 1, 500),
        ],
        rule: _momentumLongShort,
      );
}

StrategySignal _momentumLongShort(StrategyContext c) {
  final bars = c.candles;
  final lookback = c.parameter('lookback', 10).round();
  if (bars.length <= lookback) throw RangeError('lookback');
  final change = priceReturn(bars, lookback) * 100;
  final vwap = sessionVwap(bars, sessionStartIndex(bars));
  final close = bars.last.close;
  final measurements = {'returnPercent': change, 'estimatedVwap': vwap};
  if (c.hasPosition) {
    final short = c.positionSide == PositionSide.short;
    final timedOut = c.barsHeld >= c.parameter('maxHoldBars', 20).round();
    if (timedOut || (short ? close > vwap : close < vwap)) {
      return closePosition(
        c,
        timedOut
            ? 'Momentum holding limit elapsed.'
            : 'Price crossed back through estimated VWAP.',
      );
    }
    return StrategySignal(
      TradeAction.wait,
      'Holding ${short ? 'short' : 'long'} momentum.',
      measurements: measurements,
    );
  }
  final threshold = c.parameter('thresholdPercent', 1);
  final stopFraction = c.parameter('stopPercent', 1) / 100;
  final reward = c.parameter('rewardRiskRatio', 2) * stopFraction;
  if (change >= threshold && close > vwap) {
    return longEntry(
      'Upside momentum of ${change.toStringAsFixed(2)}% above VWAP.',
      stop: close * (1 - stopFraction),
      target: close * (1 + reward),
      measurements: measurements,
    );
  }
  if (change <= -threshold && close < vwap) {
    return shortEntry(
      'Downside momentum of ${change.toStringAsFixed(2)}% below VWAP.',
      stop: close * (1 + stopFraction),
      target: close * (1 - reward),
      measurements: measurements,
    );
  }
  return StrategySignal(
    TradeAction.wait,
    'Momentum ${change.toStringAsFixed(2)}% has not reached ±${threshold.toStringAsFixed(2)}% on the VWAP side.',
    measurements: measurements,
  );
}
