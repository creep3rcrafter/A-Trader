/// Shared indicator and signal helpers for algorithm files.
library;

import 'dart:math' as math;

import '../strategy_api.dart';

StrategyParameter strategyParameter(
  String name,
  String unit,
  double value, [
  double min = 1,
  double max = 100,
]) => StrategyParameter(
  name: name,
  unit: unit,
  defaultValue: value,
  minimum: min,
  maximum: max,
);

double mean(Iterable<double> values) {
  final list = values.toList();
  return list.isEmpty ? 0 : list.reduce((a, b) => a + b) / list.length;
}

double standardDeviation(List<double> values) {
  if (values.isEmpty) return 0;
  final center = mean(values);
  return math.sqrt(
    mean(values.map((value) => math.pow(value - center, 2).toDouble())),
  );
}

double priceReturn(List<Candle> bars, int lookback) {
  if (bars.length <= lookback) return 0;
  final prior = bars[bars.length - 1 - lookback].close;
  return prior == 0 ? 0 : bars.last.close / prior - 1;
}

int sessionStartIndex(List<Candle> bars) {
  final date = bars.last.time;
  for (var index = bars.length - 1; index >= 0; index--) {
    final time = bars[index].time;
    if (time.year != date.year ||
        time.month != date.month ||
        time.day != date.day) {
      return index + 1;
    }
  }
  return 0;
}

String sessionDate(DateTime time) => '${time.year}-${time.month}-${time.day}';

double averageVolume(List<Candle> bars, int count) =>
    mean(bars.skip(math.max(0, bars.length - count)).map((bar) => bar.volume));

StrategySignal shortEntry(
  String reason, {
  required double stop,
  double? target,
  Map<String, double> measurements = const {},
}) => StrategySignal(
  TradeAction.sell,
  reason,
  side: PositionSide.short,
  positionEffect: PositionEffect.open,
  stop: stop,
  target: target,
  measurements: measurements,
);

StrategySignal longEntry(
  String reason, {
  double? stop,
  double? target,
  Map<String, double> measurements = const {},
}) => StrategySignal(
  TradeAction.buy,
  reason,
  positionEffect: PositionEffect.open,
  stop: stop,
  target: target,
  measurements: measurements,
);

/// Closes whichever side is held: SELL closes a long, BUY covers a short.
StrategySignal closePosition(StrategyContext c, String reason) =>
    StrategySignal(
      c.positionSide == PositionSide.short ? TradeAction.buy : TradeAction.sell,
      reason,
      side: c.positionSide,
      positionEffect: PositionEffect.close,
    );

double sessionVwap(List<Candle> bars, int sessionStart) {
  var pv = 0.0;
  var volume = 0.0;
  for (final bar in bars.skip(sessionStart)) {
    pv += (bar.high + bar.low + bar.close) / 3 * bar.volume;
    volume += bar.volume;
  }
  return volume == 0 ? bars.last.close : pv / volume;
}

double averageClose(List<Candle> bars, int period, [int offset = 0]) {
  final end = bars.length - offset;
  if (period <= 0 || end - period < 0) throw RangeError('period');
  var total = 0.0;
  for (var index = end - period; index < end; index++) {
    total += bars[index].close;
  }
  return total / period;
}
