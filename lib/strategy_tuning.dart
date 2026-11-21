import 'dart:math' as math;

import 'simulator.dart';
import 'run_data_export.dart';

/// Strategies that cannot be tuned by replaying candles through a parameter
/// grid: the LM selector depends on a remote model and the trained models
/// depend on pinned weights rather than rule parameters.
const untunableStrategyIds = {
  'lm_selector',
  'neural_network',
  'logistic_regression',
};
const maxTuningGenerations = 10000;

class EvolutionSettings {
  const EvolutionSettings({
    this.mutationAmount = .35,
    this.additionalMutationProbability = .2,
    this.candidatesPerGeneration = 12,
    this.eliteFraction = .15,
    this.parentFraction = .5,
    this.crossoverProbability = .8,
    this.minimumMutationAmount = .005,
  });

  factory EvolutionSettings.fromJson(Map<String, dynamic>? json) {
    final settings = EvolutionSettings(
      mutationAmount: (json?['mutationAmount'] as num?)?.toDouble() ?? .35,
      additionalMutationProbability:
          (json?['additionalMutationProbability'] as num?)?.toDouble() ?? .2,
      candidatesPerGeneration:
          (json?['populationSize'] ?? json?['candidatesPerGeneration'])
              as int? ??
          12,
      eliteFraction: (json?['eliteFraction'] as num?)?.toDouble() ?? .15,
      parentFraction: (json?['parentFraction'] as num?)?.toDouble() ?? .5,
      crossoverProbability:
          (json?['crossoverProbability'] as num?)?.toDouble() ?? .8,
      minimumMutationAmount:
          (json?['minimumMutationAmount'] as num?)?.toDouble() ?? .005,
    );
    if (!settings.mutationAmount.isFinite ||
        settings.mutationAmount < .01 ||
        settings.mutationAmount > 2 ||
        !settings.additionalMutationProbability.isFinite ||
        settings.additionalMutationProbability < 0 ||
        settings.additionalMutationProbability > 1 ||
        settings.candidatesPerGeneration < 1 ||
        settings.candidatesPerGeneration > 200 ||
        !settings.eliteFraction.isFinite ||
        settings.eliteFraction < .01 ||
        settings.eliteFraction > .5 ||
        !settings.parentFraction.isFinite ||
        settings.parentFraction < .1 ||
        settings.parentFraction > 1 ||
        !settings.crossoverProbability.isFinite ||
        settings.crossoverProbability < 0 ||
        settings.crossoverProbability > 1 ||
        !settings.minimumMutationAmount.isFinite ||
        settings.minimumMutationAmount < 0 ||
        settings.minimumMutationAmount > settings.mutationAmount) {
      throw ArgumentError(
        'Choose mutation size 1–200%, minimum mutation between 0 and mutation size, '
        'probabilities 0–100%, elites 1–50%, parents 10–100%, and population 1–200.',
      );
    }
    return settings;
  }

  final double mutationAmount;
  final double additionalMutationProbability;
  final int candidatesPerGeneration;
  int get populationSize => math.max(2, candidatesPerGeneration);
  final double eliteFraction;
  final double parentFraction;
  final double crossoverProbability;
  final double minimumMutationAmount;

  Map<String, Object?> toJson() => {
    'mutationAmount': mutationAmount,
    'additionalMutationProbability': additionalMutationProbability,
    'candidatesPerGeneration': candidatesPerGeneration,
    'eliteFraction': eliteFraction,
    'parentFraction': parentFraction,
    'crossoverProbability': crossoverProbability,
    'minimumMutationAmount': minimumMutationAmount,
  };
}

/// Execution and risk assumptions copied from the source run so every
/// candidate is judged under the same costs and sizing as the original.
class TuningRisk {
  const TuningRisk({
    this.startingCash = 10000,
    this.positionSizeFraction = .2,
    this.maxExposureFraction = .9,
    this.dailyLossLimitFraction = .05,
    this.riskFraction = .02,
    this.defaultRiskPerShareFraction = .03,
    this.defaultTargetFraction = 0,
    this.spreadBps = 2,
    this.slippageBps = 3,
    this.feePerShare = .005,
    this.allowOvernight = true,
    this.enableShortSelling = false,
    this.sessionClosePolicyEnabled = false,
    this.benchmarks = const BenchmarkSettings(),
  });

