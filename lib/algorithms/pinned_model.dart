/// Shared inference for neural-network and logistic-regression algorithms.
library;

import '../strategy_api.dart';
import '../training.dart';
import 'model_features.dart';

/// Long-only simulation adapter. The model never changes during this run.
///
/// Parameter definitions belong to StrategyRegistry; pass its schema here.
class PinnedModelStrategy implements TradingStrategy {
  PinnedModelStrategy({
    required this.id,
    required this.model,
    this.parameters = const [],
  }) {
    final expectedKind = id == 'neural_network'
        ? 'neural'
        : id == 'logistic_regression'
        ? 'logistic'
        : null;
    if (expectedKind == null ||
        (model != null &&
            (model!.kind != expectedKind ||
                !model!.validationPassed ||
                model!.featureSchema != liveModelFeatureSchema ||
                model!.means.length != liveModelFeatureNames.length))) {
      throw ArgumentError(
        'A compatible validated pinned live model is required.',
      );
    }
  }

  @override
  final String id;
  final TrainedModel? model;
  @override
  final List<StrategyParameter> parameters;
  @override
  String get name => id == 'neural_network'
      ? 'Neural network (long-only)'
      : 'Logistic regression (long-only)';
  @override
  String get description =>
      'Prospective live-trained, holdout-validated, version-pinned long-only simulation.';
  @override
  int get warmupBars => 2;

  Map<String, Object?> toJson() => {
    'strategyId': id,
    'modelId': model?.version,
    'model': model?.toJson(),
  };

  factory PinnedModelStrategy.fromJson(
    Map<String, dynamic> json, {
    List<StrategyParameter> parameters = const [],
  }) {
    final rawModel = json['model'];
    final model = rawModel == null
        ? null
        : TrainedModel.fromJson(Map<String, dynamic>.from(rawModel as Map));
    if (json['modelId'] != model?.version) {
      throw const FormatException('Pinned model ID does not match parameters.');
    }
    return PinnedModelStrategy(
      id: json['strategyId'] as String,
      model: model,
      parameters: parameters,
    );
  }

  @override
  StrategySignal evaluate(StrategyContext context) {
    final pinned = model;
    if (pinned == null) {
      return const StrategySignal(
        TradeAction.wait,
        'WAIT: no validated live-trained model was pinned when this run began.',
      );
    }
    if (context.candles.length < warmupBars) {
      return const StrategySignal(
        TradeAction.wait,
        'WAIT: need two live closes.',
      );
    }
    final previous = context.candles[context.candles.length - 2];
    final current = context.current;
    if (!isValidModelCandle(previous) ||
        !isValidModelCandle(current) ||
        previous.symbol != current.symbol ||
        current.time.difference(previous.time) !=
            Duration(minutes: pinned.intervalMinutes)) {
      return const StrategySignal(
        TradeAction.wait,
        'WAIT: model requires consecutive valid live closes.',
      );
    }
    final probability = pinned.probability(
      liveCandleFeatures(previous, current),
    );
    final entry = context.parameter('entryProbability', .6).clamp(.5, .99);
    final exit = context.parameter('exitProbability', .45).clamp(.01, .5);
    final measurements = {'upProbability': probability};
    if (context.hasPosition && probability <= exit) {
      return StrategySignal(
        TradeAction.sell,
        'Pinned ${pinned.version}: long exit probability.',
        measurements: measurements,
      );
    }
    if (!context.hasPosition && probability >= entry) {
      return StrategySignal(
        TradeAction.buy,
        'Pinned ${pinned.version}: long entry probability.',
        measurements: measurements,
      );
    }
    return StrategySignal(
      TradeAction.wait,
      'Pinned ${pinned.version}: no long-only threshold crossed.',
      measurements: measurements,
    );
  }
}
