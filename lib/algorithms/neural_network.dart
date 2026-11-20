/// Model metadata; algorithms/pinned_model.dart evaluates per-run pinned weights.
library;

import '../strategy_api.dart';
import 'helpers.dart';

class NeuralNetworkStrategy extends BuiltinStrategy {
  NeuralNetworkStrategy()
    : super(
        id: 'neural_network',
        name: 'Neural network',
        description:
            'Use a pinned trained model; unavailable models wait without trading.',
        warmupBars: 2,
        parameters: [
          strategyParameter('entryProbability', 'probability', .6, .5, .99),
          strategyParameter('exitProbability', 'probability', .45, .01, .5),
        ],
        rule: (_) => const StrategySignal(
          TradeAction.wait,
          'No pinned trained model is available.',
        ),
      );
}