  factory TuningRisk.fromSettings(Map<String, dynamic> settings) {
    final risk = settings['risk'] as Map<String, dynamic>? ?? const {};
    double value(String key, double fallback) =>
        (risk[key] as num?)?.toDouble() ?? fallback;
    return TuningRisk(
      startingCash: (settings['startingCash'] as num?)?.toDouble() ?? 10000,
      positionSizeFraction: value('positionSizeFraction', .2),
      maxExposureFraction: value('maxExposureFraction', .9),
      dailyLossLimitFraction: value('dailyLossLimitFraction', .05),
      riskFraction: value('riskFraction', .02),
      defaultRiskPerShareFraction: value('defaultRiskPerShareFraction', .03),
      defaultTargetFraction: value('defaultTargetFraction', 0),
      spreadBps: value('spreadBps', 2),
      slippageBps: value('slippageBps', 3),
      feePerShare: value('feePerShare', .005),
      allowOvernight: risk['allowOvernight'] != false,
      enableShortSelling: risk['enableShortSelling'] == true,
      sessionClosePolicyEnabled: risk['sessionClosePolicyEnabled'] == true,
      benchmarks: BenchmarkSettings.fromJson(
        settings['benchmarks'] as Map<String, dynamic>?,
      ),
    );
  }

  final double startingCash;
  final double positionSizeFraction;
  final double maxExposureFraction;
  final double dailyLossLimitFraction;
  final double riskFraction;
  final double defaultRiskPerShareFraction;
  final double defaultTargetFraction;
  final double spreadBps;
  final double slippageBps;
  final double feePerShare;
  final bool allowOvernight;
  final bool enableShortSelling;
  final bool sessionClosePolicyEnabled;
  final BenchmarkSettings benchmarks;

  SimulatorEngine createEngine({
    required List<String> watchlist,
    required List<StrategySettings> strategies,
    bool includeBenchmarks = false,
  }) => SimulatorEngine(
    watchlist: watchlist,
    strategies: strategies,
    startingCash: startingCash,
    positionSizeFraction: positionSizeFraction,
    maxExposureFraction: maxExposureFraction,
    dailyLossLimitFraction: dailyLossLimitFraction,
    riskFraction: riskFraction,
    defaultRiskPerShareFraction: defaultRiskPerShareFraction,
    defaultTargetFraction: defaultTargetFraction,
    spreadBps: spreadBps,
    slippageBps: slippageBps,
    feePerShare: feePerShare,
    allowOvernight: allowOvernight,
    enableShortSelling: enableShortSelling,
    sessionClosePolicyEnabled: sessionClosePolicyEnabled,
    includeBenchmarks: includeBenchmarks,
    benchmarks: benchmarks,
  );
}

List<Candle> orderedReplayCandles(
  List<String> watchlist,
  Map<String, List<Candle>> candles,
) => [for (final symbol in watchlist) ...?candles[symbol]]
  ..sort((a, b) {
    final byTime = a.time.compareTo(b.time);
    return byTime != 0 ? byTime : a.symbol.compareTo(b.symbol);
  });

/// Performance of one parameter set over one time segment.
class SegmentScore {
  const SegmentScore({
    required this.returnPercent,
    required this.maxDrawdownPercent,
    required this.trades,
    this.endingEquity,
  });

  final double returnPercent;
  final double maxDrawdownPercent;
  final int trades;
  final double? endingEquity;

  /// Return with a drawdown penalty, so a jagged path ranks below a smooth one.
  double get score => returnPercent - .5 * maxDrawdownPercent;

  Map<String, Object?> toJson() => {
    'returnPercent': returnPercent,
    'maxDrawdownPercent': maxDrawdownPercent,
    'trades': trades,
    'endingEquity': ?endingEquity,
  };
}

