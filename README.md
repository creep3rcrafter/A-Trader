# A-Trader Live Simulator

A Flutter dashboard backed by a standalone Dart service. The Schwab integration
provides the intended live market-data source; every order is simulated locally
and no brokerage order is sent.
The backend runs separately so closing the Flutter window does not stop a run.
Dashboard and dialog text can be highlighted and copied with Ctrl+C or the
selection menu. Error messages also offer **Copy error**, including training
failures, backend notices, import dialogs, and export error notifications.

Use **Simulation controls > Strategy instances > Add algorithm from file** to
import a `.json` rules file or `.dart` algorithm. The app validates it, saves it,
and makes it available in simulation setup and evolution without source edits or
a restart. Starter files and a GPT prompt are in
[templates/algorithms](templates/algorithms/README.md). JSON math/rules run
directly. Dart imports use your installed Dart SDK to compile a persistent local
worker; the Windows bundle includes its source SDK in `algorithm_sdk`, which
must stay beside the backend executable. Java and direct LLM JSON imports are
not supported.
The current algorithms live in individual Dart files under
[lib/algorithms](lib/algorithms/README.md), with a shared catalogue for simulation
and evolution.

**Saved candle data:** the backend retains regular-session 1-minute candles in
`%LOCALAPPDATA%\ATrader\candles\1m\<symbol>\YYYY-MM-DD.json.gz`. Simulations
share this cache and download only missing days. **Download / reuse candle data**
in Simulation controls can preload the selected watchlist/date range. Completed
cached days work offline; the current day stays refreshable. While the backend
is running and Schwab is authorized, it checks every five minutes for completed
sessions, collects them after a 15-minute closing buffer, and catches up recent
missing days. Initial collection covers roughly the last four weeks where data
is available. Saved days are retained beyond the provider's download window;
no automatic collection happens while the backend is closed.

Completed generation/session replays are stored once as compressed files in
`%LOCALAPPDATA%\ATrader\state-archives`. `state.json` references these files;
keep that folder with the checkpoint when backing up application data. The app
restores them automatically, and **Export all run data** still produces one
complete JSON file including those generations. Historical jobs checkpoint at
generation boundaries instead of repeatedly rewriting all results while tuning.

## Requirements

- Flutter and Dart from the Flutter SDK for building or development
  (`flutter doctor` should be clean). A bundled Windows release does not need
  Dart installed separately.
- Windows for the current DPAPI-protected credential store.
- A Schwab developer application with API access. Schwab's portal calls the
  App Key the **Client ID** and the App Secret the **Client Secret**. The app
  must include both the **Market Data Production** and **Accounts and Trading
  Production** API products: Schwab returns the streaming login details only
  from the Accounts and Trading API, and rejects it with "Client not
  authorized" otherwise. The simulator never places orders. Register
  the Callback URL `https://127.0.0.1:8766/oauth/schwab/callback` (the app's
  default); any other loopback URL also works if Settings uses the exact same
  value.
- Optional: a running LM Studio server for model discovery and tool-calling
  checks. The simulator has no paid-model fallback.

Schwab API access, callback registration, streaming entitlements, and retention
terms depend on the account and developer application. Verify them in Schwab's
official developer portal before using live data. The application cannot
confirm those account-specific terms on your behalf.

## Windows app

Build and open the desktop app:

```powershell
flutter build windows
.\build\windows\x64\runner\Release\atrader.exe
```

Click **Start backend** in the offline banner, or open **Settings > Local
backend > Start backend**. The app starts the bundled `atrader_backend.exe`
without a terminal, waits for its health endpoint, and refreshes the dashboard.
It reuses an already-running compatible backend rather than starting another.
Starting the backend does not create a new simulation. A saved active run
follows the existing automatic recovery and Schwab reconnection flow.

Keep the entire Release folder together when moving or distributing the app,
including `atrader_backend.exe`. `flutter run -d windows` also builds and
bundles the service for development.

The backend keeps running when the app window closes. Use **Run setup > Stop**
to stop a simulation before exiting if you do not want it to continue.
Use the app-bar **Export all run data** button to create one timestamped
JSON file in `%USERPROFILE%\Downloads`. It includes all saved simulations and
in-memory historical runs, candles, portfolio equity history, decisions,
positions, pending orders, closed-trade P&L, training state, and pinned models.
The running backend also exports each completed generation retained for the
latest evolution session, including its replay, tuning results, and performance.

