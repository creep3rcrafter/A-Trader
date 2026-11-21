import 'dart:convert';

import 'package:atrader/simulator.dart';
import 'package:atrader/strategy_evolution.dart';
import 'package:atrader/strategy_tuning.dart';
import 'package:flutter_test/flutter_test.dart';

class _Genes implements TradingStrategy {
  @override
  String get id => 'evolution_fixture';
  @override
  String get name => 'Evolution fixture';
  @override
  String get description => '';
  @override
  int get warmupBars => 1;
  @override
  List<StrategyParameter> get parameters => const [
    StrategyParameter(
      name: 'x',
      unit: 'number',
      defaultValue: 0,
      minimum: -100,
      maximum: 100,
    ),
    StrategyParameter(
      name: 'y',
      unit: 'number',
      defaultValue: 0,
      minimum: -100,
      maximum: 100,
    ),
    StrategyParameter(
      name: 'lookback',
      unit: 'bars',
      defaultValue: 10,
      minimum: 1,
      maximum: 20,
    ),
  ];
  @override
  StrategySignal evaluate(StrategyContext context) =>
      const StrategySignal(TradeAction.wait, 'fixture');
}

// A repeatable fitness landscape isolates breeding from market randomness.
class _Landscape extends StrategyTuner {
  _Landscape({super.evolution})
    : super(
        candlesByInterval: const {},
        watchlist: const ['SOXL'],
        strategies: [
          StrategySettings(strategyId: 'evolution_fixture', label: 'Genes'),
        ],
        seed: 77,
      );
  @override
  List<PopulationEvaluation> evaluatePopulation(
    StrategySettings settings,
    List<Map<String, double>> candidates, {
    void Function(int)? onWork,
  }) => [for (final p in candidates) _evaluate(p)];
  PopulationEvaluation _evaluate(Map<String, double> p) {
    final distance =
        (p['x']! - 5) * (p['x']! - 5) + (p['y']! - 8) * (p['y']! - 8);
    final profit = 100 - distance;
    final performance = <String, Object?>{
      'netProfit': profit,
      'returnPercent': profit / 100,
      'winRatePercent': 50 + profit.clamp(-49, 49),
      'closedTrades': 10,
    };
    return (
      scores: [
        SegmentScore(
          returnPercent: profit / 100,
          maxDrawdownPercent: 0,
          trades: 10,
        ),
      ],
      performance: performance,
      account: {
        'history': <Object?>[],
        'closedPnl': [profit],
      },
    );
  }
}