class StrategyTuningResult {
  const StrategyTuningResult({
    required this.label,
    required this.strategyId,
    required this.intervalMinutes,
    required this.status,
    required this.message,
    required this.currentParameters,
    required this.tunedParameters,
    this.candidateParameters,
    this.currentTraining,
    this.currentSelection,
    this.currentValidation,
    this.tunedTraining,
    this.tunedSelection,
    this.tunedValidation,
    this.candidatesTested = 0,
    this.bestProfitCandidate,
    this.bestWinRateCandidate,
    this.individuals = const [],
    this.populationState,
    this.championId,
  });

  final String label;
  final String strategyId;
  final int intervalMinutes;

  /// `improved`, `kept`, `insufficient`, or `skipped`.
  final String status;
  final String message;
  final Map<String, double> currentParameters;
  final Map<String, double> tunedParameters;
  final Map<String, double>? candidateParameters;
  final SegmentScore? currentTraining;
  final SegmentScore? currentSelection;
  final SegmentScore? currentValidation;
  final SegmentScore? tunedTraining;
  final SegmentScore? tunedSelection;
  final SegmentScore? tunedValidation;
  final int candidatesTested;
  final Map<String, Object?>? bestProfitCandidate;
  final Map<String, Object?>? bestWinRateCandidate;
  final List<Map<String, Object?>> individuals;
  final Map<String, Object?>? populationState;
  final String? championId;

  bool get changed => status == 'improved';

  double? _compound(SegmentScore? training, SegmentScore? selection) =>
      training == null || selection == null
      ? null
      : _compoundReturn(training.returnPercent, selection.returnPercent);

  Map<String, Object?> toJson() => {
    'label': label,
    'strategyId': strategyId,
    'intervalMinutes': intervalMinutes,
    'status': status,
    'message': message,
    'currentParameters': currentParameters,
    'tunedParameters': tunedParameters,
    'candidateParameters': candidateParameters,
    'currentTraining': currentTraining?.toJson(),
    'currentSelection': currentSelection?.toJson(),
    'currentValidation': currentValidation?.toJson(),
    'tunedTraining': tunedTraining?.toJson(),
    'tunedSelection': tunedSelection?.toJson(),
    'tunedValidation': tunedValidation?.toJson(),
    'currentDevelopmentReturn': _compound(currentTraining, currentSelection),
    'tunedDevelopmentReturn': _compound(tunedTraining, tunedSelection),
    'candidatesTested': candidatesTested,
    'bestProfitCandidate': bestProfitCandidate,
    'bestWinRateCandidate': bestWinRateCandidate,
    if (populationState != null) ...{
      'championId': championId,
      'populationSummary': {
        'size': individuals.length,
        'championId': championId,
        'candidateId': individuals.firstOrNull?['id'],
        'candidatePerformance': individuals.firstOrNull?['performance'],
        'performance': individuals
            .where((i) => i['id'] == championId)
            .firstOrNull?['performance'],
      },
      'individuals': individuals,
    },
  };
}

double _compoundReturn(double first, double second) =>
    ((1 + first / 100) * (1 + second / 100) - 1) * 100;

typedef TuningProgress = ({double fraction, int? remainingSeconds});
typedef PopulationEvaluation = ({
  List<SegmentScore> scores,
  Map<String, Object?> performance,
  Map<String, Object?> account,
});
typedef _PreparedReplay = ({
  int work,
  StrategyTuningResult Function(void Function(int)? onWork) evaluate,
});

/// Replays collected candles through many parameter sets per strategy.
///
/// Candles are split chronologically. The training and selection segments
/// choose a candidate, then the final holdout checks it once.
class StrategyTuner {
  StrategyTuner({
    required this.candlesByInterval,
    required this.watchlist,
    required this.strategies,
    this.risk = const TuningRisk(),
    this.trainingFraction = .6,
    this.randomCandidates = 12,
    this.generations = 2,
    this.minimumTrainingTrades = 2,
    this.minimumBarsAfterWarmup = 30,
    this.seed = 42,
    this.optimizeNetReturn = false,
    this.previousTrials = const {},
    this.evolution = const EvolutionSettings(),
  });

  /// Completed candles keyed by interval minutes, then by symbol.
  final Map<int, Map<String, List<Candle>>> candlesByInterval;
  final List<String> watchlist;
  final List<StrategySettings> strategies;
  final TuningRisk risk;
  final double trainingFraction;
  final int randomCandidates;
  final int generations;
  final int minimumTrainingTrades;
  final int minimumBarsAfterWarmup;
  final int seed;
  final bool optimizeNetReturn;
  final Map<String, List<Map<String, double>>> previousTrials;
  final EvolutionSettings evolution;

