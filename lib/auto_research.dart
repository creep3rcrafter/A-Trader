import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:io';
import 'dart:math';

import 'exchange_calendar.dart';
import 'historical_replay.dart';
import 'mountain_time.dart';
import 'simulator.dart';
import 'strategy_tuning.dart';
import 'algorithms/algorithm_library.dart';

typedef HistoryFetcher =
    Future<List<MinuteBar>> Function({
      required String symbol,
      required DateTime startUtc,
      required DateTime endUtc,
    });

typedef ResearchPreview =
    void Function(
      Map<String, dynamic> configuration,
      SimulatorEngine engine,
      HistoricalRange range,
    );

enum _ResearchPhase {
  ready,
  downloading,
  tuning,
  replaying,
  waiting,
  stopping,
  stopped,
  complete,
  error,
}

typedef _ResearchProgress = ({
  _ResearchPhase phase,
  double? progress,
  int? remainingSeconds,
  String? detail,
});

class AutoResearch {
  AutoResearch({
    required this.fetch,
    required this.clock,
    this.cycleDelay = Duration.zero,
    this.onPreview,
    this.onCheckpoint,
    this.algorithmDefinitions,
    Random? random,
  }) : _random = random ?? Random();

  final HistoryFetcher fetch;
  final DateTime Function() clock;
  final Duration cycleDelay;
  final ResearchPreview? onPreview;
  final void Function()? onCheckpoint;
  final List<Map<String, dynamic>> Function()? algorithmDefinitions;
  final Random _random;
  Map<String, dynamic>? _configuration;
  Map<String, dynamic>? _source;
  EvolutionSettings _evolution = const EvolutionSettings();
  final _previousTrials = <String, List<Map<String, double>>>{};
  Map<String, List<MinuteBar>> _history = {};
  DateTime? _fetchedAt;
  Future<void>? _work;
  Future<void> get stopped => _work ?? Future<void>.value();
  Completer<void>? _stop;
  Timer? _timer;
  int _cycles = 0;
  int _generations = 0;
  int? _evolutionLimit;
  String _message = 'Ready';
  _ResearchPhase _phase = _ResearchPhase.ready;
  double? _progress;
  int? _remainingSeconds;
  String? _detail;
  String? _runName;
  String? _sessionId;
  DateTime? _start;
  DateTime? _end;
  DateTime? _nextCycleAt;
  HistoricalRange? _historicalRange;
  int _improvements = 0;
  int _tested = 0;
  List<Map<String, Object?>> _lastResults = [];

  Map<String, Object?> get status => {
    'running': _stop != null && !_stop!.isCompleted,
    'stopping': _stop?.isCompleted == true,
    'message': _message,
    'phase': _phase.name,
    'progress': _progress,
    'remainingSeconds': _remainingSeconds,
    'detail': _detail,
    'runName': _runName,
    'sessionId': _sessionId,
    'cycles': _cycles,
    'generations': _generations,
    'evolutionLimit': _evolutionLimit,
    'interval': 1,
    'rangeLabel': _historicalRange?.label,
    'start': _start?.toIso8601String(),
    'end': _end?.toIso8601String(),
    'nextCycleAt': _nextCycleAt?.toIso8601String(),
    'lastInterval': _cycles == 0 ? null : 1,
    'improvements': _improvements,
    'candidatesTested': _tested,
    'lastResults': _lastResults,
    'configurations': {'1': ?_configuration},
  };

  Map<String, Object?> checkpoint() => {
    ...status,
    'source': _source,
    'configuration': _configuration,
    'evolution': _evolution.toJson(),
    'previousTrials': _previousTrials,
    'fetchedAt': _fetchedAt?.toIso8601String(),
    'history': {
      for (final entry in _history.entries)
        entry.key: [
          for (final bar in entry.value)
            {
              'time': bar.openTime.toIso8601String(),
              'open': bar.open,
              'high': bar.high,
              'low': bar.low,
              'close': bar.close,
              'volume': bar.volume,
            },
        ],
    },
  };