void main() {
  setUp(() => StrategyRegistry.all.add(_Genes()));
  tearDown(
    () => StrategyRegistry.all.removeWhere((s) => s.id == 'evolution_fixture'),
  );

  test(
    'champion survives exploration, bounded populations breed and resume exactly',
    () {
      final tuner = _Landscape(
        evolution: const EvolutionSettings(candidatesPerGeneration: 24),
      );
      Map<String, Map<String, dynamic>> state = {};
      var priorProfit = double.negativeInfinity;
      var priorWin = double.negativeInfinity;
      String? priorChampion;
      Map? priorGenes;
      for (var generation = 1; generation <= 8; generation++) {
        final result = StrategyEvolution(
          tuner: tuner,
          generation: generation,
          populations: state,
        ).run().single;
        expect(result.individuals, hasLength(24));
        expect(result.individuals.map((m) => m['id']).toSet(), hasLength(24));
        final champion = result.individuals.singleWhere(
          (m) => m['champion'] == true,
        );
        final performance = champion['performance'] as Map;
        expect(performance['netProfit'], greaterThanOrEqualTo(priorProfit));
        expect(performance['winRatePercent'], greaterThanOrEqualTo(priorWin));
        if (priorChampion != null) {
          final elite = result.individuals.singleWhere(
            (m) => m['id'] == priorChampion,
          );
          expect(elite['parameters'], priorGenes);
          expect(elite['mutationAmount'], 0);
          expect(elite['elite'], true);
          expect(
            result.individuals.any((m) => (m['parents'] as List).length == 2),
            true,
          );
        }
        for (final m in result.individuals) {
          final p = m['parameters'] as Map;
          expect(p['x'], inInclusiveRange(-100, 100));
          expect(p['lookback'], inInclusiveRange(1, 20));
          expect(p['lookback'], (p['lookback'] as double).roundToDouble());
        }
        priorProfit = (performance['netProfit'] as num).toDouble();
        priorWin = (performance['winRatePercent'] as num).toDouble();
        priorChampion = champion['id'] as String;
        priorGenes = champion['parameters'] as Map;
        state = {'Genes': Map<String, dynamic>.from(result.populationState!)};
      }
      final reloaded = (jsonDecode(jsonEncode(state)) as Map).map(
        (k, v) => MapEntry(k as String, Map<String, dynamic>.from(v as Map)),
      );
      final expected = StrategyEvolution(
        tuner: tuner,
        generation: 9,
        populations: state,
      ).run().single;
      final actual = StrategyEvolution(
        tuner: tuner,
        generation: 9,
        populations: reloaded,
      ).run().single;
      expect(actual.toJson(), expected.toJson());
      expect(actual.populationState, expected.populationState);
      expect(
        actual.populationState!['members'].toString(),
        isNot(contains('account')),
      );
    },
  );

  test(
    'crossover combines both parents and solidified winners mutate less',
    () {
      final state = <String, Map<String, dynamic>>{
        'Genes': {
          'seed': 4,
          'serial': 2,
          'championId': 'I000001',
          'members': [
            {
              'id': 'I000001',
              'birthGeneration': 1,
              'parameters': {'x': -50.0, 'y': -50.0, 'lookback': 10.0},
              'parents': <String>[],
              'fitness': 2.0,
              'performance': {'netProfit': 100.0},
              'solidification': 1.0,
            },
            {
              'id': 'I000002',
              'birthGeneration': 1,
              'parameters': {'x': 50.0, 'y': 50.0, 'lookback': 10.0},
              'parents': <String>[],
              'fitness': 1.0,
              'performance': {'netProfit': 50.0},
              'solidification': 0.0,
            },
          ],
        },
      };
      final settings = const EvolutionSettings(
        candidatesPerGeneration: 80,
        crossoverProbability: 1,
        parentFraction: 1,
        eliteFraction: .01,
        mutationAmount: .01,
        minimumMutationAmount: 0,
        additionalMutationProbability: 0,
      );
      final result = StrategyEvolution(
        tuner: _Landscape(evolution: settings),
        generation: 2,
        populations: state,
      ).run().single;
      final children = result.individuals
          .where((m) => m['elite'] != true)
          .toList();
      expect(children.every((m) => (m['parents'] as List).length == 2), true);
      expect(
        children.any((m) {
          final p = m['parameters'] as Map;
          return (p['x'] as num) * (p['y'] as num) < 0;
        }),
        true,
      );
      final strong = children
          .where((m) => (m['parents'] as List).first == 'I000001')
          .first;
      final weak = children
          .where((m) => (m['parents'] as List).first == 'I000002')
          .first;
      expect(
        strong['mutationAmount'] as num,
        lessThan(weak['mutationAmount'] as num),
      );
    },
  );

  test(
    'win rate amplifies profit without rewarding losses; settings reject invalid floors',
    () {
      expect(
        StrategyEvolution.fitness({'returnPercent': -5, 'winRatePercent': 100}),
        -5,
      );
      expect(
        StrategyEvolution.fitness({'returnPercent': 5, 'winRatePercent': 80}),
        greaterThan(
          StrategyEvolution.fitness({'returnPercent': 5, 'winRatePercent': 40}),
        ),
      );
      expect(
        () => EvolutionSettings.fromJson({
          'mutationAmount': .1,
          'minimumMutationAmount': .2,
        }),
        throwsArgumentError,
      );
      expect(
        EvolutionSettings.fromJson({'populationSize': 30}).populationSize,
        30,
      );
    },
  );
}