  List<StrategyTuningResult> run({void Function(TuningProgress)? onProgress}) {
    final sortedBars = <int, List<Candle>>{};
    final replays = [
      for (final settings in strategies.where((item) => item.enabled))
        _prepare(settings, sortedBars),
    ];
    final total = replays.fold(0, (sum, replay) => sum + replay.work);
    final clock = Stopwatch()..start();
    var nextReportAt = 0;
    var finishedWork = 0;
    void report(int completed) {
      final elapsed = clock.elapsedMilliseconds;
      if (elapsed < nextReportAt || completed == total) return;
      nextReportAt = elapsed + 250;
      final fraction = completed / total;
      onProgress!((
        fraction: fraction,
        remainingSeconds: completed > 0 && elapsed >= 1000
            ? (elapsed * (total - completed) / completed / 1000).ceil()
            : null,
      ));
    }

    final results = <StrategyTuningResult>[];
    if (onProgress != null && total > 0) report(0);
    for (final replay in replays) {
      results.add(
        replay.evaluate(
          onProgress == null || replay.work == 0
              ? null
              : (work) => report(finishedWork + work),
        ),
      );
      finishedWork += replay.work;
    }
    onProgress?.call((fraction: 1, remainingSeconds: 0));
    return results;
  }

  StrategyTuningResult tuneOne(StrategySettings settings) =>
      _prepare(settings, {}).evaluate(null);

  /// Uses exactly the same fills, risk limits and native worker fast path as tuning.
  List<PopulationEvaluation> evaluatePopulation(
    StrategySettings settings,
    List<Map<String, double>> candidates, {
    void Function(int)? onWork,
  }) {
    final bars = orderedReplayCandles(
      watchlist,
      candlesByInterval[settings.intervalMinutes] ?? {},
    );
    final times = bars.map((b) => b.time).toSet().toList()..sort();
    final cuts = times.length < 3
        ? <DateTime>[]
        : [
            times[(times.length * .6).floor()],
            times[(times.length * .8).floor()],
          ];
    return _replayCandidates(
      settings,
      StrategyRegistry.byId(settings.strategyId),
      bars,
      cuts,
      candidates,
      onWork,
      captureAccounts: true,
    );
  }

  _PreparedReplay _prepare(
    StrategySettings settings,
    Map<int, List<Candle>> sortedBars,
  ) {
    final strategy = StrategyRegistry.all
        .where((item) => item.id == settings.strategyId)
        .firstOrNull;
    final current = _complete(strategy, settings.parameters);
    _PreparedReplay skipped(
      String status,
      String message, {
      Map<String, double>? candidate,
    }) => (
      work: 0,
      evaluate: (_) => StrategyTuningResult(
        label: settings.label,
        strategyId: settings.strategyId,
        intervalMinutes: settings.intervalMinutes,
        status: status,
        message: message,
        currentParameters: current,
        tunedParameters: current,
        candidateParameters: candidate,
      ),
    );
    if (strategy == null) {
      return skipped('skipped', 'Unknown strategy; nothing to tune.');
    }
    if (untunableStrategyIds.contains(strategy.id)) {
      return skipped(
        'skipped',
        'Model or LM-driven strategies are not tuned from candles.',
      );
    }
    if (strategy.parameters.isEmpty) {
      return skipped('skipped', 'This strategy has no adjustable parameters.');
    }
    final bars = sortedBars.putIfAbsent(settings.intervalMinutes, () {
      final bySymbol = candlesByInterval[settings.intervalMinutes] ?? const {};
      return orderedReplayCandles(watchlist, bySymbol);
    });
    final times = bars.map((bar) => bar.time).toSet().toList()..sort();
    final warmup = _largestWarmup(strategy, current);
    final trainingTimes = (times.length * trainingFraction).floor();
    final selectionTimes = (times.length - trainingTimes) ~/ 2;
    final candidates = _candidates(strategy, current);
    if (trainingTimes < warmup + minimumBarsAfterWarmup ||
        selectionTimes < minimumBarsAfterWarmup) {
      final mutation = _mutations(
        strategy,
        [current],
        [current],
        math.Random(seed),
        scale: .35,
      ).firstOrNull;
      final minimum = math.max(
        ((warmup + minimumBarsAfterWarmup) / trainingFraction).ceil(),
        (2 * minimumBarsAfterWarmup / (1 - trainingFraction)).ceil(),
      );
      return skipped(
        'insufficient',
        'Needs about $minimum distinct ${settings.intervalMinutes}m bar times '
            'to cover training, selection and holdout; collected ${times.length}.',
        candidate: mutation ?? candidates.skip(1).firstOrNull,
      );
    }
    final cuts = [times[trainingTimes], times[trainingTimes + selectionTimes]];
    return (
      work: bars.length * (candidates.length + generations * randomCandidates),
      evaluate: (onWork) =>
          _evaluate(settings, strategy, bars, cuts, candidates, onWork),
    );
  }

