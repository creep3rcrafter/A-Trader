// Copy this file, give the strategy a unique ID/name, then edit evaluate().
// Import it using Simulation controls > Add algorithm from file.
// See README.md in this folder for the single-file contract and SDK requirement.
import 'package:atrader/strategy_api.dart';

class TemplateSmaStrategy implements TradingStrategy {
  const TemplateSmaStrategy();

  @override
  String get id => 'template_sma';

  @override
  String get name => 'Template: SMA distance';

  @override
  String get description =>
      'Buy above a moving average; exit below it. Long positions only.';

  // Covers the largest allowed lookback, so tuning has enough closed bars.
  @override
  int get warmupBars => 200;

  // Expose every number you want evolution to change here. Fractions use
  // decimal values: 0.005 = 0.5%, 0.02 = 2%.
  @override
  List<StrategyParameter> get parameters => const [
    StrategyParameter(
      name: 'lookback',
      label: 'Moving average lookback',
      unit: 'bars',
      defaultValue: 20,
      minimum: 2,
      maximum: 200,
    ),
    StrategyParameter(
      name: 'entryThreshold',
      label: 'Distance above average to enter',
      unit: 'fraction',
      defaultValue: 0.005,
      minimum: 0,
      maximum: 0.1,
    ),
    StrategyParameter(
      name: 'stopFraction',
      label: 'Protective stop distance',
      unit: 'fraction',
      defaultValue: 0.02,
      minimum: 0.001,
      maximum: 0.1,
    ),
  ];

  @override
  StrategySignal evaluate(StrategyContext context) {
    final lookback = _parameter(context, 'lookback').round();
    final entryThreshold = _parameter(context, 'entryThreshold');
    final stopFraction = _parameter(context, 'stopFraction');

    if (context.candles.length < lookback) {
      return const StrategySignal(TradeAction.wait, 'Waiting for closed bars.');
    }
    if (context.hasPosition && context.positionSide != PositionSide.long) {
      return const StrategySignal(
        TradeAction.wait,
        'This template manages long positions only.',
      );
    }

    // Only use completed candles supplied by the simulator. Avoid global or
    // static mutable state: each portfolio/candidate must be independent.
    final bars = context.candles;
    var total = 0.0;
    for (var index = bars.length - lookback; index < bars.length; index++) {
      final price = bars[index].close;
      if (!price.isFinite || price <= 0) {
        return const StrategySignal(TradeAction.wait, 'Invalid closing price.');
      }
      total += price;
    }
    final average = total / lookback;
    if (!average.isFinite || average <= 0) {
      return const StrategySignal(TradeAction.wait, 'Invalid moving average.');
    }
    final close = context.current.close;
    final distance = close / average - 1;
    final measurements = {'average': average, 'distance': distance};

    // EDIT YOUR DECISION LOGIC HERE. Returning a signal lets the simulator
    // apply its risk checks and later-event fills; this never places an order.
    if (context.hasPosition && distance < 0) {
      return StrategySignal(
        TradeAction.sell,
        'Close fell below the moving average.',
        positionEffect: PositionEffect.close,
        measurements: measurements,
      );
    }
    if (!context.hasPosition && distance > entryThreshold) {
      return StrategySignal(
        TradeAction.buy,
        'Close is above the moving average by the entry threshold.',
        positionEffect: PositionEffect.open,
        stop: close * (1 - stopFraction),
        measurements: measurements,
      );
    }
    return StrategySignal(
      TradeAction.wait,
      'No entry or exit condition matched.',
      measurements: measurements,
    );
  }

  double _parameter(StrategyContext context, String name) {
    final definition = parameters.firstWhere((item) => item.name == name);
    final value = context.parameter(name, definition.defaultValue);
    return value.isFinite
        ? value.clamp(definition.minimum, definition.maximum).toDouble()
        : definition.defaultValue;
  }
}