  void restoreCheckpoint(Map<String, dynamic> saved) {
    if (_stop != null) {
      throw StateError('Stop training before loading a saved session.');
    }
    _source = saved['source'] as Map<String, dynamic>?;
    _configuration = saved['configuration'] as Map<String, dynamic>?;
    _runName = saved['runName'] as String?;
    _sessionId = saved['sessionId'] as String?;
    _cycles = saved['cycles'] as int? ?? 0;
    _generations = saved['generations'] as int? ?? 1;
    _evolutionLimit = saved['evolutionLimit'] as int?;
    _evolution = EvolutionSettings.fromJson(
      saved['evolution'] as Map<String, dynamic>?,
    );
    _lastResults = (saved['lastResults'] as List? ?? [])
        .cast<Map<String, dynamic>>();
    _previousTrials.clear();
    for (final entry in (saved['previousTrials'] as Map? ?? const {}).entries) {
      _previousTrials[entry.key as String] = [
        for (final trial in entry.value as List)
          (trial as Map).map(
            (key, value) => MapEntry(key as String, (value as num).toDouble()),
          ),
      ];
    }
    _start = DateTime.tryParse(saved['start']?.toString() ?? '');
    _end = DateTime.tryParse(saved['end']?.toString() ?? '');
    _historicalRange = _start != null && _end != null
        ? (
            startUtc: _start!,
            endUtc: _end!,
            label: saved['rangeLabel'] as String? ?? 'Saved training range',
          )
        : null;
    _fetchedAt = DateTime.tryParse(saved['fetchedAt']?.toString() ?? '');
    _history = {
      for (final entry in (saved['history'] as Map? ?? const {}).entries)
        entry.key as String: [
          for (final row in (entry.value as List).cast<Map>())
            MinuteBar(
              symbol: entry.key as String,
              openTime: DateTime.parse(row['time'] as String),
              open: (row['open'] as num).toDouble(),
              high: (row['high'] as num).toDouble(),
              low: (row['low'] as num).toDouble(),
              close: (row['close'] as num).toDouble(),
              volume: (row['volume'] as num).toDouble(),
            ),
        ],
    };
    _setActivity(
      _ResearchPhase.stopped,
      'Saved training · $_cycles generations completed',
    );
  }

  void start({
    required String runName,
    required Map<String, Object?> configuration,
    required List<StrategySettings> strategies,
    required int generations,
    int? evolutionLimit,
    HistoricalRange? historicalRange,
    EvolutionSettings evolution = const EvolutionSettings(),
    Map<String, dynamic>? resume,
  }) {
    if (_stop != null) {
      throw StateError('Wait for the current research cycle to finish.');
    }
    if (resume != null) {
      restoreCheckpoint(resume);
      if (evolutionLimit != null && evolutionLimit <= _cycles) {
        throw ArgumentError(
          'Choose a total greater than $_cycles completed generations.',
        );
      }
    }
    final eligible = strategies
        .where(
          (setting) =>
              setting.enabled &&
              !untunableStrategyIds.contains(setting.strategyId) &&
              (StrategyRegistry.byId(
                    setting.strategyId,
                  ).parameters.isNotEmpty ||
                  !StrategyRegistry.builtinIds.contains(setting.strategyId)),
        )
        .toList();
    final source =
        jsonDecode(jsonEncode(configuration)) as Map<String, dynamic>;
    final benchmarks = BenchmarkSettings.fromJson(
      source['benchmarks'] as Map<String, dynamic>?,
    );
    if (eligible.isEmpty && !benchmarks.buyAndHold && !benchmarks.equalWeight) {
      throw StateError(
        'Enable a benchmark or a strategy that supports historical replay first.',
      );
    }
    final stop = _stop = Completer<void>();
    _source = source;
    _evolution = evolution;
    if (resume == null) {
      _sessionId = '${DateTime.now().microsecondsSinceEpoch}';
      _configuration = null;
      _previousTrials.clear();
      _history = {};
      _fetchedAt = null;
      _cycles = _improvements = _tested = 0;
      _lastResults = [];
    }
    _runName = runName;
    _generations = generations;
    _evolutionLimit = evolutionLimit;
    _historicalRange = historicalRange;
    _work = _run(source, eligible, generations, historicalRange, stop);
    unawaited(_work);
  }

  void stop() {
    final stop = _stop;
    if (stop == null || stop.isCompleted) return;
    _setActivity(_ResearchPhase.stopping, 'Stopping research…');
    stop.complete();
    _timer?.cancel();
  }

  void _setActivity(
    _ResearchPhase phase,
    String message, {
    double? progress,
    int? remainingSeconds,
    String? detail,
  }) {
    _phase = phase;
    _message = message;
    _progress = progress;
    _remainingSeconds = remainingSeconds;
    _detail = detail;
  }

