import 'benchmark_api.dart';

/// Allocate the available cash to the first eligible symbol, then hold it.
class BuyAndHoldAlgorithm implements BenchmarkAlgorithm {
  const BuyAndHoldAlgorithm();

  @override
  String get id => 'buy_and_hold';
  @override
  String get label => 'Buy & Hold';
  @override
  String get description =>
      'Invest in the first eligible watchlist symbol and hold the position.';
  @override
  String get initializationReason => 'Buy-and-hold benchmark initialized.';

  @override
  double allocation({
    required double cash,
    required int watchlistLength,
    required int positionCount,
    required bool hasPendingOrders,
    required bool quoteDrivenExecution,
  }) => positionCount > 0 || (quoteDrivenExecution && hasPendingOrders)
      ? 0
      : cash;
}
