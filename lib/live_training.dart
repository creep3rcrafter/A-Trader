/// Prospective live-only collection and version-pinned simulated strategies.
library;

import 'dart:async';
import 'dart:isolate';

import 'simulator.dart';
import 'training.dart';
import 'algorithms/model_features.dart';

export 'algorithms/model_features.dart' show liveCandleFeatures;
export 'algorithms/pinned_model.dart' show PinnedModelStrategy;

/// Caller must supply completed live candles, never historical/replayed bars.
///
/// The clock gate rejects bars whose interval began before [startRun]. A service
/// can retain matured live examples across runs, but pending labels and feature
/// windows are discarded on every run boundary or observed per-symbol gap.
class LiveModelTraining {
  LiveModelTraining({
    this.autoTraining = true,
    this.intervalMinutes = 1,
    this.horizonBars = 3,
    this.minimumExamples = 100,
    this.maximumExamples = 1024,
    this.retrainEveryExamples = 40,
    this.holdoutFraction = .2,
    this.minimumTrainingRows = 20,
    this.minimumHoldoutRows = 10,
    this.minimumHoldoutAccuracy = .55,
    this.roundTripCostFraction = .001,
    this.epochs = 100,
  }) {
    if (intervalMinutes < 1 ||
        intervalMinutes > 60 ||
        horizonBars < 1 ||
        horizonBars > 60 ||
        minimumExamples < 20 ||
        maximumExamples < minimumExamples ||
        maximumExamples > 4096 ||
        retrainEveryExamples < 1 ||
        minimumTrainingRows < 2 ||
        minimumHoldoutRows < 2 ||
        minimumTrainingRows + minimumHoldoutRows > maximumExamples ||
        !holdoutFraction.isFinite ||
        holdoutFraction <= 0 ||
        holdoutFraction >= 1 ||
        !minimumHoldoutAccuracy.isFinite ||
        minimumHoldoutAccuracy < .5 ||
        minimumHoldoutAccuracy > 1 ||
        !roundTripCostFraction.isFinite ||
        roundTripCostFraction < 0 ||
        epochs < 1 ||
        epochs > 500) {
      throw ArgumentError('Invalid bounded live training configuration.');
    }
  }

  static const schemaVersion = 1;
  static const featureSchema = liveModelFeatureSchema;
  static const maximumSymbols = 64;
  static const featureNames = liveModelFeatureNames;

  bool autoTraining;
  final int intervalMinutes;
  final int horizonBars;
  final int minimumExamples;
  final int maximumExamples;
  final int retrainEveryExamples;
  final double holdoutFraction;
  final int minimumTrainingRows;
  final int minimumHoldoutRows;
  final double minimumHoldoutAccuracy;
  final double roundTripCostFraction;
  final int epochs;
  DateTime? _runStartedAt;
  bool _active = false;
  final Map<String, _SymbolWindow> _symbols = {};
  final Map<String, DateTime> _latestTimes = {};
  final List<TrainingExample> _examples = [];
  final Map<String, TrainedModel> _candidates = {};
  final Map<String, Map<String, Object?>> _lastEvaluation = {};
  int _maturedCount = 0;
  int _lastAttemptCount = -1;
  int _invalidatedLabels = 0;
  int _acceptedCandles = 0;
  String? _lastError;
  Future<Map<String, TrainedModel>>? _training;

  void startRun(DateTime startedAt) {
    stopRun();
    _latestTimes.clear();
    _runStartedAt = startedAt.toUtc();
    _active = true;
  }

  void stopRun() {
    _active = false;
    for (final window in _symbols.values) {
      _invalidatedLabels += window.pending.length;
    }
    _symbols.clear();
  }

  /// Notify on stream discontinuity, even if no missing bar has arrived yet.
  void invalidateSymbol(String symbol) {
    final window = _symbols.remove(symbol);
    if (window != null) _invalidatedLabels += window.pending.length;
  }

