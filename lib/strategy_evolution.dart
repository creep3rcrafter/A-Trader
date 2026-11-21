import 'dart:math' as math;

import 'simulator.dart';
import 'strategy_tuning.dart';

/// One generation of a durable, per-strategy genetic population. All members
/// are replayed against the same candles and execution assumptions.
class StrategyEvolution {
  StrategyEvolution({
    required this.tuner,
    required this.generation,
    this.populations = const {},
    this.changingSample = false,
  });

  final StrategyTuner tuner;
  final int generation;
  final Map<String, Map<String, dynamic>> populations;
  final bool changingSample;

  List<StrategyTuningResult> run({void Function(TuningProgress)? onProgress}) {
    final enabled = tuner.strategies.where((s) => s.enabled).toList();
    final results = <StrategyTuningResult>[];
    final clock = Stopwatch()..start();
    for (var i = 0; i < enabled.length; i++) {
      results.add(
        _evolve(enabled[i], (fraction) {
          final total = (i + fraction) / enabled.length;
          onProgress?.call((
            fraction: total,
            remainingSeconds: total > 0 && clock.elapsedMilliseconds > 1000
                ? (clock.elapsedMilliseconds * (1 - total) / total / 1000)
                      .ceil()
                : null,
          ));
        }),
      );
    }
    onProgress?.call((fraction: 1, remainingSeconds: 0));
    return results;
  }