The `performance` section identifies each portfolio by simulation, label, and
interval. It includes net profit, return, realized and unrealized P&L, closed
trades, wins, losses, breakeven trades, win rate, profit factor, average and
best/worst trade P&L, and maximum drawdown. Metric definitions appear in the
file. Win rate is null when no trades have closed. Profit factor is null when
there are no losing trades.

Export reads the running backend when connected. Offline export uses the newest
complete saved checkpoint and identifies that source in the file. Historical results, training sessions, and completed generation replays are
saved with their simulation and remain available after a backend restart. Raw live quotes and detailed
event logs for every parameter-search candidate are not retained.

If startup fails, the app displays the error; background startup diagnostics
are written to `%LOCALAPPDATA%\ATrader\backend-startup.log`. Port 8787 must not
be occupied by another service or an older, incompatible backend. The local
service starts independently of credential loading; if saved credentials cannot
be decrypted, the dashboard stays available, reports the problem in Settings,
and lets you enter replacement credentials.

## Web or terminal startup

From the repository root, open two PowerShell terminals.

Terminal 1 — start the backend and leave it running:

```powershell
dart run bin\server.dart
```

Terminal 2 — start the Flutter Web dashboard:

```powershell
flutter run -d chrome
```

The dashboard uses `http://127.0.0.1:8787`. A browser cannot start a local
process; use the Windows app or the separate terminal above to start the
backend.

## Connect and start a live simulation

1. In **Settings**, enter the Schwab **Client ID (App Key)**, **Client Secret
   (App Secret)**, and the exact Callback URL registered for the developer
   application (default `https://127.0.0.1:8766/oauth/schwab/callback`).
2. Select **Connect Schwab (OAuth)**. The backend saves the credentials,
   starts a temporary local HTTPS listener on the callback port, and opens
   Schwab's login page. Log in and approve access. The listener uses a
   self-signed certificate for 127.0.0.1 (created once in
   `%LOCALAPPDATA%\ATrader`), so the browser shows a certificate warning:
   choose **Advanced** and continue. If the page still does not load, copy the
   full address from the browser bar (it contains `code=`), paste it into
   **Redirected address** in Settings, and select **Finish with pasted
   address**. Codes expire quickly, so do this right away.
3. Select **Connect Schwab stream** to start streaming. The
   backend displays connection, authorization, and per-symbol quote freshness
   status.
4. Configure the watchlist, strategy instances and intervals, starting cash,
   and risk limits in **Run Setup**. Defaults are SOXL, OKLO, and SMR.
5. Start the run only after the stream reports live. A signal is not a fill:
   simulated orders fill on a later eligible live quote. Stop the run from the
   dashboard when finished.

To remove the current run's simulated portfolios, positions, pending orders,
candles, decisions, fills and chart history, stop the run and choose **Run
setup > Clear run data**, then confirm. This keeps the saved run configuration,
Schwab credentials and connection settings. Only the selected simulation is
cleared; other simulations and the shared training collection are retained.

Every enabled strategy instance and each benchmark (Buy & Hold, Equal Weight)
is a separate portfolio with its own cash, positions, orders, and fills. All
start with the same **Starting cash per portfolio**; the dashboard plots them
together on one time axis. Hover over (or drag across) the equity, drawdown,
or candle charts to see every line's value, or the candle's OHLCV and fills,
at that point. Toggle a strategy in the chart legend to show or hide its line
on both equity and drawdown charts; hidden lines are also excluded from hover.
The dashboard is a single page without separate navigation tabs. Expand
**Simulation controls** near the top to select a run or use the existing
setup, start, stop, and clear controls. Each watched ticker has its own candle
chart on the dashboard. Its interval menu lists the intervals supplied by the
backend; no missing candles are invented.