  StrategyTuningResult _evaluate(
    StrategySettings settings,
    TradingStrategy strategy,
    List<Candle> bars,
    List<DateTime> cuts,
    List<Map<String, double>> candidates,
    void Function(int)? onWork,
  ) {
    final scores = <List<SegmentScore>>[];
    final performance = <Map<String, Object?>>[];
    void replay(List<Map<String, double>> batch) {
      final priorWork = scores.length * bars.length;
      final batchResults = _replayCandidates(
        settings,
        strategy,
        bars,
        cuts,
        batch,
        onWork == null ? null : (work) => onWork(priorWork + work),
      );
      scores.addAll(batchResults.map((result) => result.scores));
      performance.addAll(batchResults.map((result) => result.performance));
    }

    replay(candidates);
    final current = scores.first;
    double gain(int i) {
      final candidate = scores[i];
      if (optimizeNetReturn) {
        return _developmentReturn(candidate) - _developmentReturn(current);
      }
      return math.min(
        candidate[0].score - current[0].score,
        candidate[1].score - current[1].score,
      );
    }

    final random = math.Random(seed);
    for (var generation = 0; generation < generations; generation++) {
      final ranked = List<int>.generate(scores.length, (i) => i)
        ..sort((a, b) {
          final byGain = gain(b).compareTo(gain(a));
          return byGain == 0 ? a.compareTo(b) : byGain;
        });
      final parents = (optimizeNetReturn ? ranked : ranked.take(4))
          .map((i) => candidates[i])
          .toList();
      final batch = _mutations(
        strategy,
        candidates,
        parents,
        random,
        scale: evolution.mutationAmount / (1 + generation * .3),
        adaptive: optimizeNetReturn,
      );
      if (batch.isEmpty) break;
      replay(batch);
      candidates.addAll(batch);
    }

    var bestIndex = 0;
    int? experimentalIndex;
    int? freshTrialIndex;
    final tried = previousTrials[settings.label] ?? const [];
    for (var i = 1; i < scores.length; i++) {
      if (experimentalIndex == null || gain(i) > gain(experimentalIndex)) {
        experimentalIndex = i;
      }
      if (tried.isNotEmpty &&
          (freshTrialIndex == null || gain(i) > gain(freshTrialIndex)) &&
          !tried.any(
            (previous) => candidates[i].entries.every(
              (entry) => previous[entry.key] == entry.value,
            ),
          )) {
        freshTrialIndex = i;
      }
      final candidate = scores[i];
      final enoughEvidence = optimizeNetReturn
          ? candidate[0].trades + candidate[1].trades >= minimumTrainingTrades
          : _beats(candidate[0], current[0]) &&
                _beats(candidate[1], current[1]);
      if (enoughEvidence && gain(i) > gain(bestIndex)) {
        bestIndex = i;
      }
    }
    final holdout = scores[bestIndex][2];
    final passedHoldout = optimizeNetReturn
        ? holdout.trades >= minimumTrainingTrades &&
              holdout.returnPercent > current[2].returnPercent
        : _beats(holdout, current[2]);
    final improved = bestIndex != 0 && passedHoldout;
    final preferred = bestIndex == 0 ? experimentalIndex : bestIndex;
    final selected = improved ? preferred : freshTrialIndex ?? preferred;
    final best = scores[selected ?? 0];
    final message = selected != preferred
        ? 'No candidate was accepted. Showing a different tested mutation.'
        : bestIndex == 0
        ? 'No candidate met the training and selection checks.'
        : improved
        ? (optimizeNetReturn
              ? 'The candidate earned a higher net return on development and holdout data.'
              : 'The selected candidate beat the current settings in all three periods.')
        : 'The selected candidate fell short on the final holdout.';
    var profitIndex = 0;
    int? winIndex;
    for (var i = 0; i < performance.length; i++) {
      final profit = performance[i]['netProfit'] as num;
      if (profit > (performance[profitIndex]['netProfit'] as num)) {
        profitIndex = i;
      }
      final rate = performance[i]['winRatePercent'] as num?;
      if (rate != null &&
          (winIndex == null ||
              rate > (performance[winIndex]['winRatePercent'] as num) ||
              (rate == performance[winIndex]['winRatePercent'] &&
                  profit > (performance[winIndex]['netProfit'] as num)))) {
        winIndex = i;
      }
    }
    Map<String, Object?> bookmark(int index) => {
      'parameters': candidates[index],
      'performance': performance[index],
    };
    return StrategyTuningResult(
      label: settings.label,
      strategyId: strategy.id,
      intervalMinutes: settings.intervalMinutes,
      status: improved ? 'improved' : 'kept',
      message: message,
      currentParameters: candidates.first,
      tunedParameters: improved ? candidates[bestIndex] : candidates.first,
      candidateParameters: selected == null ? null : candidates[selected],
      currentTraining: current[0],
      currentSelection: current[1],
      currentValidation: current[2],
      tunedTraining: best[0],
      tunedSelection: best[1],
      tunedValidation: best[2],
      candidatesTested: candidates.length,
      bestProfitCandidate: bookmark(profitIndex),
      bestWinRateCandidate: winIndex == null ? null : bookmark(winIndex),
    );
  }