  StrategyTuningResult _evolve(
    StrategySettings setting,
    void Function(double) progress,
  ) {
    final strategy = StrategyRegistry.byId(setting.strategyId);
    final old = populations[setting.label];
    final settings = tuner.evolution;
    final seed = old?['seed'] as int? ?? tuner.seed;
    final random = math.Random(seed + generation * 104729);
    var serial = old?['serial'] as int? ?? 0;
    final current = {
      for (final p in strategy.parameters)
        p.name: setting.parameters[p.name] ?? p.defaultValue,
    };
    final previous = [
      for (final row in old?['members'] as List? ?? const [])
        Map<String, Object?>.from(row as Map),
    ]..sort(_rank);
    final priorChampion = previous
        .where((p) => p['id'] == old?['championId'])
        .firstOrNull;
    final members = <Map<String, Object?>>[];
    Map<String, double> genes(Map row) => (row['parameters'] as Map).map(
      (k, v) => MapEntry(k as String, (v as num).toDouble()),
    );
    Map<String, Object?> member(
      Map<String, double> parameters, {
      List<String> parents = const [],
      double mutation = 0,
      double solidity = 0,
    }) => {
      'id': 'I${(++serial).toString().padLeft(6, '0')}',
      'birthGeneration': generation,
      'parameters': parameters,
      'parents': parents,
      'mutationAmount': mutation,
      'solidification': solidity,
      'elite': false,
    };

    if (previous.isEmpty) {
      members.add(member(current));
    } else {
      // The champion survives independently of the weighted fitness ranking.
      final keep = [
        ?priorChampion,
        ...previous.where((p) => p['id'] != priorChampion?['id']),
      ];
      final count = math.max(
        1,
        (settings.populationSize * settings.eliteFraction).ceil(),
      );
      for (final p in keep.take(count)) {
        members.add({...p, 'elite': true, 'mutationAmount': 0.0});
      }
    }
    final parentCount = math.max(
      2,
      (previous.length * settings.parentFraction).ceil(),
    );
    final parents = previous.take(parentCount).toList();
    if (priorChampion != null &&
        !parents.any((p) => p['id'] == priorChampion['id'])) {
      parents.add(priorChampion);
    }
    final seen = members.map((m) => _key(genes(m))).toSet();
    while (members.length < settings.populationSize) {
      final index = members.length;
      final p1 = parents.isEmpty
          ? members.first
          : parents[random.nextInt(parents.length)];
      var p2 = p1;
      if (parents.length > 1 &&
          random.nextDouble() < settings.crossoverProbability) {
        final others = parents.where((p) => p['id'] != p1['id']).toList();
        p2 = others[random.nextInt(others.length)];
      }
      final a = genes(p1);
      final b = genes(p2);
      final solid =
          (((p1['solidification'] as num?)?.toDouble() ?? 0) +
              ((p2['solidification'] as num?)?.toDouble() ?? 0)) /
          2;
      final weakness = previous.isEmpty
          ? index / settings.populationSize
          : (previous
                    .indexWhere((p) => p['id'] == p1['id'])
                    .clamp(0, previous.length - 1)) /
                math.max(1, previous.length - 1);
      final scale = math.max(
        settings.minimumMutationAmount,
        settings.mutationAmount * (.3 + weakness * 1.7) * (1 - .9 * solid),
      );
      var child = a;
      for (var attempt = 0; attempt < 40; attempt++) {
        child = {
          for (final p in strategy.parameters)
            p.name: random.nextBool() ? a[p.name]! : b[p.name]!,
        };
        // At least one variable is selected; weak parents change more variables.
        final primary = strategy.parameters.isEmpty
            ? null
            : strategy.parameters[random.nextInt(strategy.parameters.length)];
        for (final p in strategy.parameters) {
          if (p != primary &&
              random.nextDouble() >=
                  (settings.additionalMutationProbability * (.5 + 2 * weakness))
                      .clamp(0, 1)) {
            continue;
          }
          final value = child[p.name]!;
          final step =
              math.max(value.abs(), (p.maximum - p.minimum) * .05) * scale;
          final delta = (random.nextDouble() * 2 - 1) * step;
          var next = _bound(p, value + delta);
          if (_discrete(p) && next == value && p.maximum > p.minimum) {
            next = _bound(p, value + (delta < 0 ? -1 : 1));
          }
          child[p.name] = next;
        }
        if (_consistent(child) && seen.add(_key(child))) break;
        child = a;
      }
      // A finite or parameter-free search space can legitimately contain clones.
      members.add(
        member(
          child,
          parents: {p1['id'] as String, p2['id'] as String}.toList(),
          mutation: scale,
          solidity: solid,
        ),
      );
    }
    final bars =
        tuner.candlesByInterval[setting.intervalMinutes]?.values.fold<int>(
          0,
          (n, values) => n + values.length,
        ) ??
        0;
    final evaluations = tuner.evaluatePopulation(
      setting,
      members.map(genes).toList(),
      onWork: (work) => progress(
        bars == 0 ? 1 : (work / (bars * members.length)).clamp(0, 1),
      ),
    );
    // The incumbent is replayed first. For changing windows, only compare
    // results measured on this sample when rewarding smaller mutations.
    final currentIncumbent = evaluations.first.performance;
    for (var i = 0; i < members.length; i++) {
      final m = members[i];
      final performance = evaluations[i].performance;
      m['performance'] = performance;
      m['generation'] = generation;
      m['strategyId'] = strategy.id;
      m['strategyLabel'] = setting.label;
      m['fitness'] = fitness(performance);
      m['account'] = {
        ...evaluations[i].account,
        'label': m['id'],
        'events': [
          for (final event
              in evaluations[i].account['events'] as List? ?? const [])
            <String, Object?>{
              ...Map<String, Object?>.from(event as Map),
              'strategy': m['id'],
            },
        ],
      };
      final ancestors = previous.where(
        (p) => (m['parents'] as List).contains(p['id']),
      );
      final improvedOnSample = changingSample
          ? _dominates(performance, currentIncumbent, strict: true)
          : ancestors.isNotEmpty &&
                ancestors.every(
                  (p) => _dominates(
                    performance,
                    p['performance'] as Map,
                    strict: true,
                  ),
                );
      if (m['elite'] != true &&
          improvedOnSample &&
          _number(performance, 'netProfit') > 0) {
        m['solidification'] = (((m['solidification'] as num).toDouble()) + .15)
            .clamp(0, 1);
      }
    }
    final baseline = members.firstWhere(
      (m) => m['id'] == priorChampion?['id'],
      orElse: () => members.first,
    );
    var champion = baseline;
    final ranked = List<Map<String, Object?>>.of(members)..sort(_rank);
    for (final m in ranked) {
      if (_dominates(
        m['performance'] as Map,
        champion['performance'] as Map,
        strict: true,
      )) {
        champion = m;
      }
    }
    for (var i = 0; i < ranked.length; i++) {
      ranked[i]['rank'] = i + 1;
      ranked[i]['champion'] = ranked[i]['id'] == champion['id'];
    }
    final championIndex = members.indexOf(champion);
    final baselineIndex = members.indexOf(baseline);
    final before = evaluations[baselineIndex].scores;
    final after = evaluations[championIndex].scores;
    final profitOrder = List<Map<String, Object?>>.of(members)
      ..sort(
        (a, b) => _number(
          b['performance'] as Map,
          'netProfit',
        ).compareTo(_number(a['performance'] as Map, 'netProfit')),
      );
    final winOrder =
        members
            .where((m) => _number(m['performance'] as Map, 'closedTrades') > 0)
            .toList()
          ..sort((a, b) {
            final cmp = _number(
              b['performance'] as Map,
              'winRatePercent',
            ).compareTo(_number(a['performance'] as Map, 'winRatePercent'));
            return cmp == 0 ? _rank(a, b) : cmp;
          });
    Map<String, Object?> bookmark(Map m) => {
      'parameters': m['parameters'],
      'performance': m['performance'],
    };
    final improved = _key(genes(champion)) != _key(genes(baseline));
    return StrategyTuningResult(
      label: setting.label,
      strategyId: strategy.id,
      intervalMinutes: setting.intervalMinutes,
      status: improved ? 'improved' : 'kept',
      message: improved
          ? 'A child improved profit without lowering win rate. Champion retained.'
          : 'Champion retained; offspring will breed and mutate again.',
      currentParameters: genes(baseline),
      tunedParameters: genes(champion),
      candidateParameters: genes(ranked.first),
      candidatesTested: members.length,
      currentTraining: before.first,
      currentSelection: before.length > 1 ? before[1] : null,
      currentValidation: before.length > 2 ? before[2] : before.last,
      tunedTraining: after.first,
      tunedSelection: after.length > 1 ? after[1] : null,
      tunedValidation: after.length > 2 ? after[2] : after.last,
      bestProfitCandidate: bookmark(profitOrder.first),
      bestWinRateCandidate: winOrder.isEmpty ? null : bookmark(winOrder.first),
      individuals: ranked,
      championId: champion['id'] as String,
      populationState: {
        'seed': seed,
        'serial': serial,
        'generation': generation,
        'championId': champion['id'],
        'members': [
          for (final m in ranked)
            {
              for (final e in m.entries)
                if (e.key != 'account') e.key: e.value,
            },
        ],
      },
    );
  }

