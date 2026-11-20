/// Single-file algorithm: metadata, evolvable parameters, and decisions.
library;

import 'dart:math' as math;

import '../strategy_api.dart';
import 'helpers.dart';

class OpeningRangeBreakdownShortStrategy extends BuiltinStrategy {
  OpeningRangeBreakdownShortStrategy()
    : super(
        id: 'opening_range_breakdown_short',
        name: 'Opening-range breakdown (short)',
        description:
            'Record the opening range, then SHORT a close below it when volume '
            'is high enough compared with recent bars. Cover if the close '
            'climbs back above the range low. Requires short selling enabled.',
        warmupBars: 8,
        parameters: [
          strategyParameter('rangeMinutes', 'minutes', 5, 1, 60),
          strategyParameter('relativeVolume', 'x', 1.2, .5, 5),
        ],
        rule: _openingRangeBreakdownShort,
      );
}

StrategySignal _openingRangeBreakdownShort(StrategyContext c) {
  final bars = c.candles;
  final start = sessionStartIndex(bars);
  final rangeLength = c.parameter('rangeMinutes', 5).round();
  final rangeBars = (rangeLength / c.intervalMinutes).ceil();
  if (c.sessionElapsedMinutes == null ||
      c.sessionElapsedMinutes! < rangeLength ||
      bars.length - start < rangeBars) {
    return const StrategySignal(
      TradeAction.wait,
      'Building the regular-session opening range.',
    );
  }
  final range = bars.skip(start).take(rangeBars).toList();
  final low = range.map((bar) => bar.low).reduce(math.min);
  final high = range.map((bar) => bar.high).reduce(math.max);
  final relativeVolume =
      bars.last.volume /
      math.max(1, averageVolume(bars.take(bars.length - 1).toList(), 20));
  final measurements = {
    'rangeLow': low,
    'rangeHigh': high,
    'relativeVolume': relativeVolume,
  };
  if (c.hasPosition) {
    if (c.positionSide == PositionSide.short && bars.last.close > low) {
      return closePosition(
        c,
        'Failed breakdown climbed back inside the opening range.',
      );
    }
    return StrategySignal(
      TradeAction.wait,
      'Holding the opening-range breakdown short.',
      measurements: measurements,
    );
  }
  if (bars.last.close < low &&
      relativeVolume >= c.parameter('relativeVolume', 1.2)) {
    return shortEntry(
      'Confirmed opening-range breakdown with relative volume.',
      stop: high,
      measurements: measurements,
    );
  }
  return StrategySignal(
    TradeAction.wait,
    'Waiting for a volume-confirmed opening-range breakdown.',
    measurements: measurements,
  );
}
