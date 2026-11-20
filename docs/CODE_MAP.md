# Code map

This map describes the current implementation and its verified boundaries.
Schwab credentials and account access are required for live-service validation;
tests use synthetic fixtures and never claim to be real market data.

| Feature | Entry point | Implementation | Storage | Tests |
|---|---|---|---|---|
| Flutter application and dashboard | `lib/main.dart` | Single dashboard with collapsible simulation controls, per-ticker candle charts, expandable strategy metrics/recorded performance/decisions, open trades, and virtualized multi-select decision log with final-column reasons; ready-only training panel | Frontend-only filter/expansion/visibility state; backend API | `test/widget_test.dart` |
| Windows backend launch | Offline banner or Settings > Local backend in `lib/main.dart` | `lib/backend_launcher.dart`, `lib/backend_api_io.dart`; reuse, detached startup, health polling, visible errors | Startup diagnostics in `%LOCALAPPDATA%\ATrader\backend-startup.log` | `test/backend_launcher_test.dart`, `test/widget_test.dart` |
| Windows service packaging | `windows/CMakeLists.txt` | `windows/backend/CMakeLists.txt` compiles `bin/server.dart` into the bundled `atrader_backend.exe` | Windows build output beside `atrader.exe` | `flutter build windows`; bundled-service smoke check |
| Local API and independent runs | `bin/server.dart`; simulation picker | `lib/local_backend.dart`; per-run lifecycle, immutable used configurations, shared subscription union, recovery, run-scoped reads | Schema-v2 `%LOCALAPPDATA%\ATrader\state.json`; one-time `state-before-multi-run.json` migration backup | `test/local_backend_test.dart`, `test/independent_runs_test.dart` |
| Schwab OAuth and live quotes | Settings in `lib/main.dart` | `lib/schwab_api.dart`; OAuth, token refresh, preferences, Level One stream, reconnect. `lib/oauth_callback_server.dart`; local HTTPS callback listener | `lib/secure_storage.dart` DPAPI via FFI | `test/simulator_test.dart` DPAPI round-trip/legacy format; `test/local_backend_test.dart` credential save, OAuth start, callback state check, pasted-URL validation; no real Schwab token exchange test |
| Feed health and candles | Quote callback in `lib/local_backend.dart` | `lib/live_runtime.dart`; freshness gate, reconnect handling, session candle builders | Runtime checkpoint | `test/simulator_test.dart` |
| Exchange sessions | `UsEquityCalendar` | `lib/exchange_calendar.dart`; DST, holidays, early closes | None | `test/simulator_test.dart` |
| Strategies and parameter schemas | `lib/algorithms/registry.dart`; compatibility export from `lib/simulator.dart` | One Dart file per registered strategy, shared contract in `lib/strategy_api.dart`, indicator/signal helpers in `lib/algorithms/helpers.dart`; model adapters and benchmark allocation policies also live in `lib/algorithms` | Stable strategy IDs and parameter keys in saved run settings and engine checkpoint | `test/algorithm_registry_test.dart`, `test/simulator_test.dart`, `test/short_strategies_test.dart` |
| In-app algorithm import | Simulation controls > Add algorithm from file; `POST /api/algorithms/import` | Platform file picker, validated JSON expressions, native Dart compilation/persistent workers, backend metadata catalogue, per-isolate restore for tuning/replay | Source and metadata in state.json / JSON export; compiled Dart workers in application data; immutable unique IDs | `test/algorithm_import_test.dart`, importer UI tests in `test/widget_test.dart` |
| Strategy evolution | Simulation Controls Start; `POST /api/research/start` | `lib/auto_research.dart` and `lib/strategy_tuning.dart`; saved sessions, configurable mutations, best profit/win-rate parameter records, generation replays and resume | Per-run research session, downloaded history, best settings, replays and archived sessions in state.json | `test/short_strategies_test.dart`, `test/research_preview_test.dart`, `test/widget_test.dart` |
| Mountain date/time display | Dashboard, charts, Run Setup, training and JSON exports | `lib/mountain_time.dart` uses `America/Denver` with MST/MDT and a 12-hour clock; machine timestamps and exchange-session rules remain unchanged | Original UTC checkpoint data; exports include Mountain export time | `test/mountain_time_test.dart`, `test/widget_test.dart`, `test/data_export_test.dart` |
| Historical date replay | Run Setup > Historical in `lib/main.dart`; `POST /api/run/historical/start` | `lib/historical_replay.dart` (time-ordered quotes, `ReplayClock`, awaited pre-decision LM hook); Mountain inputs convert to UTC; `SchwabApi.fetchMinuteBars`; `LocalBackend._runHistoricalReplay` | In memory only; state file records it as not running | `test/historical_replay_test.dart` (no look-ahead, next-open fills, stop, time ranges); `test/historical_lm_test.dart` (awaited same-candle selection, no timeout, cancellation, instance isolation, explicit errors, live non-blocking regression) |
| Clear run data | Run Setup > Clear run data; `POST /api/run/reset` | `DashboardController.resetRun` and `LocalBackend`; requires a stopped run and confirmation in the UI | Removes the runtime checkpoint while retaining configuration and credentials | `test/local_backend_test.dart`, `test/widget_test.dart` |
| Export run data | App-bar download button; `GET /api/export` | `lib/run_data_export.dart`, `lib/data_export_io.dart`; backend simulation and generation data with portfolio performance, offline checkpoint fallback | One JSON file in Downloads with candles, events, equity, trades, settings, training, models, and win rates | `test/data_export_test.dart`, `test/research_preview_test.dart` |
| Simulated orders, risk, and accounting | `SimulatorEngine` in `lib/simulator.dart` | Explicit side/effect, cash-collateralized shorts, bid/ask fills, protective exits, optional ten-/one-minute close policy, benchmarks | Per-engine checkpoint including close-decision locks and derived valuations, not raw executable quotes | `test/simulator_test.dart` |
| LM Studio strategy selection | Settings and registry `lm_selector` | `lib/lm_studio.dart`, per-run selection in `lib/local_backend.dart`; asynchronous live requests, historical backpressure after warm-up with Stop cancellation, same evaluator and pinned exit source; readiness includes model availability | URL/model settings, selected evaluator on positions/orders | Fixture-server restrictions, offline isolation and exit-source tests in `test/simulator_test.dart`; backend integration in `test/historical_lm_test.dart`; no real-server check |
| Prospective live training | Settings training controls | `lib/live_training.dart`, `lib/training.dart`; separate 1m collector, mature labels, isolate fitting, training-only preprocessing, purged chronological holdout, validated candidates | Bounded mature examples/candidates and immutable per-run pinned model payloads | `test/live_training_test.dart`, `test/training_test.dart`, `test/independent_runs_test.dart` |

