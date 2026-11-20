# Add an algorithm

1. Copy `strategy_template.json` or `strategy_template.dart` and give it a new
   ID and readable name. Edit its logic, or give the file to GPT with the prompt
   below.
2. Open **Simulation controls** and choose **Add algorithm from file** under
   **Strategy instances**. Select your `.json` or `.dart` file.
3. Wait for validation (and compilation for Dart). The app adds it to an editable
   setup automatically. For an existing simulation with saved results, create a
   new simulation and choose the import under **Add strategy instance**.

Imported algorithms remain available after reopening the app/backend. Their
source, metadata, and tunable parameters are saved and included in the single
JSON data export. Evolution workers load the same definitions. Algorithm IDs
are immutable: an edited version needs a new ID so existing simulations retain
their original code. Import rejects duplicate IDs, including built-in IDs.
Files must be UTF-8 and at most 1 MB.

| File | Support |
|---|---|
| `strategy_template.json` | Importable math and rules strategy |
| `strategy_template.dart` | Importable native Dart strategy |
| `llm_strategy_template.json` | Future direct LLM design; not importable |
| `StrategyTemplate.java` | Reference example; Java import is not supported |

## The example

The JSON and Dart examples calculate the mean of the latest `lookback` closed
candles, including the current close. Buy when flat and `close / average - 1`
exceeds `entryThreshold`, with a stop at `close * (1 - stopFraction)`. Exit a long
when the close falls below its average. Otherwise wait. They illustrate an
interface and do not assert profitability.

| Variable | Default | Range | Meaning |
|---|---|---|---|
| `lookback` | 20 | 2–200 | Closed candles, rounded to an integer |
| `entryThreshold` | 0.005 | 0–0.1 | Required distance above the average; 0.005 = 0.5% |
| `stopFraction` | 0.02 | 0.001–0.1 | Protective stop distance; 0.02 = 2% |

Expose numbers you want evolution to change in the parameter definitions, then
read the supplied parameter values during evaluation. Keep defaults within their
declared ranges. Use `warmupBars` large enough for the maximum lookback.
Algorithms with no parameters can still replay, but have nothing to mutate.

## Give a template to GPT

Attach your chosen file and this guide, then use:

> Modify this A-Trader algorithm into: [describe my strategy]. Return the
> complete single file for in-app import. Use a unique lowercase ID containing
> letters, numbers, and underscores, and give it a readable name. Preserve the
> interface and metadata format. Expose tunable numbers with defaults, minimums,
> maximums, and units. Use only supplied completed candles and position data.
> Return buy, sell, or wait with a reason; the simulator handles orders, fills,
> sizing, cash, and risk. Keep portfolios and tuning candidates independent.
> For JSON, use only the documented expressions and indicators. For Dart,
> implement TradingStrategy or extend BuiltinStrategy, with a no-argument
> constructor and no third-party dependencies.

## JSON expressions

Use `format: "atrader.algorithm"`, `version: 1`, and `kind: "rules"`. The earlier
`atrader.algorithm.draft` format marker is also accepted for rules templates.
The template shows the complete required metadata. `intervalMinutes`, if
provided, must be 1. Rules run on the candles supplied by the simulator;
historical evolution uses 1-minute bars.

- Arithmetic: `+ - * / %`; comparisons: `> < >= <= == !=`.
- Logic: `&& || !`, parentheses, `true`, `false`, and `null`.
- Candle values: `open high low close volume`; `close[1]` means the previous
  closed candle. Negative/future offsets are rejected at evaluation.
- Context: `hasPosition`, `positionSide` (`'long'` or `'short'`), `entryPrice`,
  `positionStop`, `barsHeld`, `intervalMinutes`, `sessionElapsedMinutes`, and
  `sessionLengthMinutes`. Missing position/session fields are null.
- Parameters by their names. Set `round: true` for integer parameters, with
  integer defaults and bounds. All supplied values are clamped to their ranges.
- Calculations by their names, evaluated in declaration order. Define each
  calculation before using it in another calculation.
- Indicators: `sma(close, period)`, `ema(close, period)`, `sum(close, period)`,
  `std(close, period)`, `lowest(low, period)`, `highest(high, period)`,
  `rsi(close, period)`, and `atr(period)`. A series argument must be one of the
  five candle values. Periods must be integers from 1 to 10000.
- Math functions: `abs(x)`, `min(a,b)`, `max(a,b)`, `round(x)`, `floor(x)`,
  `ceil(x)`, `sqrt(x)`, `pow(a,b)`, and `clamp(x,min,max)`.

Indicators include the current closed candle. `std` is population standard
deviation. EMA seeds from the oldest value in its requested window. RSI uses
simple gains/losses over the window (not Wilder smoothing); a flat window gives
50. ATR averages true ranges over the window. RSI and ATR need one additional
prior close. These definitions matter when matching indicators from other apps.

Each rule has `when`, `action`, `reason`, `side`, and `positionEffect`. Trade
signals need `open` or `close`; buy opens a long or closes a short, while sell
opens a short or closes a long. Optional stop/target expressions must yield
positive finite prices. The first eligible matching rule wins. Existing
positions cannot be opened again and exits must match the held side. The
fallback action is `wait`. Numeric calculations appear in decision measurements.

Expressions are parsed and checked at import. Unknown variables/functions,
invalid arity, inconsistent actions/sides, and malformed definitions produce
readable import errors. Insufficient history or invalid/nonfinite runtime
calculations produce WAIT with a reason. This is a bounded expression language;
it does not execute Dart code, make HTTP requests, or evaluate prompts.

## Dart

Implement `TradingStrategy` from `package:atrader/strategy_api.dart`, or extend
`BuiltinStrategy`. Define exactly one strategy class with a no-argument
constructor. `evaluate(StrategyContext context)` returns a `StrategySignal`.
The supplied context contains completed OHLCV candles, watchlist history,
position details, tunable parameters, session information, and portfolio label.

The importer compiles the file once using the Dart SDK installed on the backend
computer. Your Flutter installation already contains Dart. If it cannot be
found, put Flutter's `bin` folder on PATH or set `DART_SDK` / `FLUTTER_ROOT`,
then restart the backend. Keep the `algorithm_sdk` folder beside a bundled
Windows backend. Cached compiled imports can run without recompilation.

The supplied SDK includes `strategy_api.dart`, the simulator and calendar,
training types, and the built-in algorithm/helper files. Standard Dart libraries
are available; importing extra third-party packages or sibling user files is
not currently supported. Existing rule files from `lib/algorithms` can also be
used after changing their class/name/ID to avoid duplicates.

Dart code executes locally in a persistent worker process. Each simulator
engine/portfolio gets its own strategy object. Avoid mutable global/static
state, which is shared within that worker. Derive decisions from context for
reproducible training and resume; arbitrary object fields are not checkpointed.
A decision exceeding five seconds stops its worker and records WAIT. Runtime
errors also produce WAIT. Compilation errors are displayed in the app.

Native calls copy context to a worker, so JSON or built-in strategies generally
have lower evaluation overhead. The synchronous Dart interface is designed for
calculations; the existing LM Studio feature continues to handle asynchronous
model selection separately.

## LLM and Java reference templates

The direct LLM JSON and Java templates remain design references. They cannot be
selected as runnable imports. For local model decisions today, use the existing
LM Studio strategy selector in simulation setup.