  Future<void> _run(
    Map<String, dynamic> source,
    List<StrategySettings> eligible,
    int generations,
    HistoricalRange? historicalRange,
    Completer<void> stop,
  ) async {
    final watchlist = (source['watchlist'] as List).cast<String>();
    final risk = TuningRisk.fromSettings(source);
    try {
      while (!stop.isCompleted) {
        try {
          final now = clock().toUtc();
          final today = DateTime.utc(now.year, now.month, now.day);
          if (historicalRange != null) {
            _start = historicalRange.startUtc;
            _end = historicalRange.endUtc;
          } else {
            final length = 8 + _random.nextInt(21);
            final offset = _random.nextInt(28 - length + 1);
            _end = today.subtract(Duration(days: offset));
            _start = _end!.subtract(Duration(days: length));
          }
          if (_fetchedAt == null ||
              (historicalRange == null &&
                  (now.difference(_fetchedAt!) >= const Duration(hours: 1) ||
                      _fetchedAt!.day != now.day))) {
            final downloaded = <String, List<MinuteBar>>{};
            for (final symbol in watchlist) {
              _setActivity(
                _ResearchPhase.downloading,
                'Downloading Schwab history',
                progress: downloaded.length / watchlist.length,
                detail:
                    '$symbol · ${downloaded.length + 1} of ${watchlist.length} symbols',
              );
              downloaded[symbol] = await fetch(
                symbol: symbol,
                startUtc:
                    historicalRange?.startUtc ??
                    today.subtract(const Duration(days: 28)),
                endUtc: historicalRange?.endUtc ?? today,
              );
              if (stop.isCompleted) return;
            }
            _history = downloaded;
            _fetchedAt = now;
          }
          final existing = _configuration;
          final parametersByLabel = {
            for (final row
                in (existing?['strategies'] as List? ?? const []).cast<Map>())
              row['label']: (row['parameters'] as Map).map(
                (key, value) =>
                    MapEntry(key as String, (value as num).toDouble()),
              ),
          };
          final strategies = [
            for (final strategy in eligible)
              StrategySettings(
                strategyId: strategy.strategyId,
                label: strategy.label,
                intervalMinutes: 1,
                startingCash: strategy.startingCash,
                parameters:
                    parametersByLabel[strategy.label] ?? strategy.parameters,
              ),
          ];
          _setActivity(
            _ResearchPhase.tuning,
            'Retuning strategies',
            detail: 'Preparing the candle sample',
          );
          final progressPort = ReceivePort();
          progressPort.listen((message) {
            if (stop.isCompleted || message is! _ResearchProgress) return;
            _setActivity(
              message.phase,
              message.phase == _ResearchPhase.replaying
                  ? 'Replaying the tuned simulation'
                  : 'Retuning strategies',
              progress: message.progress,
              remainingSeconds: message.remainingSeconds,
              detail: message.detail,
            );
          });
          final ({List<StrategyTuningResult> results, SimulatorEngine? preview})
          cycle;
          try {
            cycle = await _researchInIsolate(
              history: _history,
              start: _start!,
              end: _end!,
              watchlist: watchlist,
              risk: risk,
              strategies: strategies,
              generations: generations,
              seed: _random.nextInt(1 << 30),
              recordPreview: onPreview != null,
              previousTrials: _previousTrials,
              evolution: _evolution,
              progressPort: progressPort.sendPort,
              algorithms: algorithmDefinitions?.call() ?? const [],
            );
          } finally {
            progressPort.close();
          }
          if (stop.isCompleted) return;
          final results = cycle.results;
          if (_evolutionLimit != null) {
            for (final result in results) {
              if (result.candidateParameters case final trial?) {
                (_previousTrials[result.label] ??= []).add(trial);
              }
            }
          }
          final improved = {
            for (final result in results)
              if (result.changed) result.label: result.tunedParameters,
          };
          if (improved.isNotEmpty) {
            _configuration = {
              ...source,
              'strategies': [
                for (final row in (source['strategies'] as List).cast<Map>())
                  {
                    ...row,
                    'intervalMinutes': 1,
                    'parameters':
                        improved[row['label']] ??
                        parametersByLabel[row['label']] ??
                        row['parameters'],
                  },
              ],
            };
          }
          _cycles++;
          _improvements = improved.length;
          _lastResults = [for (final result in results) result.toJson()];
          _tested = results.fold(
            0,
            (total, row) => total + row.candidatesTested,
          );
          _setActivity(
            _ResearchPhase.waiting,
            _tested == 0
                ? 'Sample had too few candles to tune'
                : 'Waiting for the next sample',
          );
          if (cycle.preview case final engine?) {
            final start = _start!;
            final end = _end!;
            onPreview?.call(
              {
                ...source,
                'strategies': [
                  for (final strategy in engine.strategies)
                    {
                      'strategyId': strategy.strategyId,
                      'label': strategy.label,
                      'parameters': strategy.parameters,
                      'intervalMinutes': strategy.intervalMinutes,
                      'enabled': strategy.enabled,
                      'startingCash': ?strategy.startingCash,
                    },
                ],
              },
              engine,
              historicalRange ??
                  (
                    startUtc: start,
                    endUtc: end,
                    label:
                        '${MountainTime.formatDate(start)} to '
                        '${MountainTime.formatDate(end.subtract(const Duration(days: 1)))}',
                  ),
            );
          }
          if (_evolutionLimit case final limit?) {
            onCheckpoint?.call();
            if (_tested == 0) {
              _setActivity(
                _ResearchPhase.complete,
                eligible.isEmpty
                    ? (cycle.preview == null
                          ? 'No candles available for the benchmark replay'
                          : 'Benchmark replay complete')
                    : 'Too few candles to evolve strategies',
              );
              return;
            }
            if (_cycles >= limit) {
              _setActivity(_ResearchPhase.complete, 'Generations complete');
              return;
            }
          }
        } catch (error) {
          if (stop.isCompleted) return;
          _setActivity(_ResearchPhase.error, 'Research cycle failed: $error');
          if (_evolutionLimit != null) return;
        }
        final delay =
            cycleDelay == Duration.zero &&
                (_phase == _ResearchPhase.error || _tested == 0)
            ? const Duration(seconds: 5)
            : cycleDelay;
        if (delay == Duration.zero) {
          await Future<void>.delayed(Duration.zero);
          continue;
        }
        _nextCycleAt = clock().toUtc().add(delay);
        final wake = Completer<void>();
        _timer = Timer(delay, wake.complete);
        await Future.any([wake.future, stop.future]);
        _nextCycleAt = null;
      }
    } finally {
      _timer?.cancel();
      _timer = null;
      _stop = null;
      _nextCycleAt = null;
      if (_phase != _ResearchPhase.complete && _phase != _ResearchPhase.error) {
        _setActivity(_ResearchPhase.stopped, 'Stopped');
      }
      onCheckpoint?.call();
    }
  }
}