The compact line toggles sit above the graphs and use each line's color;
hidden lines have outlined, struck-through toggles. Hover over one for its
strategy description. Every portfolio receives a distinct color rather than
recycling the palette after eight lines; equity, drawdown, legend, and expanded
strategy charts share the same assignment. A dotted **Starting cash** reference
appears on the equity chart (0% in return view), including separate cash levels
when portfolios start with different amounts.
Chart hover details use a foreground overlay so later
charts cannot cover them. Readiness is green when the required bars and model are available,
and red otherwise. Numeric strategy metrics are green for positive values, red
for negative values, and yellow for zero; drawdowns display as negative losses.
Expand a **Strategy metrics** row using its arrow to see recorded return and
drawdown over time plus that portfolio's decisions. Multiple rows can stay
expanded independently, and polling preserves the expanded rows.
Near the bottom of the dashboard, **Open trades by strategy** lists current
positions with direction, shares, entry, stop, target, and Mountain entry time.
The dashboard's compact **Decision log** starts with time and shows explicit
position side, entry, stop, and target only when available, omitting empty fields
and duplicate prices. Reasoning occupies the last column to the right instead
of a footer beneath every row; narrow windows wrap the final cell as needed.
Search decisions by text or use searchable multi-select
menus for strategy, ticker, side, action, and event type. Selected values within
one menu are alternatives; different menus combine to narrow the results.
**Clear filters** restores all events. The log scrolls independently and
renders rows on demand. Model training stays hidden on the dashboard until a
validated candidate is ready; its controls remain available in Settings.
Dashboard counters separate open longs and shorts
and count completed trades together, not individual order fills. Add as many
strategy instances as needed; there is no configured limit, though practical
capacity depends on your computer.

### Independent simulations and saved data

Use the simulation picker and **New simulation** inside the dashboard's
collapsed **Simulation controls** / **Run setup** section to compare independent
runs. The main dashboard identifies the selected simulation without a separate
creation button.
Each run keeps its own configuration, cash, positions, orders, decisions,
history, and pinned model versions. Runs share one Schwab market-data
subscription and credentials. Switching the displayed run does not stop any
other run. Once a run has data, its configuration is immutable: create another
simulation rather than overwriting results. Stop and clear only when deletion
is intended.

The backend migrates earlier single-run checkpoints into **Simulation 1**.
Before the first new-format save it preserves the original checkpoint as
`%LOCALAPPDATA%\ATrader\state-before-multi-run.json`; that migration backup is
not removed by Clear run data. Unreadable state blocks saving instead of
overwriting the original. Stopped portfolios remain available after restart.
Recovered active runs retain accounting but rebuild live indicator warm-up;
saved valuations are not treated as fresh executable quotes.

Editing source files does not update an already-running backend executable.
Export first and schedule a backend update/restart when a feed interruption is
acceptable; a frontend hot reload alone cannot activate new execution rules.

### Simulated shorts, inverse gaps, and closing windows

In Run Setup, **Enable simulated short selling** permits strategies with an
explicit short-entry signal to open shorts. A SELL from an existing long-only
strategy remains an exit, never an implicit short entry. Short entry fills at
the next eligible bid; covering uses the ask, with the same slippage and
per-share fees. Entry notional is reserved from cash, short proceeds do not
increase buying power, and there is no leverage. Adverse gaps can still create
losses beyond the reserved cash. Borrow availability, recalls, and borrow
interest are not modeled.

**Inverse fair value gap** (`inverse_fair_value_gap`) supports both directions:
three closed candles first confirm a gap, a later close crosses the gap to
invert it, and a still-later retest/rejection signals entry in the opposite
direction. Gap size, expiry, stop buffer, and reward/risk are registry parameters.

Short-only strategies open shorts and cover on their own exit rules:
**Donchian breakdown short** (`donchian_breakdown_short`), **VWAP rejection
short** (`vwap_rejection_short`), and **Opening-range breakdown short**
(`opening_range_breakdown_short`). Long/short strategies choose a side from the
signal: **Moving-average crossover long/short** (`ma_crossover_long_short`),
**Bollinger reversion long/short** (`bollinger_reversion_long_short`), and
**Momentum long/short** (`momentum_long_short`). All of them need **Enable
simulated short selling**; otherwise short entries are logged as blocked risk
events and only long entries fill. Other built-in strategies and both trained
models remain long-only. New strategies need an updated backend restart.

### Historical strategy evolution

