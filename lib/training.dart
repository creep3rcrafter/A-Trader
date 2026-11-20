/// Deterministic, chronological training and portable model inference.
library;

import 'dart:math' as math;

class TrainingExample {
  const TrainingExample(
    this.features,
    this.forwardReturn, {
    this.observedAt,
    this.labelEndAt,
    this.symbol,
  });

  final List<double> features;
  final double forwardReturn;
  final DateTime? observedAt;
  final DateTime? labelEndAt;
  final String? symbol;

  Map<String, Object?> toJson() => {
    'features': features,
    'forwardReturn': forwardReturn,
    'observedAt': observedAt?.toUtc().toIso8601String(),
    'labelEndAt': labelEndAt?.toUtc().toIso8601String(),
    'symbol': symbol,
  };

  factory TrainingExample.fromJson(Map<String, dynamic> json) =>
      TrainingExample(
        _numbers(json['features']),
        (json['forwardReturn'] as num).toDouble(),
        observedAt: DateTime.tryParse(json['observedAt'] as String? ?? ''),
        labelEndAt: DateTime.tryParse(json['labelEndAt'] as String? ?? ''),
        symbol: json['symbol'] as String?,
      );
}

/// All parameters, including nested neural layers, are immutable.
class TrainedModel {
  TrainedModel({
    required this.kind,
    required this.version,
    required List<double> means,
    required List<double> scales,
    required List<double> weights,
    required this.bias,
    required this.accuracy,
    required this.trainingRows,
    List<List<double>> hiddenWeights = const [],
    List<double> hiddenBias = const [],
    List<double> outputWeights = const [],
    this.holdoutRows = 0,
    this.purgedRows = 0,
    this.trainingAccuracy = 0,
    this.baselineAccuracy = 0,
    this.brierScore = 1,
    this.validationPassed = false,
    this.roundTripCostFraction = .001,
    this.trainingLastLabelAt,
    this.holdoutStartAt,
    this.holdoutEndAt,
    this.featureSchema = 'supplied_v1',
    this.horizonBars = 0,
    this.intervalMinutes = 0,
  }) : means = List.unmodifiable(means),
       scales = List.unmodifiable(scales),
       weights = List.unmodifiable(weights),
       hiddenWeights = List.unmodifiable(
         hiddenWeights.map((row) => List<double>.unmodifiable(row)),
       ),
       hiddenBias = List.unmodifiable(hiddenBias),
       outputWeights = List.unmodifiable(outputWeights);

  static const schemaVersion = 2;
  final String kind;
  final String version;
  final List<double> means;
  final List<double> scales;
  final List<double> weights;

  /// Logistic intercept, or the neural output-layer bias.
  final double bias;
  final List<List<double>> hiddenWeights;
  final List<double> hiddenBias;
  final List<double> outputWeights;

  /// Accuracy is measured exclusively on the later, untouched holdout.
  final double accuracy;
  final int trainingRows;
  final int holdoutRows;
  final int purgedRows;
  final double trainingAccuracy;
  final double baselineAccuracy;
  final double brierScore;
  final bool validationPassed;
  final double roundTripCostFraction;
  final DateTime? trainingLastLabelAt;
  final DateTime? holdoutStartAt;
  final DateTime? holdoutEndAt;
  final String featureSchema;
  final int horizonBars;
  final int intervalMinutes;

  double probability(List<double> features) {
    if (features.length != means.length ||
        features.any((value) => !value.isFinite)) {
      throw ArgumentError('Expected ${means.length} finite features.');
    }
    final normalized = List.generate(
      features.length,
      (j) => ((features[j] - means[j]) / scales[j]).clamp(-10.0, 10.0),
    );
    if (kind == 'neural') {
      final hidden = List.generate(
        hiddenWeights.length,
        (h) => _tanh(_dot(hiddenWeights[h], normalized) + hiddenBias[h]),
      );
      return _sigmoid(_dot(outputWeights, hidden) + bias);
    }
    return _sigmoid(_dot(weights, normalized) + bias);
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'kind': kind,
    'version': version,
    'means': means,
    'scales': scales,
    'weights': weights,
    'bias': bias,
    'hiddenWeights': hiddenWeights,
    'hiddenBias': hiddenBias,
    'outputWeights': outputWeights,
    'accuracy': accuracy,
    'trainingRows': trainingRows,
    'holdoutRows': holdoutRows,
    'purgedRows': purgedRows,
    'trainingAccuracy': trainingAccuracy,
    'baselineAccuracy': baselineAccuracy,
    'brierScore': brierScore,
    'validationPassed': validationPassed,
    'roundTripCostFraction': roundTripCostFraction,
    'trainingLastLabelAt': trainingLastLabelAt?.toUtc().toIso8601String(),
    'holdoutStartAt': holdoutStartAt?.toUtc().toIso8601String(),
    'holdoutEndAt': holdoutEndAt?.toUtc().toIso8601String(),
    'featureSchema': featureSchema,
    'horizonBars': horizonBars,
    'intervalMinutes': intervalMinutes,
  };