  void invalidateAll() {
    for (final symbol in _symbols.keys.toList()) {
      invalidateSymbol(symbol);
    }
  }

  void setAutoTraining(bool enabled) {
    autoTraining = enabled;
    _maybeTrain();
  }

  void onCandle(Candle candle) {
    if (!_active || _runStartedAt == null) return;
    final interval = Duration(minutes: intervalMinutes);
    if (candle.time.subtract(interval).isBefore(_runStartedAt!)) return;
    final latest = _latestTimes[candle.symbol];
    if (latest != null && !candle.time.isAfter(latest)) return;
    if (latest == null && _latestTimes.length >= maximumSymbols) return;
    _latestTimes[candle.symbol] = candle.time.toUtc();
    if (!isValidModelCandle(candle)) {
      invalidateSymbol(candle.symbol);
      return;
    }
    var window = _symbols[candle.symbol];
    if (window == null && _symbols.length >= maximumSymbols) return;
    if (window != null) {
      final elapsed = candle.time.difference(window.previous.time);
      if (elapsed <= Duration.zero) return;
      if (elapsed != interval) {
        invalidateSymbol(candle.symbol);
        window = null;
      }
    }
    _acceptedCandles++;
    if (window == null) {
      _symbols[candle.symbol] = _SymbolWindow(candle);
      return;
    }
    final matured = <_PendingLabel>[];
    for (final pending in window.pending) {
      pending.remainingBars--;
      if (pending.remainingBars == 0) {
        matured.add(pending);
        _examples.add(
          TrainingExample(
            List.unmodifiable(pending.features),
            candle.close / pending.close - 1,
            observedAt: pending.observedAt,
            labelEndAt: candle.time.toUtc(),
            symbol: candle.symbol,
          ),
        );
        _maturedCount++;
      }
    }
    window.pending.removeWhere(matured.contains);
    window.pending.add(
      _PendingLabel(
        candle.time.toUtc(),
        candle.close,
        liveCandleFeatures(window.previous, candle),
        horizonBars,
      ),
    );
    window.previous = candle;
    // Keep chronological rows even when symbols arrive in a different order.
    _examples.sort((a, b) => a.observedAt!.compareTo(b.observedAt!));
    if (_examples.length > maximumExamples) {
      _examples.removeRange(0, _examples.length - maximumExamples);
    }
    _maybeTrain();
  }

  void _maybeTrain() {
    if (autoTraining &&
        _active &&
        _training == null &&
        _examples.length >= minimumExamples &&
        (_lastAttemptCount < 0 ||
            _maturedCount - _lastAttemptCount >= retrainEveryExamples)) {
      unawaited(train());
    }
  }

  /// Fits an immutable snapshot in a worker isolate, never in the quote loop.
  ///
  /// Returns currently published candidates; a rejected fit leaves any prior
  /// validated version unchanged. No model is silently substituted in a run.
  Future<Map<String, TrainedModel>> train() {
    final running = _training;
    if (running != null) return running;
    if (_examples.length < minimumExamples) {
      _lastError =
          'Collecting prospective live labels: ${_examples.length}/$minimumExamples.';
      return Future.value(pinCandidates());
    }
    _lastAttemptCount = _maturedCount;
    final request = <String, Object?>{
      'examples': _examples.map((example) => example.toJson()).toList(),
      'roundTripCostFraction': roundTripCostFraction,
      'epochs': epochs,
      'holdoutFraction': holdoutFraction,
      'minimumTrainingRows': minimumTrainingRows,
      'minimumHoldoutRows': minimumHoldoutRows,
      'minimumHoldoutAccuracy': minimumHoldoutAccuracy,
      'horizonBars': horizonBars,
      'intervalMinutes': intervalMinutes,
    };
    final future = _fit(request);
    _training = future;
    return future;
  }

