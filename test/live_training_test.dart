import 'dart:convert';

import 'package:atrader/live_training.dart';
import 'package:atrader/simulator.dart';
import 'package:atrader/training.dart';
import 'package:flutter_test/flutter_test.dart';

final start = DateTime.utc(2026, 1, 5, 15);

Candle candle(int minute, {String symbol = 'A', double? close}) {
  final price = close ?? (minute.isEven ? 100.0 : 102.0);
  return Candle(
    symbol: symbol,
    time: start.add(Duration(minutes: minute)),
    open: price,
    high: price + 1,
    low: price - 1,
    close: price,
    volume: 1000,
  );
}

LiveModelTraining service({bool auto = false, int horizon = 1}) =>
    LiveModelTraining(
      autoTraining: auto,
      horizonBars: horizon,
      minimumExamples: 32,
      maximumExamples: 80,
      minimumTrainingRows: 12,
      minimumHoldoutRows: 6,
      holdoutFraction: .25,
      retrainEveryExamples: 20,
      epochs: 80,
    );

StrategyContext context(List<Candle> candles, {bool hasPosition = false}) =>
    StrategyContext(
      candles: candles,
      watchlist: const {},
      hasPosition: hasPosition,
      entryPrice: hasPosition ? 100 : null,
      parameters: const {},
    );