Training saves its date range, downloaded market data, population, parentage,
champion parameters, individual performance/equity/trades, completed generation
replays, and mutation settings. The app uses one simulation setup; there is no
simulation-profile picker or name/delete workflow. Changing a stopped setup
archives its previous results for export. To continue, keep
**Continue saved training** checked, enter a higher total
in **Generations**, and click **Start**. Continuation starts after the last
completed generation. Starting a fresh session keeps the earlier session
in the simulation's training archive.

Set **Population size** (2–200 variants per strategy) beside **Generations**.
Each generation preserves unchanged elites and breeds children from the strongest
parent pool using parameter crossover. **Evolution settings** exposes base mutation
size (1–200%), its minimum floor, extra-variable mutation probability, elite
percentage (1–50%), parent pool percentage (10–100%), and crossover probability.
Weaker parents receive larger mutations. When a child improves profit and win
rate together over its parents, its inherited solidification increases, reducing
subsequent mutation toward the floor. Integer parameters stay integral and all
values stay within the algorithm's declared limits.

Fitness is return × (1 + win-rate/100) for profitable individuals, and return
for losing individuals. This rewards profitable winners without rewarding losses
for having a high win rate. A separate retained champion is replaced only when
net profit and win rate are both non-decreasing and at least one improves on the
same sample. This deliberately rejects profit/win-rate tradeoffs for the champion;
other strong individuals can still breed. No closed trades means an unknown win
rate (shown as a dash), treated as zero for selection.

**Population performance** lists every individual in every saved generation:
rank, parent IDs, profit, return, win rate, trade count, drawdown, fitness,
effective mutation, and solidification. Select an individual for all performance
metrics, variables, equity/drawdown charts and fills, or copy its JSON. Use the
generation arrows and strategy selector to browse, or **Follow latest** for live
updates. These records are included in the single JSON export and restored after
a backend restart. Older sessions acquire a population when continued; earlier
generations cannot retroactively show individuals that were never recorded.

**Best saved strategy settings** bookmarks the highest observed net profit
and highest win rate for every strategy, including tested candidates.
Each bookmark shows the variables, generation, trade count, profit, and win
rate. **Use these variables** copies that strategy's recorded
variables and time range into the setup. Win rate ties use net
profit. Both records are observations of the historical window.

**Strategy variable changes** beneath the portfolio metrics follows the latest
completed generation. It shows each strategy's prior values, tested mutations,
and accepted settings. Increases have green signed differences and decreases
have red differences. Use the previous/next generation buttons to inspect saved
history, or **Follow latest** to return to automatic updates. **Show unchanged
variables** displays the rest of each parameter set.


Open **Simulation Controls**, set the date range and **Generations** (1 to 10,000),
and click **Start**. Historical mode defaults to the latest completed full
trading day, 7:30 AM to 2:00 PM Mountain Time. Each generation uses the same
selected range of 1-minute Schwab candles and starts when the previous one
completes. The backend stops after the requested number of generations.
If the window has too little data to tune, research ends early and shows why.

Each generation evaluates its population after simulated trading costs.
The dashboard automatically follows the retained champion in completed
generations and shows their candles, equity, drawdown, strategy metrics,
positions, and decisions. The generation equity chart can show either the
tested mutation or the champion accepted for each generation; it defaults to
the champion. The activity indicator shows progress while the next generation
runs. Use **Stop** to end the job. Fitness uses the full chosen training window;
chronological segment metrics are diagnostics, not an independent acceptance
holdout. Improvement on this repeated sample does not establish performance on
unseen dates.

The optional session-close policy checks each strategy portfolio's net
liquidation P&L, including estimated exit costs, on its first synchronized fresh
quotes in the last ten minutes. Positive portfolios close their positions;
losing or flat portfolios are locked to wait until the last minute, even if
they become positive meanwhile. New entries are blocked throughout that
window. Exchange holidays, DST, and early closes are respected. Benchmark
portfolios are excluded from this policy. Fills still require fresh
regular-session quotes: missing data leaves positions open rather than
inventing a close. These controls default off, including for migrated runs;
configure them before starting a new simulation.

### Live training and local-model strategies

The backend collects bounded, prospective completed 1-minute candles while at
least one live simulation runs. Forward-return labels mature only after three
later consecutive candles; disconnections and gaps invalidate pending labels.
Historical replay does not train models. The shared collection survives
restarts, but unfinished labels are invalidated.