  List<PopulationEvaluation> _replayCandidates(
    StrategySettings settings,
    TradingStrategy strategy,
    List<Candle> bars,
    List<DateTime> cuts,
    List<Map<String, double>> candidates,
    void Function(int)? onWork, {
    bool captureAccounts = false,
  }) {
    final labels = [for (var i = 0; i < candidates.length; i++) 'c$i'];
    var engine = risk.createEngine(
      watchlist: watchlist,
      strategies: [
        for (var i = 0; i < candidates.length; i++)
          StrategySettings(
            strategyId: strategy.id,
            label: labels[i],
            parameters: candidates[i],
            intervalMinutes: settings.intervalMinutes,
            startingCash: settings.startingCash,
          ),
      ],
    );
    final tradesAtCuts = <Map<String, int>>[];
    if (strategy is CandidateReplayStrategy) {
      final replay = (strategy).replayCandidates(
        checkpoint: engine.checkpoint(),
        strategies: [
          for (final setting in engine.strategies)
            {
              'strategyId': setting.strategyId,
              'label': setting.label,
              'parameters': setting.parameters,
              'intervalMinutes': setting.intervalMinutes,
              'startingCash': setting.startingCash,
            },
        ],
        bars: bars,
        cuts: cuts,
        retainFills: captureAccounts,
        onProgress: onWork == null
            ? null
            : (count) => onWork(count * candidates.length),
      );
      engine = SimulatorEngine.restore(
        watchlist: watchlist,
        strategies: engine.strategies,
        startingCash: engine.startingCash,
        checkpoint: Map<String, dynamic>.from(replay['checkpoint'] as Map),
      );
      tradesAtCuts.addAll(
        (replay['tradesAtCuts'] as List).map(
          (row) => (row as Map).map(
            (key, value) => MapEntry(key as String, value as int),
          ),
        ),
      );
      onWork?.call(bars.length * candidates.length);
    } else {
      for (var i = 0; i < bars.length; i++) {
        final bar = bars[i];
        if (tradesAtCuts.length < cuts.length &&
            !bar.time.isBefore(cuts[tradesAtCuts.length])) {
          tradesAtCuts.add({
            for (final account in engine.accounts.values)
              account.label: account.closedTradeCount,
          });
        }
        engine.process(bar);
        StrategyRegistry.checkExecutionHealth();
        // Tuning only needs equity and trade counts, so drop the event log.
        for (final account in engine.accounts.values) {
          if (captureAccounts) {
            account.events.removeWhere((event) => event.kind != 'fill');
          } else {
            account.events.clear();
          }
        }
        onWork?.call((i + 1) * candidates.length);
      }
    }
    final accounts = captureAccounts
        ? engine.checkpoint()['accounts'] as Map
        : const {};
    return [
      for (final label in labels)
        (
          account: captureAccounts
              ? {
                  ...Map<String, Object?>.from(accounts[label] as Map),
                  'equity': engine.markToMarket(engine.accounts[label]!),
                  'label': label,
                }
              : const <String, Object?>{},
          scores: _scoreSegments(engine.accounts[label]!, cuts, [
            for (final counts in tradesAtCuts) counts[label]!,
          ]),
          performance: portfolioPerformance({
            if (captureAccounts)
              ...Map<String, Object?>.from(accounts[label] as Map),
            'startingCash': engine.accounts[label]!.startingCash,
            'equity': engine.markToMarket(engine.accounts[label]!),
            'closedPnl': engine.accounts[label]!.closedPnl,
            'history': [
              for (final point in engine.accounts[label]!.history)
                {'value': point.value},
            ],
          }, defaultStartingCash: risk.startingCash),
        ),
    ];
  }

