import 'package:atrader/algorithms/benchmarks.dart';
import 'package:atrader/algorithms/ma_crossover.dart';
import 'package:atrader/algorithms/registry.dart';
import 'package:atrader/simulator.dart' as compatibility;
import 'package:atrader/strategy_api.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('single-file catalogue retains all saved strategy identifiers', () {
    final ids = StrategyRegistry.all.map((strategy) => strategy.id).toList();
    expect(ids.toSet(), hasLength(ids.length));
    expect(
      ids,
      containsAll([
        'inverse_fair_value_gap',
        'neural_network',
        'logistic_regression',
        'fibonacci',
        'opening_range',
        'trend_pullback',
        'ma_crossover',
        'bollinger_reversion',
        'vwap_reclaim',
        'donchian',
        'volatility_squeeze',
        'gap_continuation',
        'support_bounce',
        'first_half_hour',
        'relative_strength',
        'rule_selector',
        'donchian_breakdown_short',
        'vwap_rejection_short',
        'opening_range_breakdown_short',
        'ma_crossover_long_short',
        'bollinger_reversion_long_short',
        'momentum_long_short',
        'lm_selector',
      ]),
    );
    for (final strategy in StrategyRegistry.all) {
      expect(strategy.name, isNotEmpty, reason: strategy.id);
      expect(strategy.description, isNotEmpty, reason: strategy.id);
      expect(strategy.warmupBars, greaterThan(0), reason: strategy.id);
      final keys = strategy.parameters.map((parameter) => parameter.name);
      expect(keys.toSet(), hasLength(keys.length), reason: strategy.id);
      for (final parameter in strategy.parameters) {
        expect(parameter.defaultValue.isFinite, isTrue);
        expect(parameter.minimum.isFinite, isTrue);
        expect(parameter.maximum.isFinite, isTrue);
        expect(
          parameter.defaultValue,
          inInclusiveRange(parameter.minimum, parameter.maximum),
          reason: '${strategy.id}.${parameter.name}',
        );
      }
    }
  });

  test('native files and legacy simulator exports share the same contract', () {
    final TradingStrategy strategy = StrategyRegistry.byId('ma_crossover');
    expect(strategy, isA<MaCrossoverStrategy>());
    expect(compatibility.StrategyRegistry.byId(strategy.id), same(strategy));
    expect(
      const StrategySignal(TradeAction.wait, 'example'),
      isA<compatibility.StrategySignal>(),
    );
  });

  test('benchmark files preserve cash allocation and pending-order rules', () {
    final hold = BenchmarkAlgorithms.byLabel('Buy & Hold');
    final equal = BenchmarkAlgorithms.byLabel('Equal Weight');
    double allocation(String label, int positions, bool pending, bool quoted) =>
        BenchmarkAlgorithms.byLabel(label).allocation(
          cash: 900,
          watchlistLength: 3,
          positionCount: positions,
          hasPendingOrders: pending,
          quoteDrivenExecution: quoted,
        );

    expect(allocation(hold.label, 0, false, true), 900);
    expect(allocation(hold.label, 0, true, true), 0);
    expect(allocation(hold.label, 0, true, false), 900);
    expect(allocation(hold.label, 1, false, false), 0);
    expect(allocation(equal.label, 0, false, true), 300);
    expect(allocation(equal.label, 1, true, true), 450);
    expect(allocation(equal.label, 2, false, false), 900);
    expect(hold.initializationReason, 'Buy-and-hold benchmark initialized.');
    expect(equal.initializationReason, isNull);
  });
}