Settings exposes automatic training (off by default), manual training,
readiness, and evaluation results. At least 100 mature examples are required.
Fitting runs in a worker isolate. Preprocessing is fitted on the training slice;
a chronological, purged later holdout and class/metric checks gate publication
of versioned neural-network and logistic-regression candidates. This is not
evidence of profitability or an independent final test.

New live runs pin available validated models. A model missing at run start
produces an explicit WAIT for that entire run; subsequent training never
silently changes an existing run. Trained strategies currently require a
1-minute decision interval and are long-only. The neural network persists and
uses its hidden-layer weights, separately from the logistic baseline.

The LM Studio strategy selector is a different strategy: it chooses eligible
registry evaluators via tool calls and preserves their risk/exit behavior.
Server failures cause that selector to WAIT without stopping deterministic
strategies. Verify Schwab's retention and model-use permissions before enabling
training or sending derived market information to LM Studio; account-specific
permission has not been verified by this project.

### Historical mode (date replay)

In **Run Setup** choose **Historical**, select **Choose dates**, then
**Start historical replay**. The backend downloads Schwab 1-minute price
history (regular session only) for the watchlist and replays it as fast as
possible through the same candle, strategy, risk, and fill code used live.
With an enabled **LM Studio strategy selector**, replay instead pauses at each
decision candle after its 22-bar warm-up. It sends only completed candles and
waits for every applicable selector's response before evaluating that candle
and delivering the next quote. There is no historical inference timeout;
**Stop** cancels pending requests. Invalid responses and server errors explicitly
record WAIT and let replay continue. Live mode remains non-blocking, with its
15-second request timeout and stale-response expiry.
The dashboard refuses LM replay on older backends instead of silently skipping
selection. Stop every simulation before updating a running backend. Historical
results are saved with the simulation; the Windows export covers
persisted runs, not these in-memory historical results.
Dates and times in the app use Mountain Time (`America/Denver`), with a
12-hour clock and the appropriate MST or MDT daylight-saving offset. Optional
**Start** and **End** time chips turn the dates into one continuous span, for
example `2026-11-10 8:00 AM MST` to `2026-11-13 12:30 PM MST`. When a time
is left unset, the replay uses the start of the first day or the end of the
last day. The end time is exclusive. Times skipped or repeated during a
daylight-saving transition must be changed to an unambiguous time.
Market-session rules still use the exchange's Eastern calendar.

The JSON export retains original UTC timestamps and adds a Mountain-time
export timestamp. An older backend must be updated before it can start a
Mountain-time replay; stop any running simulation before updating it.

- No look-ahead: bars are released one quote at a time on a simulated clock.
  Strategies see a candle only after it closes; orders fill no earlier than the
  next minute's open plus slippage and fees. The final in-progress minute never
  completes.
- Inside each minute the path is open, near extreme, far extreme, close; that
  ordering is an assumption because only OHLC is available.
- Schwab keeps roughly the last month of 1-minute history. Ranges are limited
  to 60 days, cannot be in the future, and weekends/holidays have no data.
- Session close rule (optional, Run Setup): blocks new entries in the final
  10 minutes. At 10 minutes before the close, a strategy whose open positions
  are profitable after estimated exit costs and fees closes them. All other
  positions close 1 minute before the close.
- If edited lookbacks need more bars than the warm-up provides, a strategy
  records WAIT until it has collected enough completed bars.
- Schwab history is split-adjusted. Training retains its input candles with
  the saved session. Historical runs restore as historical results after a restart.

Schwab credentials and tokens are stored by the Windows backend using DPAPI
(`CryptProtectData`, current Windows user) in
`%LOCALAPPDATA%\ATrader\secrets.dpapi`.
They are not sent to LM Studio. Keep the backend on the local machine and do not
expose its loopback service to an untrusted network.

## Checks and builds

```powershell
dart format lib test bin
flutter analyze
flutter test
flutter build windows
flutter build web
```

Run the backend integration smoke check manually with:

```powershell
Invoke-RestMethod http://127.0.0.1:8787/api/status
```

Tests use fixtures only; they do not represent a Schwab account or live-feed
verification. See [docs/CODE_MAP.md](docs/CODE_MAP.md) for the architecture,
storage, tests, and common extension points.
