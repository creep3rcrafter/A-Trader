/// Allocation contract for benchmark portfolios managed by the simulator.
library;

abstract interface class BenchmarkAlgorithm {
  String get id;
  String get label;
  String get description;
  String? get initializationReason;

  double allocation({
    required double cash,
    required int watchlistLength,
    required int positionCount,
    required bool hasPendingOrders,
    required bool quoteDrivenExecution,
  });
}
