import 'benchmark_api.dart';
import 'buy_and_hold.dart';
import 'equal_weight.dart';

/// Benchmarks use allocation policies; the simulator owns orders and accounting.
class BenchmarkAlgorithms {
  BenchmarkAlgorithms._();

  static const List<BenchmarkAlgorithm> all = [
    BuyAndHoldAlgorithm(),
    EqualWeightAlgorithm(),
  ];

  static BenchmarkAlgorithm byLabel(String label) =>
      all.firstWhere((algorithm) => algorithm.label == label);
}