  bool _beats(SegmentScore candidate, SegmentScore current) =>
      candidate.trades >= minimumTrainingTrades &&
      candidate.score > current.score &&
      candidate.returnPercent >= current.returnPercent;

  static double _developmentReturn(List<SegmentScore> scores) =>
      _compoundReturn(scores[0].returnPercent, scores[1].returnPercent);

  static Map<String, double> _complete(
    TradingStrategy? strategy,
    Map<String, double> parameters,
  ) => {
    if (strategy != null)
      for (final parameter in strategy.parameters)
        parameter.name: parameters[parameter.name] ?? parameter.defaultValue,
  };

  static int _largestWarmup(
    TradingStrategy strategy,
    Map<String, double> parameters,
  ) {
    var warmup = strategy.warmupBars;
    for (final parameter in strategy.parameters) {
      final name = parameter.name.toLowerCase();
      if (parameter.unit == 'bars' &&
          !name.contains('hold') &&
          !name.contains('expiry')) {
        warmup = math.max(warmup, parameters[parameter.name]!.round() + 1);
      }
    }
    return warmup;
  }

  static bool _integer(StrategyParameter parameter) =>
      parameter.unit == 'bars' || parameter.unit == 'minutes';

  static double _clamp(StrategyParameter parameter, double value) {
    final clamped = value.clamp(parameter.minimum, parameter.maximum);
    return _integer(parameter)
        ? clamped.roundToDouble()
        : double.parse(clamped.toStringAsFixed(4));
  }

  static bool _consistent(Map<String, double> parameters) {
    bool ordered(String fast, String slow) =>
        !(parameters.containsKey(fast) && parameters.containsKey(slow)) ||
        parameters[fast]! < parameters[slow]!;
    return ordered('fastPeriod', 'slowPeriod') &&
        ordered('fastPeriod', 'trendPeriod') &&
        ordered('exitLookback', 'lookback') &&
        ordered('exitProbability', 'entryProbability');
  }

