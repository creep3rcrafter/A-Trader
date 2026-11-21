/// Shared contract for single-file trading algorithms and the simulator.
library;

enum TradeAction { buy, sell, wait }

enum PositionSide { long, short }

enum PositionEffect { open, close }

enum RunMode { liveSimulation }

class Candle {
  const Candle({
    required this.symbol,
    required this.time,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    required this.volume,
  });

  final String symbol;
  final DateTime time;
  final double open;
  final double high;
  final double low;
  final double close;
  final double volume;

  String get key => '$symbol:${time.toUtc().microsecondsSinceEpoch}';
}

class StrategyParameter {
  const StrategyParameter({
    required this.name,
    required this.unit,
    required this.defaultValue,
    required this.minimum,
    required this.maximum,
    this.label,
  });

  final String name;
  final String? label;
  final String unit;
  final double defaultValue;
  final double minimum;
  final double maximum;
}

class StrategyContext {
  const StrategyContext({
    required this.candles,
    required this.watchlist,
    required this.hasPosition,
    required this.entryPrice,
    this.positionStop,
    this.positionSide = PositionSide.long,
    required this.parameters,
    this.intervalMinutes = 1,
    this.sessionElapsedMinutes,
    this.sessionLengthMinutes,
    this.barsHeld = 0,
    this.portfolioLabel = '',
    this.executionId = '',
  });

  final List<Candle> candles;
  final Map<String, List<Candle>> watchlist;
  final bool hasPosition;
  final double? entryPrice;
  final double? positionStop;
  final PositionSide positionSide;
  final Map<String, double> parameters;
  final int intervalMinutes;
  final int? sessionElapsedMinutes;
  final int? sessionLengthMinutes;
  final int barsHeld;
  final String portfolioLabel;

  /// Runtime scope for imported algorithm instances; distinct for each engine.
  final String executionId;

  Candle get current => candles.last;
  double parameter(String key, double fallback) => parameters[key] ?? fallback;
}

class StrategySignal {
  const StrategySignal(
    this.action,
    this.reason, {
    this.stop,
    this.target,
    this.measurements = const {},
    this.sourceStrategyId,
    this.sourceStrategyParameters = const {},
    this.side = PositionSide.long,
    this.positionEffect,
  });

  final TradeAction action;
  final PositionSide side;
  PositionSide get positionSide => side;
  final PositionEffect? positionEffect;
  final String reason;
  final double? stop;
  final double? target;
  final Map<String, double> measurements;
  final String? sourceStrategyId;
  final Map<String, double> sourceStrategyParameters;
}

abstract interface class TradingStrategy {
  String get id;
  String get name;
  String get description;
  int get warmupBars;
  List<StrategyParameter> get parameters;
  StrategySignal evaluate(StrategyContext context);
}

/// Optional transport optimization: candidates on the same closed candle share
/// one market-data message. Results must retain the supplied context order.
abstract interface class BatchTradingStrategy implements TradingStrategy {
  List<StrategySignal> evaluateBatch(List<StrategyContext> contexts);
}

abstract interface class StrategyExecutionHealth {
  String? get executionError;
}

/// Optional compiled-worker replay using the same simulator and fill rules.
abstract interface class CandidateReplayStrategy implements TradingStrategy {
  Map<String, dynamic> replayCandidates({
    required Map<String, Object?> checkpoint,
    required List<Map<String, Object?>> strategies,
    required List<Candle> bars,
    required List<DateTime> cuts,
    bool retainEvents = false,
    bool retainFills = false,
    void Function(int completedBars)? onProgress,
  });
}

typedef StrategyRule = StrategySignal Function(StrategyContext context);

class BuiltinStrategy implements TradingStrategy {
  const BuiltinStrategy({
    required this.id,
    required this.name,
    required this.description,
    required this.warmupBars,
    required this.parameters,
    required this.rule,
  });

  @override
  final String id;
  @override
  final String name;
  @override
  final String description;
  @override
  final int warmupBars;
  @override
  final List<StrategyParameter> parameters;
  final StrategyRule rule;

  /// Edited lookback parameters can need more history than [warmupBars];
  /// such rules wait for more live bars instead of failing the run.
  @override
  StrategySignal evaluate(StrategyContext context) {
    try {
      return rule(context);
    } on RangeError {
      return StrategySignal(
        TradeAction.wait,
        'Collecting more completed bars for the current parameters '
        '(${context.candles.length} so far).',
      );
    } on StateError {
      return StrategySignal(
        TradeAction.wait,
        'Collecting more completed bars for the current parameters '
        '(${context.candles.length} so far).',
      );
    }
  }
}