## Extension points

- **Add a strategy:** copy a native template or an existing file into
  `lib/algorithms`, implement `TradingStrategy` from `lib/strategy_api.dart`
  (or extend `BuiltinStrategy` for the shared insufficient-history guard),
  and register its import and instance in `lib/algorithms/registry.dart`.
  Keep its stable ID, typed parameters, and evaluator in the algorithm file,
  then add focused evaluator tests. See `lib/algorithms/README.md`. The
  registry supplies UI descriptions, parameter metadata and LM Studio tool
  schemas. Dashboard and log labels resolve descriptions by strategy ID.
- **Import a personal strategy:** use the in-app JSON/Dart file chooser.
  `AlgorithmLibrary` persists the original definition and native executable
  location; the backend restores imports before restoring runs. Tuning workers
  restore their own library/workers from serializable definitions. The frontend
  receives metadata only. Keep SDK packaging in `windows/CMakeLists.txt` aligned
  with `compileDartAlgorithm`; never transfer process handles across isolates.
- **Update a parameter:** change the registry entry's key, readable label,
  unit, default, and allowed range together. Update any persisted-setting
  migration and tests if the parameter changes behavior.
- **Change a fill rule:** edit the quote-driven order/fill and protective-exit
  paths in `SimulatorEngine` in `lib/simulator.dart`. Preserve later-event
  eligibility, bid/ask side, fees, slippage, risk accounting, and duplicate
  event protection; extend simulator tests.
- **Introduce another execution adapter:** `ExecutionAdapter.submit` receives a
  risk-approved simulated order intent. This release constructs
  `SimulatorExecutionAdapter` internally and it only queues local simulated
  orders. Any future adapter requires an explicit, reviewed backend wiring
  change; the Schwab market-data integration does not submit orders.