void main() {
  test(
    'collects only fully prospective closes; labels mature at exact horizon',
    () {
      final training = service(horizon: 3);
      training.onCandle(candle(1));
      expect(training.status['acceptedCandles'], 0);
      training.startRun(start.add(const Duration(seconds: 30)));
      training.onCandle(candle(1)); // Interval began before run.
      training.onCandle(candle(-1));
      expect(training.status['acceptedCandles'], 0);
      for (var minute = 2; minute <= 5; minute++) {
        training.onCandle(candle(minute));
      }
      expect(training.status['maturedExamples'], 0);
      expect(training.status['pendingLabels'], 3);
      training.onCandle(candle(6));
      expect(training.status['maturedExamples'], 1);
      final rows = training.checkpoint()['examples'] as List;
      final row = rows.single as Map;
      expect(row['observedAt'], candle(3).time.toIso8601String());
      expect(row['labelEndAt'], candle(6).time.toIso8601String());
      expect(row['forwardReturn'], closeTo(100 / 102 - 1, 1e-12));
      expect(row['features'], everyElement(inInclusiveRange(-1, 1)));
      training.stopRun();
      training.onCandle(candle(7));
      expect(training.status['acceptedCandles'], 5);
      expect(training.status['pendingLabels'], 0);
    },
  );

  test(
    'per-symbol gaps invalidate pending labels without affecting others',
    () {
      final training = service(horizon: 2)..startRun(start);
      for (var minute = 1; minute <= 3; minute++) {
        training.onCandle(candle(minute));
        training.onCandle(candle(minute, symbol: 'B'));
      }
      training.onCandle(candle(5)); // A skips minute 4.
      training.onCandle(candle(4, symbol: 'B'));
      expect(training.status['maturedExamples'], 1);
      expect(training.status['invalidatedLabels'], 2);
      final rows = training.checkpoint()['examples'] as List;
      expect((rows.single as Map)['symbol'], 'B');
      training.invalidateSymbol('B');
      expect(training.status['pendingLabels'], 0);
      training.onCandle(candle(6));
      training.onCandle(candle(6)); // Duplicate.
      training.onCandle(candle(4)); // Out of order.
      expect(training.status['pendingLabels'], 1);
    },
  );

  test(
    'restore drops pending outage windows and rejects already seen bars',
    () {
      final training = service(horizon: 3)..startRun(start);
      for (var minute = 1; minute <= 8; minute++) {
        training.onCandle(candle(minute));
      }
      final restored = LiveModelTraining.restore(
        jsonDecode(jsonEncode(training.checkpoint())),
      );
      expect(restored.status['maturedExamples'], 4);
      expect(restored.status['pendingLabels'], 0);
      expect(restored.status['invalidatedLabels'], 3);
      restored.onCandle(candle(6));
      restored.onCandle(candle(8));
      restored.onCandle(candle(9));
      expect(restored.status['acceptedCandles'], 9);
      expect(restored.status['maturedExamples'], 4);
      expect(restored.status['pendingLabels'], 0);
      restored.onCandle(candle(10));
      expect(restored.status['pendingLabels'], 1);
    },
  );

  test(
    'invalid OHLC invalidates pending labels and never becomes a feature',
    () {
      final invalid = [
        (open: 100.0, high: 99.0, low: 98.0, close: 100.0, volume: 1.0),
        (open: 100.0, high: 102.0, low: 101.0, close: 100.0, volume: 1.0),
        (open: 100.0, high: 99.0, low: 101.0, close: 100.0, volume: 1.0),
        (open: 100.0, high: 101.0, low: 0.0, close: 100.0, volume: 1.0),
        (open: double.nan, high: 101.0, low: 99.0, close: 100.0, volume: 1.0),
        (open: 100.0, high: 101.0, low: 99.0, close: 100.0, volume: -1.0),
      ];
      for (final bar in invalid) {
        final training = service(horizon: 2)..startRun(start);
        training.onCandle(candle(1));
        training.onCandle(candle(2));
        training.onCandle(
          Candle(
            symbol: 'A',
            time: candle(3).time,
            open: bar.open,
            high: bar.high,
            low: bar.low,
            close: bar.close,
            volume: bar.volume,
          ),
        );
        expect(training.status['acceptedCandles'], 2);
        expect(training.status['invalidatedLabels'], 1);
        expect(training.status['pendingLabels'], 0);
        expect(training.status['maturedExamples'], 0);
        training.onCandle(candle(4));
        expect(training.status['pendingLabels'], 0);
      }
    },
  );

  test(
    'restore warns on rejected candidates while preserving valid models',
    () async {
      final training = service()..startRun(start);
      for (var minute = 1; minute <= 64; minute++) {
        training.onCandle(candle(minute));
      }
      await training.train();
      final saved =
          jsonDecode(jsonEncode(training.checkpoint())) as Map<String, dynamic>;
      final candidates = saved['candidates'] as Map<String, dynamic>;
      (candidates['neural_network']
              as Map<String, dynamic>)['intervalMinutes'] =
          5;
      final restored = LiveModelTraining.restore(saved);
      expect(restored.pinCandidates().keys, ['logistic_regression']);
      expect(restored.status['ready'], isTrue);
      expect(
        restored.status['lastError'],
        contains('Rejected saved neural_network'),
      );
      (candidates['logistic_regression'] as Map<String, dynamic>)['scales'] = [
        0,
      ];
      final unavailable = LiveModelTraining.restore(saved);
      expect(unavailable.pinCandidates(), isEmpty);
      expect(unavailable.status['ready'], isFalse);
      expect(unavailable.status['readiness'], contains('Rejected saved'));
      expect(unavailable.status['lastError'], contains('logistic_regression'));
    },
  );

  test(
    'auto trains only after threshold and publishes purged validated models',
    () async {
      final training = service(auto: true)..startRun(start);
      final before = training.pinCandidates();
      for (var minute = 1; minute <= 33; minute++) {
        training.onCandle(candle(minute));
      }
      expect(training.status['maturedExamples'], 31);
      expect(training.status['training'], isFalse);
      expect(training.status['ready'], isFalse);
      training.onCandle(candle(34));
      expect(training.status['training'], isTrue);
      final candidates = await training.train();
      expect(
        candidates.keys,
        containsAll(['logistic_regression', 'neural_network']),
      );

      expect(training.status['ready'], isTrue);
      expect(training.status['training'], isFalse);
      expect(
        before,
        isEmpty,
      ); // No candidate/pin drift when training completes.
      for (final model in candidates.values) {
        expect(model.trainingRows, 23);
        expect(model.holdoutRows, 8);
        expect(model.purgedRows, 1);
        expect(model.accuracy, 1);
        expect(
          model.trainingLastLabelAt!.isBefore(model.holdoutStartAt!),
          isTrue,
        );
        expect(model.hiddenWeights.isNotEmpty, model.kind == 'neural');
      }
      final saved = LiveModelTraining.restore(
        jsonDecode(jsonEncode(training.checkpoint())),
      );
      expect(saved.pinCandidates().keys, candidates.keys);
      expect(
        saved.pinCandidates()['neural_network']!.toJson(),
        candidates['neural_network']!.toJson(),
      );
      final oldVersion = candidates['logistic_regression']!.version;
      for (var minute = 35; minute < 70; minute++) {
        training.onCandle(candle(minute));
      }
      await training.train();
      expect(candidates['logistic_regression']!.version, oldVersion);
      expect(
        training.pinCandidates()['logistic_regression']!.version,
        isNot(oldVersion),
      );
    },
  );

  test('a rejected later fit never replaces validated candidates', () async {
    final training = service()..startRun(start);
    for (var minute = 1; minute <= 64; minute++) {
      training.onCandle(candle(minute));
    }
    final validated = await training.train();
    expect(validated, isNotEmpty);
    for (var minute = 65; minute <= 180; minute++) {
      training.onCandle(candle(minute, close: 100 + minute.toDouble()));
    }
    final rejected = await training.train();
    expect(
      rejected.map((key, model) => MapEntry(key, model.version)),
      validated.map((key, model) => MapEntry(key, model.version)),
    );
    expect(training.status['lastError'], contains('only one class'));
    expect(training.status['lastEvaluation'], isEmpty);
    expect(training.status['ready'], isTrue);
  });

  test(
    'insufficient or single-class data stays unready; dataset is bounded',
    () async {
      final training = service()..startRun(start);
      await training.train();
      expect(training.status['ready'], isFalse);
      expect(training.status['lastError'], contains('Collecting'));
      for (var minute = 1; minute <= 120; minute++) {
        training.onCandle(candle(minute, close: 100 + minute.toDouble()));
      }
      await training.train();
      expect(training.status['maturedExamples'], 80);
      expect(training.status['ready'], isFalse);
      expect(training.status['lastError'], contains('only one class'));
    },
  );

  test(
    'pinned model strategy waits clearly if absent and never changes pin',
    () async {
      final training = service()..startRun(start);
      final noModel = PinnedModelStrategy(
        id: 'neural_network',
        model: training.pinCandidates()['neural_network'],
      );
      expect(
        noModel.evaluate(context([candle(1), candle(2)])).reason,
        contains('no validated'),
      );
      for (var minute = 1; minute <= 64; minute++) {
        training.onCandle(candle(minute));
      }
      final candidates = await training.train();
      final pinned = candidates['logistic_regression']!;
      final strategy = PinnedModelStrategy(
        id: 'logistic_regression',
        model: pinned,
      );
      expect(
        strategy.evaluate(context([candle(1), candle(2)])).action,
        TradeAction.buy,
      );
      expect(
        strategy
            .evaluate(context([candle(2), candle(3)], hasPosition: true))
            .action,
        TradeAction.sell,
      );
      expect(
        strategy.evaluate(context([candle(2), candle(4)])).action,
        TradeAction.wait,
      );
      expect(
        noModel.evaluate(context([candle(1), candle(2)])).action,
        TradeAction.wait,
      );
      expect(strategy.toJson()['modelId'], pinned.version);
      final restored = PinnedModelStrategy.fromJson(
        jsonDecode(jsonEncode(strategy.toJson())),
      );
      expect(restored.model!.version, pinned.version);
      expect(
        restored.evaluate(context([candle(1), candle(2)])).action,
        TradeAction.buy,
      );
      final corrupted = Map<String, dynamic>.from(strategy.toJson());
      corrupted['modelId'] = 'another_version';
      expect(
        () => PinnedModelStrategy.fromJson(corrupted),
        throwsFormatException,
      );
      final full = strategy.toJson()['model'] as Map<String, Object?>;
      expect(
        TrainedModel.fromJson(Map<String, dynamic>.from(full)).version,
        pinned.version,
      );
    },
  );
}