  factory TrainedModel.fromJson(Map<String, dynamic> json) {
    final schema = json['schemaVersion'] as int? ?? 1;
    final kind = json['kind'] as String;
    if (schema != schemaVersion && !(schema == 1 && kind == 'logistic')) {
      throw const FormatException(
        'Unsupported model schema; legacy flattened neural models must retrain.',
      );
    }
    final model = TrainedModel(
      kind: kind,
      version: json['version'] as String,
      means: _numbers(json['means']),
      scales: _numbers(json['scales']),
      weights: _numbers(json['weights']),
      bias: (json['bias'] as num).toDouble(),
      hiddenWeights: (json['hiddenWeights'] as List? ?? [])
          .map(_numbers)
          .toList(),
      hiddenBias: _numbers(json['hiddenBias'] ?? []),
      outputWeights: _numbers(json['outputWeights'] ?? []),
      accuracy: (json['accuracy'] as num).toDouble(),
      trainingRows: json['trainingRows'] as int,
      holdoutRows: json['holdoutRows'] as int? ?? 0,
      purgedRows: json['purgedRows'] as int? ?? 0,
      trainingAccuracy: (json['trainingAccuracy'] as num? ?? 0).toDouble(),
      baselineAccuracy: (json['baselineAccuracy'] as num? ?? 0).toDouble(),
      brierScore: (json['brierScore'] as num? ?? 1).toDouble(),
      validationPassed:
          schema == schemaVersion &&
          (json['validationPassed'] as bool? ?? false),
      roundTripCostFraction: (json['roundTripCostFraction'] as num? ?? .001)
          .toDouble(),
      trainingLastLabelAt: DateTime.tryParse(
        json['trainingLastLabelAt'] as String? ?? '',
      ),
      holdoutStartAt: DateTime.tryParse(
        json['holdoutStartAt'] as String? ?? '',
      ),
      holdoutEndAt: DateTime.tryParse(json['holdoutEndAt'] as String? ?? ''),
      featureSchema: json['featureSchema'] as String? ?? 'supplied_v1',
      horizonBars: json['horizonBars'] as int? ?? 0,
      intervalMinutes: json['intervalMinutes'] as int? ?? 0,
    );
    final count = model.means.length;
    if (!{'logistic', 'neural'}.contains(kind) ||
        count == 0 ||
        model.scales.length != count ||
        model.means.any((value) => !value.isFinite) ||
        model.scales.any((value) => !value.isFinite || value <= 0) ||
        !model.bias.isFinite ||
        !model.accuracy.isFinite ||
        model.accuracy < 0 ||
        model.accuracy > 1 ||
        !model.brierScore.isFinite ||
        model.trainingRows < 0 ||
        model.holdoutRows < 0 ||
        (kind == 'logistic' &&
            (model.weights.length != count ||
                model.weights.any((value) => !value.isFinite))) ||
        (kind == 'neural' &&
            (model.hiddenWeights.isEmpty ||
                model.hiddenWeights.length != model.hiddenBias.length ||
                model.hiddenWeights.length != model.outputWeights.length ||
                model.hiddenWeights.any(
                  (row) =>
                      row.length != count ||
                      row.any((value) => !value.isFinite),
                ) ||
                model.hiddenBias.any((value) => !value.isFinite) ||
                model.outputWeights.any((value) => !value.isFinite)))) {
      throw const FormatException('Invalid model dimensions or parameters.');
    }
    return model;
  }
}

class TrainingPartition {
  TrainingPartition(this.training, this.holdout, this.purgedRows);
  final List<TrainingExample> training;
  final List<TrainingExample> holdout;
  final int purgedRows;
}

/// Groups tied timestamps into the holdout and purges training label windows
/// ending at or beyond its first observation, across every symbol.
TrainingPartition chronologicalPartition(
  List<TrainingExample> examples, {
  double holdoutFraction = .2,
}) {
  if (examples.length < 2 ||
      !holdoutFraction.isFinite ||
      holdoutFraction <= 0 ||
      holdoutFraction >= 1) {
    throw ArgumentError('A chronological train/holdout split is required.');
  }
  final timestamped = examples.any(
    (example) => example.observedAt != null || example.labelEndAt != null,
  );
  if (timestamped &&
      examples.any(
        (example) =>
            example.observedAt == null ||
            example.labelEndAt == null ||
            !example.labelEndAt!.isAfter(example.observedAt!),
      )) {
    throw ArgumentError(
      'Timestamped examples need later label maturity times.',
    );
  }
  final ordered = [...examples];
  if (timestamped) {
    ordered.sort((a, b) => a.observedAt!.compareTo(b.observedAt!));
  }
  var boundary = (ordered.length * (1 - holdoutFraction)).floor();
  boundary = boundary.clamp(1, ordered.length - 1);
  if (timestamped) {
    final firstHoldout = ordered[boundary].observedAt!;
    while (boundary > 0 && ordered[boundary - 1].observedAt == firstHoldout) {
      boundary--;
    }
  }
  final holdout = ordered.sublist(boundary);
  final earlier = ordered.sublist(0, boundary);
  final training = timestamped
      ? earlier
            .where(
              (example) =>
                  example.labelEndAt!.isBefore(holdout.first.observedAt!),
            )
            .toList()
      : earlier;
  return TrainingPartition(training, holdout, earlier.length - training.length);
}