  Future<Map<String, TrainedModel>> _fit(Map<String, Object?> request) async {
    try {
      final response = await Isolate.run(() => _trainSnapshot(request));
      _lastError = response['error'] as String?;
      final evaluations = response['evaluations'] as Map<String, dynamic>;
      _lastEvaluation.clear();
      for (final entry in evaluations.entries) {
        final evaluation = Map<String, dynamic>.from(entry.value as Map);
        _lastEvaluation[entry.key] = evaluation;
        if (evaluation['validationPassed'] == true) {
          _candidates[entry.key] = TrainedModel.fromJson(evaluation);
        }
      }
    } catch (error) {
      _lastError = 'Training unavailable: $error';
    } finally {
      _training = null;
    }
    return pinCandidates();
  }

  /// Keys are registry IDs. Model arrays are deeply immutable.
  Map<String, TrainedModel> pinCandidates() => Map.unmodifiable(_candidates);

  Map<String, Object?> get status => {
    'schemaVersion': schemaVersion,
    'source': 'prospective_completed_live_candles_only',
    'featureSchema': featureSchema,
    'featureNames': featureNames,
    'active': _active,
    'runStartedAt': _runStartedAt?.toIso8601String(),
    'autoTraining': autoTraining,
    'training': _training != null,
    'intervalMinutes': intervalMinutes,
    'horizonBars': horizonBars,
    'acceptedCandles': _acceptedCandles,
    'maturedExamples': _examples.length,
    'totalMaturedExamples': _maturedCount,
    'minimumExamples': minimumExamples,
    'maximumExamples': maximumExamples,
    'pendingLabels': _symbols.values.fold<int>(
      0,
      (n, w) => n + w.pending.length,
    ),
    'invalidatedLabels': _invalidatedLabels,
    'ready': _candidates.isNotEmpty,
    'readiness': _candidates.isNotEmpty
        ? 'Validated candidates available for new runs; existing runs stay pinned.'
        : _lastError ??
              'Collecting live labels; models require a later purged holdout.',
    'lastError': _lastError,
    'candidates': {
      for (final entry in _candidates.entries)
        entry.key: {
          'version': entry.value.version,
          'accuracy': entry.value.accuracy,
          'holdoutRows': entry.value.holdoutRows,
          'trainingRows': entry.value.trainingRows,
          'purgedRows': entry.value.purgedRows,
          'baselineAccuracy': entry.value.baselineAccuracy,
          'brierScore': entry.value.brierScore,
          'longOnly': true,
        },
    },
    'lastEvaluation': {
      for (final entry in _lastEvaluation.entries)
        entry.key: {
          for (final metric in [
            'version',
            'accuracy',
            'trainingRows',
            'holdoutRows',
            'purgedRows',
            'trainingAccuracy',
            'baselineAccuracy',
            'brierScore',
            'validationPassed',
            'trainingLastLabelAt',
            'holdoutStartAt',
            'holdoutEndAt',
          ])
            metric: entry.value[metric],
        },
    },
    'limitations':
        'One chronological holdout is not evidence of profitability. '
        'Repeated validation is not an independent final test. '
        'Labels are close returns net of a configured cost hurdle, not fills. '
        'Long-only, simulator-only; no external model or order service.',
  };

  Map<String, Object?> checkpoint() => {
    'schemaVersion': schemaVersion,
    'featureSchema': featureSchema,
    'configuration': {
      'autoTraining': autoTraining,
      'intervalMinutes': intervalMinutes,
      'horizonBars': horizonBars,
      'minimumExamples': minimumExamples,
      'maximumExamples': maximumExamples,
      'retrainEveryExamples': retrainEveryExamples,
      'holdoutFraction': holdoutFraction,
      'minimumTrainingRows': minimumTrainingRows,
      'minimumHoldoutRows': minimumHoldoutRows,
      'minimumHoldoutAccuracy': minimumHoldoutAccuracy,
      'roundTripCostFraction': roundTripCostFraction,
      'epochs': epochs,
    },
    'active': _active,
    'runStartedAt': _runStartedAt?.toIso8601String(),
    'maturedCount': _maturedCount,
    'lastAttemptCount': _lastAttemptCount,
    'invalidatedLabels': _invalidatedLabels,
    'acceptedCandles': _acceptedCandles,
    'pendingLabelsAtCheckpoint': _symbols.values.fold<int>(
      0,
      (count, window) => count + window.pending.length,
    ),
    'latestTimes': {
      for (final entry in _latestTimes.entries)
        entry.key: entry.value.toUtc().toIso8601String(),
    },
    'examples': _examples.map((example) => example.toJson()).toList(),
    'candidates': {
      for (final entry in _candidates.entries) entry.key: entry.value.toJson(),
    },
    'lastEvaluation': _lastEvaluation,
    'lastError': _lastError,
    // Pending windows intentionally do not survive an unobserved outage.
  };

