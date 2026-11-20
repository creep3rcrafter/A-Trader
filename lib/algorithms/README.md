# Algorithms

Each registered algorithm now has a Dart file containing its ID, description,
warm-up, parameter definitions, and decision logic. These files implement the
same native `TradingStrategy` contract as the Dart starter template.

`registry.dart` lists the 23 strategy instances used by the dashboard, backend,
LM strategy selection, and evolution isolates. The original IDs, order,
parameter keys/ranges/defaults, and decision behavior are preserved, so existing
saved simulations and training can continue resolving their algorithms.

## Make your own

For personal algorithms, copy
[`strategy_template.json`](../../templates/algorithms/strategy_template.json) or
[`strategy_template.dart`](../../templates/algorithms/strategy_template.dart),
edit its unique ID/name and decision logic, then select **Simulation controls >
Add algorithm from file**. JSON and Dart algorithms become available immediately
and are saved with the application. Their source and metadata are included in
the single JSON data export. No registry edit or restart is required.

To add a built-in algorithm in the application source instead:

1. Copy an existing rule file or
   [`strategy_template.dart`](../../templates/algorithms/strategy_template.dart)
   into this folder with a new filename.
2. Give its class, `id`, and name unique values. Edit its parameters and evaluator.
3. Add its import and an instance to `StrategyRegistry.all` in `registry.dart`.
4. Restart the backend and the dashboard to see it in simulation setup.

For example, after copying the starter into `my_strategy.dart` and changing its
class to `MyStrategy`, add:

```dart
import 'my_strategy.dart';
// Inside StrategyRegistry.all:
const MyStrategy(),
```

Keep the template's `package:atrader/strategy_api.dart` import. An existing file
may use a relative import of that same contract and `helpers.dart`. The
`BuiltinStrategy` base class accepts metadata, parameters, and a `rule` callback;
it converts insufficient-history range/state errors into WAIT decisions. The
starter implements `TradingStrategy` directly and checks history explicitly.
Both styles work with simulation and parameter evolution.

Source registration is optional for built-ins. The in-app importer supports
JSON rules and native Dart files. Java and the direct LLM JSON design remain
unsupported.

## Files

| File | Algorithm |
|---|---|
| `inverse_fair_value_gap.dart` | Inverse fair value gap |
| `fibonacci.dart` | Fibonacci retracement |
| `opening_range.dart` | Opening-range breakout |
| `trend_pullback.dart` | Trend pullback |
| `ma_crossover.dart` | Moving-average crossover |
| `bollinger_reversion.dart` | Bollinger mean reversion |
| `vwap_reclaim.dart` | VWAP reclaim |
| `donchian.dart` | Donchian channel breakout |
| `volatility_squeeze.dart` | Volatility squeeze |
| `gap_continuation.dart` | Gap-up continuation |
| `support_bounce.dart` | Support bounce |
| `first_half_hour.dart` | First-half-hour strategy |
| `relative_strength.dart` | Relative-strength rotation |
| `rule_selector.dart` | Rule-based selector |
| `donchian_breakdown_short.dart` | Donchian breakdown short |
| `vwap_rejection_short.dart` | VWAP rejection short |
| `opening_range_breakdown_short.dart` | Opening-range breakdown short |
| `ma_crossover_long_short.dart` | Moving-average crossover long/short |
| `bollinger_reversion_long_short.dart` | Bollinger reversion long/short |
| `momentum_long_short.dart` | Momentum long/short |
| `neural_network.dart` | Neural network definition |
| `logistic_regression.dart` | Logistic regression definition |
| `lm_selector.dart` | LM Studio definition, selections, and decision adapter |
| `buy_and_hold.dart` | Buy & Hold allocation policy |
| `equal_weight.dart` | Equal Weight allocation policy |

Neural network and logistic regression share `pinned_model.dart` for inference
against a run's saved model weights, and `model_features.dart` for the exact
features used in training. Their definitions still WAIT without a pinned model.
The LM selector keeps its synchronous decision adapter here; HTTP requests and
model discovery stay in `lm_studio.dart` and the backend.

Benchmarks use the small `BenchmarkAlgorithm` allocation contract rather than
the signal interface: they allocate portfolio cash and hold positions. Their
files contain the allocation policies, while the simulator continues to own
fees, order timing, fills, and accounting. Their existing enable switches and
saved configuration remain in place; they are not parameter-tuned strategies.

## Shared contract and helpers

- `../strategy_api.dart`: candles, contexts, parameters, signals, and strategy
  interfaces. It has no registry or simulator-engine dependency.
- `helpers.dart`: shared indicators, session grouping, and long/short signal
  builders. Keep private strategy-specific logic in the strategy's own file.
- `registry.dart`: explicit native registration, constructed identically in
  every tuning isolate. No runtime filesystem scanning is required.
- `benchmarks.dart` / `benchmark_api.dart`: benchmark catalogue and allocation
  contract.
- `algorithm_library.dart`: import, duplicate-ID checks, saved definitions,
  runtime registration, and per-isolate worker ownership.
- `json_algorithm.dart`: validated expressions, indicators, and rule evaluation.
- `native_algorithm.dart`: Dart compilation, persistent local workers, bounded
  decision requests, and context/signal messages. Worker instances are scoped
  by simulator engine and portfolio so tuning candidates do not share objects.
- `imported_definition.dart`: portable metadata used by the dashboard.

Existing imports of the public types from `simulator.dart`, model inference from
`live_training.dart`, and LM selection from `lm_studio.dart` continue to work
through compatibility exports.