// Its closure captures replay inputs only, never the scheduler or HTTP client.
Future<({List<StrategyTuningResult> results, SimulatorEngine? preview})>
_researchInIsolate({
  required Map<String, List<MinuteBar>> history,
  required DateTime start,
  required DateTime end,
  required List<String> watchlist,
  required TuningRisk risk,
  required List<StrategySettings> strategies,
  required int generations,
  required int seed,
  required bool recordPreview,
  required Map<String, List<Map<String, double>>> previousTrials,
  required EvolutionSettings evolution,
  required SendPort progressPort,
  required List<Map<String, dynamic>> algorithms,
}) => Isolate.run(() async {
  final library = AlgorithmLibrary(Directory.systemTemp);
  await library.restore(algorithms);
  try {
    const minute = Duration(minutes: 1);
    final candles = {
      for (final symbol in watchlist)
        symbol: [
          for (final bar in history[symbol]!)
            if (!bar.openTime.isBefore(start) &&
                !bar.openTime.add(minute).isAfter(end) &&
                UsEquityCalendar.sessionAt(bar.openTime) != null)
              Candle(
                symbol: symbol,
                time: bar.openTime.add(minute),
                open: bar.open,
                high: bar.high,
                low: bar.low,
                close: bar.close,
                volume: bar.volume,
              ),
        ],
    };
    final results =
        StrategyTuner(
          candlesByInterval: {1: candles},
          watchlist: watchlist,
          strategies: strategies,
          risk: risk,
          generations: generations,
          seed: seed,
          optimizeNetReturn: true,
          previousTrials: previousTrials,
          evolution: evolution,
          randomCandidates: evolution.candidatesPerGeneration,
        ).run(
          onProgress: (progress) => progressPort.send((
            phase: _ResearchPhase.tuning,
            progress: progress.fraction,
            remainingSeconds: progress.remainingSeconds,
            detail: null,
          )),
        );
    if (!recordPreview || candles.values.every((bars) => bars.isEmpty)) {
      return (results: results, preview: null);
    }

    final acceptedParameters = {
      for (final result in results) result.label: result.tunedParameters,
    };
    final preview = risk.createEngine(
      watchlist: watchlist,
      strategies: [
        for (final strategy in strategies)
          StrategySettings(
            strategyId: strategy.strategyId,
            label: strategy.label,
            parameters:
                acceptedParameters[strategy.label] ?? strategy.parameters,
            intervalMinutes: strategy.intervalMinutes,
            startingCash: strategy.startingCash,
          ),
      ],
      includeBenchmarks: true,
    );
    final bars = orderedReplayCandles(watchlist, candles);
    final replayClock = Stopwatch()..start();
    var nextProgressAt = 0;
    for (var index = 0; index < bars.length; index++) {
      final elapsed = replayClock.elapsedMilliseconds;
      if (elapsed >= nextProgressAt) {
        progressPort.send((
          phase: _ResearchPhase.replaying,
          progress: index / bars.length,
          remainingSeconds: index > 0 && elapsed >= 1000
              ? (elapsed * (bars.length - index) / index / 1000).ceil()
              : null,
          detail: '$index of ${bars.length} candles',
        ));
        nextProgressAt = elapsed + 250;
      }
      preview.process(bars[index]);
    }
    return (results: results, preview: preview);
  } finally {
    await library.close();
  }
});