  factory LiveModelTraining.restore(Map<String, dynamic> json) {
    if (json['schemaVersion'] != schemaVersion ||
        json['featureSchema'] != featureSchema) {
      throw const FormatException('Unsupported live-training checkpoint.');
    }
    final config = Map<String, dynamic>.from(json['configuration'] as Map);
    final service = LiveModelTraining(
      autoTraining: config['autoTraining'] as bool,
      intervalMinutes: config['intervalMinutes'] as int,
      horizonBars: config['horizonBars'] as int,
      minimumExamples: config['minimumExamples'] as int,
      maximumExamples: config['maximumExamples'] as int,
      retrainEveryExamples: config['retrainEveryExamples'] as int,
      holdoutFraction: (config['holdoutFraction'] as num).toDouble(),
      minimumTrainingRows: config['minimumTrainingRows'] as int,
      minimumHoldoutRows: config['minimumHoldoutRows'] as int,
      minimumHoldoutAccuracy: (config['minimumHoldoutAccuracy'] as num)
          .toDouble(),
      roundTripCostFraction: (config['roundTripCostFraction'] as num)
          .toDouble(),
      epochs: config['epochs'] as int,
    );
    service._active = json['active'] as bool? ?? false;
    service._runStartedAt = DateTime.tryParse(
      json['runStartedAt'] as String? ?? '',
    );
    service._maturedCount = json['maturedCount'] as int? ?? 0;
    service._lastAttemptCount = json['lastAttemptCount'] as int? ?? -1;
    service._invalidatedLabels =
        (json['invalidatedLabels'] as int? ?? 0) +
        (json['pendingLabelsAtCheckpoint'] as int? ?? 0);
    service._acceptedCandles = json['acceptedCandles'] as int? ?? 0;
    for (final entry in (json['latestTimes'] as Map? ?? {}).entries.take(
      maximumSymbols,
    )) {
      service._latestTimes[entry.key as String] = DateTime.parse(
        entry.value as String,
      ).toUtc();
    }
    for (final raw in (json['examples'] as List? ?? []).take(
      service.maximumExamples,
    )) {
      final example = TrainingExample.fromJson(
        Map<String, dynamic>.from(raw as Map),
      );
      if (example.features.length != featureNames.length ||
          example.features.any((value) => !value.isFinite || value.abs() > 1) ||
          !example.forwardReturn.isFinite ||
          example.observedAt == null ||
          example.labelEndAt == null ||
          example.labelEndAt!.difference(example.observedAt!) !=
              Duration(
                minutes: service.horizonBars * service.intervalMinutes,
              )) {
        throw const FormatException('Invalid saved prospective example.');
      }
      service._examples.add(example);
    }
    final candidates = json['candidates'] as Map? ?? {};
    final restoreWarnings = <String>[];
    for (final entry in candidates.entries) {
      try {
        final model = TrainedModel.fromJson(
          Map<String, dynamic>.from(entry.value as Map),
        );
        final expectedKind = entry.key == 'neural_network'
            ? 'neural'
            : entry.key == 'logistic_regression'
            ? 'logistic'
            : null;
        if (!model.validationPassed ||
            model.kind != expectedKind ||
            model.featureSchema != featureSchema ||
            model.means.length != featureNames.length ||
            model.intervalMinutes != service.intervalMinutes ||
            model.horizonBars != service.horizonBars ||
            model.holdoutRows < service.minimumHoldoutRows ||
            model.trainingRows < service.minimumTrainingRows ||
            model.accuracy < service.minimumHoldoutAccuracy ||
            !model.baselineAccuracy.isFinite ||
            model.baselineAccuracy < 0 ||
            model.baselineAccuracy > 1 ||
            model.accuracy < model.baselineAccuracy ||
            model.brierScore < 0 ||
            model.brierScore >= .25 ||
            model.roundTripCostFraction != service.roundTripCostFraction ||
            model.trainingLastLabelAt == null ||
            model.holdoutStartAt == null ||
            model.holdoutEndAt == null ||
            !model.trainingLastLabelAt!.isBefore(model.holdoutStartAt!) ||
            !model.holdoutEndAt!.isAfter(model.holdoutStartAt!)) {
          throw const FormatException(
            'Incompatible parameters or missing holdout validation.',
          );
        }
        service._candidates[entry.key as String] = model;
      } on FormatException {
        restoreWarnings.add(
          'Rejected saved ${entry.key} candidate: invalid or incompatible validation.',
        );
      } on TypeError {
        restoreWarnings.add(
          'Rejected saved ${entry.key} candidate: malformed model parameters.',
        );
      }
    }
    final evaluations = json['lastEvaluation'] as Map? ?? {};
    for (final entry in evaluations.entries) {
      service._lastEvaluation[entry.key as String] = Map<String, Object?>.from(
        entry.value as Map,
      );
    }
    service._lastError = [
      if (json['lastError'] != null) json['lastError'] as String,
      ...restoreWarnings,
    ].join(' ');
    if (service._lastError!.isEmpty) service._lastError = null;
    return service;
  }