class ModelTrainer {
  const ModelTrainer();

  TrainedModel train(
    List<TrainingExample> examples, {
    required String kind,
    double roundTripCostFraction = .001,
    int epochs = 120,
    double learningRate = .03,
    double holdoutFraction = .2,
    int minimumTrainingRows = 12,
    int minimumHoldoutRows = 5,
    double minimumHoldoutAccuracy = .55,
    String featureSchema = 'supplied_v1',
    int horizonBars = 0,
    int intervalMinutes = 0,
  }) {
    if (!{'logistic', 'neural'}.contains(kind) ||
        examples.length < 20 ||
        examples.length > 4096 ||
        epochs < 1 ||
        epochs > 500 ||
        !learningRate.isFinite ||
        learningRate <= 0 ||
        learningRate > 1 ||
        !roundTripCostFraction.isFinite ||
        roundTripCostFraction < 0 ||
        minimumTrainingRows < 2 ||
        minimumHoldoutRows < 2 ||
        !minimumHoldoutAccuracy.isFinite ||
        minimumHoldoutAccuracy < .5 ||
        minimumHoldoutAccuracy > 1) {
      throw ArgumentError('Invalid or unbounded training configuration.');
    }
    final featureCount = examples.first.features.length;
    if (featureCount == 0 ||
        featureCount > 32 ||
        examples.any(
          (example) =>
              example.features.length != featureCount ||
              example.features.any((value) => !value.isFinite) ||
              !example.forwardReturn.isFinite,
        )) {
      throw ArgumentError('Examples must contain aligned finite features.');
    }
    final partition = chronologicalPartition(
      examples,
      holdoutFraction: holdoutFraction,
    );
    final training = partition.training;
    final holdout = partition.holdout;
    if (training.length < minimumTrainingRows ||
        holdout.length < minimumHoldoutRows) {
      throw ArgumentError(
        'Insufficient chronological rows after horizon purge.',
      );
    }
    final means = List<double>.generate(
      featureCount,
      (j) =>
          training.fold(0.0, (sum, e) => sum + e.features[j]) / training.length,
    );
    final scales = List<double>.generate(featureCount, (j) {
      final variance =
          training.fold(
            0.0,
            (sum, e) => sum + math.pow(e.features[j] - means[j], 2),
          ) /
          training.length;
      return math.max(.000001, math.sqrt(variance));
    });
    if (means.any((value) => !value.isFinite) ||
        scales.any((value) => !value.isFinite)) {
      throw ArgumentError(
        'Feature magnitudes exceed finite scaler statistics.',
      );
    }
    final inputs = training
        .map(
          (example) => List<double>.generate(
            featureCount,
            (j) => ((example.features[j] - means[j]) / scales[j]).clamp(
              -10.0,
              10.0,
            ),
          ),
        )
        .toList();
    double label(TrainingExample example) =>
        example.forwardReturn > roundTripCostFraction ? 1 : 0;
    final labels = training.map(label).toList();
    if (labels.toSet().length < 2) {
      throw ArgumentError(
        'Training labels contain only one class after costs.',
      );
    }
    final weights = List<double>.filled(featureCount, 0);
    final hiddenSize = math.min(8, math.max(4, featureCount * 2));
    final random = math.Random(17);
    final hiddenWeights = List.generate(
      hiddenSize,
      (_) => List.generate(featureCount, (_) => (random.nextDouble() - .5)),
    );
    final hiddenBias = List<double>.filled(hiddenSize, 0);
    final outputWeights = List<double>.generate(
      hiddenSize,
      (_) => (random.nextDouble() - .5),
    );
    var bias = 0.0;
    for (var epoch = 0; epoch < epochs; epoch++) {
      for (var row = 0; row < inputs.length; row++) {
        final input = inputs[row];
        if (kind == 'logistic') {
          final error = _sigmoid(_dot(weights, input) + bias) - labels[row];
          for (var j = 0; j < featureCount; j++) {
            weights[j] -= learningRate * error * input[j];
          }
          bias -= learningRate * error;
        } else {
          final hidden = List.generate(
            hiddenSize,
            (h) => _tanh(_dot(hiddenWeights[h], input) + hiddenBias[h]),
          );
          final error =
              _sigmoid(_dot(outputWeights, hidden) + bias) - labels[row];
          for (var h = 0; h < hiddenSize; h++) {
            final hiddenError =
                error * outputWeights[h] * (1 - hidden[h] * hidden[h]);
            outputWeights[h] -= learningRate * error * hidden[h];
            for (var j = 0; j < featureCount; j++) {
              hiddenWeights[h][j] -= learningRate * hiddenError * input[j];
            }
            hiddenBias[h] -= learningRate * hiddenError;
          }
          bias -= learningRate * error;
        }
      }
    }
    TrainedModel result({
      double accuracy = 0,
      double trainingAccuracy = 0,
      double baselineAccuracy = 0,
      double brierScore = 1,
      bool validationPassed = false,
    }) => TrainedModel(
      kind: kind,
      version: '${kind}_v2_${DateTime.now().toUtc().microsecondsSinceEpoch}',
      means: means,
      scales: scales,
      weights: kind == 'logistic' ? weights : const [],
      bias: bias,
      hiddenWeights: kind == 'neural' ? hiddenWeights : const [],
      hiddenBias: kind == 'neural' ? hiddenBias : const [],
      outputWeights: kind == 'neural' ? outputWeights : const [],
      accuracy: accuracy,
      trainingRows: training.length,
      holdoutRows: holdout.length,
      purgedRows: partition.purgedRows,
      trainingAccuracy: trainingAccuracy,
      baselineAccuracy: baselineAccuracy,
      brierScore: brierScore,
      validationPassed: validationPassed,
      roundTripCostFraction: roundTripCostFraction,
      trainingLastLabelAt: training
          .map((e) => e.labelEndAt)
          .whereType<DateTime>()
          .fold<DateTime?>(
            null,
            (latest, time) =>
                latest == null || time.isAfter(latest) ? time : latest,
          ),
      holdoutStartAt: holdout.first.observedAt,
      holdoutEndAt: holdout.last.labelEndAt,
      featureSchema: featureSchema,
      horizonBars: horizonBars,
      intervalMinutes: intervalMinutes,
    );
    final fitted = result();
    double accuracyOn(List<TrainingExample> rows) =>
        rows
            .where(
              (e) => (fitted.probability(e.features) >= .5 ? 1 : 0) == label(e),
            )
            .length /
        rows.length;
    final accuracy = accuracyOn(holdout);
    final baselineLabel =
        labels.where((value) => value == 1).length >= labels.length / 2 ? 1 : 0;
    final baselineAccuracy =
        holdout.where((e) => label(e) == baselineLabel).length / holdout.length;
    final brierScore =
        holdout.fold(
          0.0,
          (sum, e) =>
              sum + math.pow(fitted.probability(e.features) - label(e), 2),
        ) /
        holdout.length;
    return result(
      accuracy: accuracy,
      trainingAccuracy: accuracyOn(training),
      baselineAccuracy: baselineAccuracy,
      brierScore: brierScore,
      validationPassed:
          holdout.map(label).toSet().length == 2 &&
          accuracy >= minimumHoldoutAccuracy &&
          accuracy >= baselineAccuracy &&
          brierScore < .25,
    );
  }
}

