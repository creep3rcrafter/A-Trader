import 'dart:math' as math;

import 'benchmark_api.dart';

/// Divide remaining cash across watchlist symbols that do not yet have a position.
class EqualWeightAlgorithm implements BenchmarkAlgorithm {
  const EqualWeightAlgorithm();

  @override
  String get id => 'equal_weight';
  @override
  String get label => 'Equal Weight';
  @override
  String get description =>
      'Allocate equal initial cash shares across eligible watchlist symbols.';
  @override
  String? get initializationReason => null;

  @override
  double allocation({
    required double cash,
    required int watchlistLength,
    required int positionCount,
    required bool hasPendingOrders,
    required bool quoteDrivenExecution,
  }) => cash / math.max(1, watchlistLength - positionCount);
}