- **Change chart hover:** `EquityChart`/`_EquityPainter` and `CandleChart`/`_CandlePainter` in `lib/main.dart` draw crosshairs; shared `_ChartHoverSurface` displays details in the root overlay above subsequent charts. Equity lines share a time axis; hover values interpolate on the painted line. `_portfolioColors` assigns unique colors beyond the base palette, shared by legend, equity, drawdown, and expanded strategy charts. Equity charts can include dotted starting-cash levels (zero in return view). The simulator replaces multiple marks at one timestamp with one portfolio mark, preventing vertical jumps when symbols complete candles together.
- **Run more simulations:** `POST /api/runs/create` creates a stopped selected run; `POST /api/runs/select` changes only the display selection. Snapshot/status/log accept `?runId=`. Each run can contain multiple independent strategy portfolios. Configuration changes after data exists require a new run or explicit clear. Shared feed/training callbacks must capture the intended run, never rely on display selection.
- **Change short behavior:** preserve explicit `PositionSide` and `PositionEffect` through wrappers, orders, events, checkpoint migration, API serializers and exports. A legacy SELL is exit-only. Reserve entry notional without crediting sale proceeds. Covering remains possible even when losses exceed reserve.
- **Change model training:** edit `LiveModelTraining` and `ModelTrainer`; preserve prospective label timing, gap invalidation, bounded buffers, purged later holdout, and training-only preprocessing. Existing `PinnedModelStrategy` instances never switch to a newer candidate. Only 1m long-only trained adapters are currently wired.
- **Add a chart metric:** add the calculation to the account/metrics shaping
  path in `lib/local_backend.dart` and render it in `lib/main.dart`. Test the
  metric calculation independently of Flutter rendering where possible.
- **Change live candle/session behavior:** edit `SessionCandleBuilder` in
  `lib/live_runtime.dart` and session rules in `lib/exchange_calendar.dart`.
  Missing intervals must not be synthesized; invalidate affected warm-up after
  a gap.
- **Change Windows startup:** `WindowsBackendLauncher` resolves the backend
  beside the running Flutter executable and verifies `/api/health` before and
  after launch. `bin/server.dart --background` avoids console I/O and leaves the
  server running independently. Keep the health identity/version and bundle
  filename consistent with `LocalBackend` and the Windows CMake target.
- **Change Windows credential handling:** `SecureStorage` in
  `lib/secure_storage.dart` calls DPAPI directly through `dart:ffi`
  (`WindowsDpapi`); no helper process is used, so it works in the detached
  backend. The file format (hex DPAPI blob of UTF-16LE JSON) matches earlier
  PowerShell-written files. Never log plaintext or include it in errors.
- **Change the OAuth callback:** `LocalBackend._startAuthorization` parses the
  saved callback URL and starts `OAuthCallbackServer`
  (`lib/oauth_callback_server.dart`) for loopback HTTPS or non-backend ports.
  Its self-signed PFX and DPAPI-protected password live in
  `%LOCALAPPDATA%\ATrader`. `POST /api/schwab/oauth/complete` accepts a pasted
  redirected URL. Both paths go through `SchwabApi.completeAuthorization`.

## Important current limitations

- Schwab's official portal describes OAuth 2.0 and real-time API access, but
  the detailed docs were inaccessible during implementation and OAuth
  registration, streamer message semantics, account entitlement, and data
  retention/model-use terms remain unverified against an authenticated account.
- LM Studio selection is wired, but real-server compatibility and Schwab's
  model-use permissions still require operator verification.
- Trained models are long-only and 1m-only. A single chronological holdout,
  even with purging and metric gates, does not demonstrate profitability.
  Labels use close returns and a configured cost hurdle, not executable fills.
- Simulated shorts assume borrow availability; recalls and borrow interest are
  not modeled. Close-window exits cannot guarantee flattening without eligible
  regular-session quotes. Benchmarks intentionally remain outside that policy.
- Historical results are restored for viewing. Training resumes explicitly
  from its last completed generation. They do not enter live training.
- The backend HTTP API has integration tests for health, credential save, and
  OAuth start/callback validation using dummy credentials. The real Schwab
  token exchange and crash-recovery of the state-file replace path remain
  unverified.

## Build and verification commands

From the repository root in PowerShell:

```powershell
dart format lib test bin
flutter analyze
flutter test
flutter build windows
flutter build web
dart run bin\server.dart
```

See the root `README.md` for launch, OAuth setup, and the backend status
endpoint.