  factory LiveModelTraining.fromJson(Map<String, dynamic> json) =>
      LiveModelTraining.restore(json);
}

class _SymbolWindow {
  _SymbolWindow(this.previous);
  Candle previous;
  final List<_PendingLabel> pending = [];
}

class _PendingLabel {
  _PendingLabel(this.observedAt, this.close, this.features, this.remainingBars);
  final DateTime observedAt;
  final double close;
  final List<double> features;
  int remainingBars;
}

Map<String, dynamic> _trainSnapshot(Map<String, Object?> request) {
  final examples = (request['examples'] as List)
      .map(
        (raw) =>
            TrainingExample.fromJson(Map<String, dynamic>.from(raw as Map)),
      )
      .toList();
  final evaluations = <String, Object?>{};
  final errors = <String>[];
  for (final entry in const {
    'logistic_regression': 'logistic',
    'neural_network': 'neural',
  }.entries) {
    try {
      final model = const ModelTrainer().train(
        examples,
        kind: entry.value,
        roundTripCostFraction: request['roundTripCostFraction'] as double,
        epochs: request['epochs'] as int,
        holdoutFraction: request['holdoutFraction'] as double,
        minimumTrainingRows: request['minimumTrainingRows'] as int,
        minimumHoldoutRows: request['minimumHoldoutRows'] as int,
        minimumHoldoutAccuracy: request['minimumHoldoutAccuracy'] as double,
        featureSchema: LiveModelTraining.featureSchema,
        horizonBars: request['horizonBars'] as int,
        intervalMinutes: request['intervalMinutes'] as int,
      );
      evaluations[entry.key] = model.toJson();
      if (!model.validationPassed) {
        errors.add('${entry.key}: later holdout validation did not pass.');
      }
    } on ArgumentError catch (error) {
      errors.add('${entry.key}: ${error.message}');
    }
  }
  return {
    'evaluations': evaluations,
    'error': errors.isEmpty ? null : errors.join(' '),
  };
}
