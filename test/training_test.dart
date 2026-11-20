import 'dart:convert';

import 'package:atrader/training.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final start = DateTime.utc(2026, 1, 5, 15);

  test(
    'chronological split purges forward windows globally and groups ties',
    () {
      final examples = [
        for (var minute = 0; minute < 50; minute++)
          for (final symbol in ['A', 'B'])
            TrainingExample(
              [minute.toDouble()],
              minute.isEven ? .01 : -.01,
              symbol: symbol,
              observedAt: start.add(Duration(minutes: minute)),
              labelEndAt: start.add(Duration(minutes: minute + 3)),
            ),
      ];
      final split = chronologicalPartition(examples.reversed.toList());
      expect(split.training.length, 74);
      expect(split.holdout.length, 20);
      expect(split.purgedRows, 6);
      expect(
        split.holdout.first.observedAt,
        start.add(const Duration(minutes: 40)),
      );
      expect(
        split.training.every(
          (row) => row.labelEndAt!.isBefore(split.holdout.first.observedAt!),
        ),
        isTrue,
      );
      expect(split.holdout.take(2).map((e) => e.symbol).toSet(), {'A', 'B'});
    },
  );

  test('scaler fits earlier training only; accuracy is untouched holdout', () {
    final examples = [
      for (var row = 0; row < 100; row++)
        TrainingExample([
          row < 80 ? (row.isEven ? -1 : 1) : 1000000,
        ], row.isEven ? -.02 : .02),
    ];
    final model = const ModelTrainer().train(examples, kind: 'logistic');
    expect(model.means, [0]);
    expect(model.scales, [1]);
    expect(model.trainingRows, 80);
    expect(model.holdoutRows, 20);
    expect(model.trainingAccuracy, 1);
    expect(model.accuracy, .5);
    expect(model.validationPassed, isFalse);
    final decoded = TrainedModel.fromJson(
      jsonDecode(jsonEncode(model.toJson())),
    );
    expect(decoded.probability([1]), model.probability([1]));
  });

  test(
    'hidden biases and nonlinear feed-forward inference survive persistence',
    () {
      final model = TrainedModel(
        kind: 'neural',
        version: 'nonlinear_fixture_v2',
        means: [0],
        scales: [1],
        weights: [],
        bias: 1,
        hiddenWeights: [
          [4],
          [-4],
        ],
        hiddenBias: [-2, -2],
        outputWeights: [1, 1],
        accuracy: 1,
        trainingRows: 100,
      );
      final restored = TrainedModel.fromJson(
        jsonDecode(jsonEncode(model.toJson())),
      );
      expect(restored.probability([-1]), greaterThan(.7));
      expect(restored.probability([0]), lessThan(.3));
      expect(restored.probability([1]), greaterThan(.7));
      expect(restored.probability([.25]), model.probability([.25]));
      expect(() => restored.hiddenWeights[0][0] = 0, throwsUnsupportedError);
      expect(() => restored.means[0] = 0, throwsUnsupportedError);
    },
  );

  test('trained neural network learns XOR without flattening hidden layer', () {
    final examples = [
      for (var row = 0; row < 200; row++)
        TrainingExample([
          row % 4 < 2 ? -1 : 1,
          row.isEven ? -1 : 1,
        ], (row % 4 == 1 || row % 4 == 2) ? .02 : -.02),
    ];
    final neural = const ModelTrainer().train(
      examples,
      kind: 'neural',
      epochs: 400,
    );
    final logistic = const ModelTrainer().train(
      examples,
      kind: 'logistic',
      epochs: 400,
    );
    expect(neural.accuracy, greaterThan(.95));
    expect(neural.validationPassed, isTrue);
    expect(neural.hiddenWeights, isNotEmpty);
    expect(neural.weights, isEmpty);
    expect(logistic.accuracy, lessThan(.8));
  });

  test('single-class or invalid data never produces false readiness', () {
    expect(
      () => const ModelTrainer().train(
        List.generate(40, (_) => const TrainingExample([1], .1)),
        kind: 'logistic',
      ),
      throwsArgumentError,
    );
    expect(
      () => const ModelTrainer().train(
        List.generate(
          40,
          (i) => TrainingExample([double.nan], i.isEven ? .1 : -.1),
        ),
        kind: 'neural',
      ),
      throwsArgumentError,
    );
    final oneClassHoldout = [
      for (var i = 0; i < 100; i++)
        TrainingExample([i.isEven ? -1 : 1], i < 80 && i.isEven ? -.02 : .02),
    ];
    final model = const ModelTrainer().train(oneClassHoldout, kind: 'logistic');
    expect(model.validationPassed, isFalse);
  });

  test(
    'old flattened neural schemas are rejected; old logistic is unvalidated',
    () {
      final old = {
        'kind': 'neural',
        'version': 'v1',
        'means': [0.0],
        'scales': [1.0],
        'weights': [1.0],
        'bias': 0.0,
        'accuracy': 1.0,
        'trainingRows': 20,
      };
      expect(() => TrainedModel.fromJson(old), throwsFormatException);
      old['kind'] = 'logistic';
      expect(TrainedModel.fromJson(old).validationPassed, isFalse);
    },
  );

  test('legacy example builder purges labels maturing at split boundary', () {
    final examples = buildExamples(
      List.generate(10, (i) => [i.toDouble()]),
      List.generate(10, (i) => 100 + i.toDouble()),
      horizon: 3,
      trainingEndExclusive: 7,
    );
    expect(examples.length, 4);
    expect(examples.last.features, [3]);
    expect(examples.last.forwardReturn, closeTo(106 / 103 - 1, 1e-12));
  });
}