  static double _number(Map p, String key) => (p[key] as num?)?.toDouble() ?? 0;

  /// Win rate amplifies profitable returns; it cannot reward a losing strategy.
  static double fitness(Map p) {
    final result = _number(p, 'returnPercent');
    return result * (result > 0 ? 1 + _number(p, 'winRatePercent') / 100 : 1);
  }

  static bool _dominates(Map candidate, Map incumbent, {required bool strict}) {
    final profit =
        _number(candidate, 'netProfit') - _number(incumbent, 'netProfit');
    final win =
        _number(candidate, 'winRatePercent') -
        _number(incumbent, 'winRatePercent');
    return profit >= -1e-9 &&
        win >= -1e-9 &&
        (!strict || profit > 1e-9 || win > 1e-9);
  }

  static int _rank(Map a, Map b) {
    var cmp = (b['fitness'] as num).compareTo(a['fitness'] as num);
    if (cmp == 0) {
      cmp = _number(
        b['performance'] as Map,
        'netProfit',
      ).compareTo(_number(a['performance'] as Map, 'netProfit'));
    }
    return cmp == 0 ? (a['id'] as String).compareTo(b['id'] as String) : cmp;
  }

  static String _key(Map<String, double> p) =>
      p.entries.map((e) => '${e.key}:${e.value}').join('|');
  static bool _discrete(StrategyParameter p) =>
      const {'bars', 'minutes', 'flag', 'mode', 'integer'}.contains(p.unit);
  static double _bound(StrategyParameter p, double value) {
    var result = value.clamp(p.minimum, p.maximum).toDouble();
    if (_discrete(p)) {
      result = result.roundToDouble().clamp(p.minimum, p.maximum).toDouble();
    }
    return double.parse(result.toStringAsPrecision(10));
  }

  static bool _consistent(Map<String, double> p) {
    for (final pair in [
      ('fastPeriod', 'slowPeriod'),
      ('fastPeriod', 'trendPeriod'),
      ('exitLookback', 'lookback'),
      ('exitProbability', 'entryProbability'),
    ]) {
      if (p.containsKey(pair.$1) &&
          p.containsKey(pair.$2) &&
          p[pair.$1]! >= p[pair.$2]!) {
        return false;
      }
    }
    return true;
  }
}