/// Legacy row-based helper: a training label must mature before the boundary.
List<TrainingExample> buildExamples(
  List<List<double>> featureRows,
  List<double> closes, {
  required int horizon,
  required int trainingEndExclusive,
}) {
  if (horizon < 1 ||
      featureRows.length != closes.length ||
      trainingEndExclusive < 0 ||
      trainingEndExclusive > closes.length ||
      closes.any((close) => !close.isFinite || close <= 0)) {
    throw ArgumentError(
      'Aligned positive closes and a valid split are required.',
    );
  }
  final last = math.min(
    trainingEndExclusive - horizon,
    closes.length - horizon,
  );
  return [
    for (var i = 0; i < last; i++)
      TrainingExample(
        List.unmodifiable(featureRows[i]),
        closes[i + horizon] / closes[i] - 1,
      ),
  ];
}

List<double> _numbers(dynamic values) =>
    (values as List).map((value) => (value as num).toDouble()).toList();

double _dot(List<double> left, List<double> right) {
  var sum = 0.0;
  for (var i = 0; i < left.length; i++) {
    sum += left[i] * right[i];
  }
  return sum;
}

double _sigmoid(double value) => 1 / (1 + math.exp(-value.clamp(-30, 30)));

double _tanh(double value) {
  final exponential = math.exp(2 * value.clamp(-15, 15));
  return (exponential - 1) / (exponential + 1);
}
