/// Shared catalogue used by the dashboard, backend, and tuning isolates.
library;

import '../strategy_api.dart';
import 'inverse_fair_value_gap.dart';
import 'neural_network.dart';
import 'logistic_regression.dart';
import 'fibonacci.dart';
import 'opening_range.dart';
import 'trend_pullback.dart';
import 'ma_crossover.dart';
import 'bollinger_reversion.dart';
import 'vwap_reclaim.dart';
import 'donchian.dart';
import 'volatility_squeeze.dart';
import 'gap_continuation.dart';
import 'support_bounce.dart';
import 'first_half_hour.dart';
import 'relative_strength.dart';
import 'rule_selector.dart';
import 'donchian_breakdown_short.dart';
import 'vwap_rejection_short.dart';
import 'opening_range_breakdown_short.dart';
import 'ma_crossover_long_short.dart';
import 'bollinger_reversion_long_short.dart';
import 'momentum_long_short.dart';
import 'lm_selector.dart';

class StrategyRegistry {
  StrategyRegistry._();

  static final List<TradingStrategy> all = [
    InverseFairValueGapStrategy(),
    NeuralNetworkStrategy(),
    LogisticRegressionStrategy(),
    FibonacciStrategy(),
    OpeningRangeStrategy(),
    TrendPullbackStrategy(),
    MaCrossoverStrategy(),
    BollingerReversionStrategy(),
    VwapReclaimStrategy(),
    DonchianStrategy(),
    VolatilitySqueezeStrategy(),
    GapContinuationStrategy(),
    SupportBounceStrategy(),
    FirstHalfHourStrategy(),
    RelativeStrengthStrategy(),
    RuleSelectorStrategy(),
    DonchianBreakdownShortStrategy(),
    VwapRejectionShortStrategy(),
    OpeningRangeBreakdownShortStrategy(),
    MaCrossoverLongShortStrategy(),
    BollingerReversionLongShortStrategy(),
    MomentumLongShortStrategy(),
    LmSelectorDefinition(),
  ];

  static TradingStrategy byId(String id) =>
      all.firstWhere((strategy) => strategy.id == id);

  static final Set<String> builtinIds = all
      .map((strategy) => strategy.id)
      .toSet();

  static void replaceImported(Iterable<TradingStrategy> strategies) {
    // Capture built-in IDs before changing the catalogue for the first time.
    final reserved = builtinIds;
    final imported = strategies.toList();
    final ids = <String>{...reserved};
    for (final strategy in imported) {
      if (!ids.add(strategy.id)) {
        throw ArgumentError(
          'Algorithm id ${strategy.id} already exists. Use a unique id.',
        );
      }
    }
    all.removeWhere((strategy) => !reserved.contains(strategy.id));
    all.addAll(imported);
  }
}