  /// Current settings first, then defaults, one-at-a-time steps, and a few
  /// seeded random combinations. Duplicates and inconsistent sets are dropped.
  List<Map<String, double>> _candidates(
    TradingStrategy strategy,
    Map<String, double> current,
  ) {
    final seen = <String>{};
    final result = <Map<String, double>>[];
    void add(Map<String, double> candidate, {bool force = false}) {
      final key = strategy.parameters
          .map((parameter) => candidate[parameter.name])
          .join('|');
      if (!seen.add(key)) return;
      if (!force && !_consistent(candidate)) return;
      result.add(candidate);
    }

    add(current, force: true);
    add({
      for (final parameter in strategy.parameters)
        parameter.name: parameter.defaultValue,
    });
    const factors = [.5, .75, 1.25, 1.5, 2.0];
    for (final parameter in strategy.parameters) {
      final base = current[parameter.name]!;
      for (final factor in factors) {
        final value = base == 0
            ? parameter.minimum +
                  (parameter.maximum - parameter.minimum) * (factor - .5) / 3
            : base * factor;
        add({...current, parameter.name: _clamp(parameter, value)});
      }
    }
    final random = math.Random(seed);
    for (var i = 0; i < randomCandidates * 3; i++) {
      if (result.length >=
          2 + strategy.parameters.length * factors.length + randomCandidates) {
        break;
      }
      add({
        for (final parameter in strategy.parameters)
          parameter.name: _clamp(
            parameter,
            current[parameter.name] == 0
                ? parameter.minimum +
                      random.nextDouble() *
                          (parameter.maximum - parameter.minimum) /
                          4
                : current[parameter.name]! *
                      math.pow(2, random.nextDouble() * 2 - 1),
          ),
      });
    }
    return result;
  }

  List<Map<String, double>> _mutations(
    TradingStrategy strategy,
    List<Map<String, double>> previous,
    List<Map<String, double>> parents,
    math.Random random, {
    required double scale,
    bool adaptive = false,
  }) {
    final parameters = strategy.parameters;
    String key(Map<String, double> candidate) =>
        parameters.map((parameter) => candidate[parameter.name]).join('|');
    final seen = previous.map(key).toSet();
    final next = <Map<String, double>>[];
    for (
      var attempt = 0;
      attempt < randomCandidates * 8 && next.length < randomCandidates;
      attempt++
    ) {
      // Sample across the ranks, including the weakest performers. Previous
      // candidates stay in the pool, so exploratory mutations cannot erase a
      // strong set of parameters.
      final rank = adaptive
          ? (attempt % randomCandidates) *
                (parents.length - 1) ~/
                math.max(1, randomCandidates - 1)
          : random.nextInt(parents.length);
      final parent = parents[rank];
      final weakness = rank / math.max(1, parents.length - 1);
      final stepScale = adaptive ? scale * (.25 + 1.5 * weakness) : scale;
      final additionalMutationRate = adaptive
          ? (evolution.additionalMutationProbability * (.5 + 3.25 * weakness))
                .clamp(0.0, 1.0)
          : evolution.additionalMutationProbability;
      final mutation = {...parent};
      final primary = parameters[random.nextInt(parameters.length)];
      for (final parameter in parameters) {
        if (parameter != primary &&
            random.nextDouble() >= additionalMutationRate) {
          continue;
        }
        final value = parent[parameter.name]!;
        final range = parameter.maximum - parameter.minimum;
        final step = math.max(value.abs() * stepScale, range * stepScale * .05);
        mutation[parameter.name] = _clamp(
          parameter,
          value + step * (random.nextDouble() * 2 - 1),
        );
      }
      if (_consistent(mutation) && seen.add(key(mutation))) next.add(mutation);
    }
    return next;
  }

  static List<SegmentScore> _scoreSegments(
    StrategyAccount account,
    List<DateTime> cuts,
    List<int> tradesAtCuts,
  ) {
    final scores = <SegmentScore>[];
    var start = account.startingCash;
    var end = start;
    var peak = start;
    var drawdown = 0.0;
    var priorTrades = 0;
    void finish(int totalTrades) {
      scores.add(
        SegmentScore(
          returnPercent: start == 0 ? 0 : (end / start - 1) * 100,
          maxDrawdownPercent: drawdown,
          trades: totalTrades - priorTrades,
          endingEquity: end,
        ),
      );
      start = peak = end;
      drawdown = 0;
      priorTrades = totalTrades;
    }

    for (final point in account.history) {
      final segment = scores.length;
      if (segment < cuts.length && !point.time.isBefore(cuts[segment])) {
        finish(tradesAtCuts[segment]);
      }
      end = point.value;
      peak = math.max(peak, end);
      if (peak > 0) drawdown = math.max(drawdown, (peak - end) / peak * 100);
    }
    finish(account.closedTradeCount);
    return scores;
  }
}
