/// Single-file algorithm: metadata, evolvable parameters, and decisions.
library;

import 'dart:math' as math;

import '../strategy_api.dart';
import 'helpers.dart';

class DonchianBreakdownShortStrategy extends BuiltinStrategy {
  DonchianBreakdownShortStrategy()
    : super(
        id: 'donchian_breakdown_short',
        name: 'Donchian breakdown (short)',
        description:
            'SHORT when a close breaks below the lowest low of the prior '
            'lookback window. Cover when a close rises above the shorter exit '
            'channel high. Short entries require short selling enabled in Risk.',
        warmupBars: 21,
        parameters: [
          strategyParameter('lookback', 'bars', 20, 2, 100),
          strategyParameter('exitLookback', 'bars', 10, 2, 50),
        ],
        rule: _donchianBreakdownShort,
      );
}

StrategySignal _donchianBreakdownShort(StrategyContext c) {
  final bars = c.candles;
  final lookback = c.parameter('lookback', 20).round();
  final exitCount = c.parameter('exitLookback', 10).round();
  final prior = bars.skip(bars.length - lookback - 1).take(lookback).toList();
  if (prior.length < lookback) throw RangeError('lookback');
  final low = prior.map((b) => b.low).reduce(math.min);
  final exitBars = bars
      .skip(math.max(0, bars.length - exitCount - 1))
      .take(exitCount)
      .toList();
  final exitHigh = exitBars.map((b) => b.high).reduce(math.max);
  final measurements = {'priorChannelLow': low, 'exitChannelHigh': exitHigh};
  if (c.hasPosition) {
    if (c.positionSide == PositionSide.short && bars.last.close > exitHigh) {
      return closePosition(
        c,
        'Close rose above the shorter exit channel high; cover the short.',
      );
    }
    return StrategySignal(
      TradeAction.wait,
      'Holding the breakdown short.',
      measurements: measurements,
    );
  }
  if (bars.last.close < low) {
    return shortEntry(
      'Close broke below the prior Donchian low.',
      stop: exitHigh,
      measurements: measurements,
    );
  }
  return StrategySignal(
    TradeAction.wait,
    'Waiting for a prior-channel breakdown.',
    measurements: measurements,
  );
}
