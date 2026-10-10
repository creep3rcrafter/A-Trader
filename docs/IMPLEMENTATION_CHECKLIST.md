# A-Trader Implementation Checklist

Use `[x]` only after implementation and verification. Revisit provider facts and links before each integration.

## Phase 0 — Audit and research

- [x] Inspect Flutter/Dart version, project structure, dependencies, current UI, tests, routing/state management, and VCS status.
- [x] Record the baseline and staged architecture in `PROJECT_ROADMAP.md` and `ARCHITECTURE.md`.
- [x] Research individual Schwab developer access, market-data entitlement uncertainty, and quote/history/account API surface.
- [x] Compare free market-data candidates and record quota, freshness, exchange coverage, authentication, licensing and constraints.
- [x] Research SEC filings, Google search/news, Reddit, X, Bright Data's unified social scraper, OpenAI, and free issuer/news alternatives.
- [x] Define performance outcomes, entry/exit assumptions, and the 85% target measure in `PERFORMANCE_METRICS.md`.
- [x] Rank provider choices and list exact later acceptance criteria.

## Phase 1 — Flutter interface (current pass only)

- [x] Implement a responsive dashboard with a settings gear at top right.
- [x] Show ranked ideas with explicit mock status, ticker/company, mock last-known price/time, entry range, stop, horizon, and risk.
- [x] Expand evidence, indicator summaries, and risks without showing large charts by default.
- [x] Add mock “Ask GPT Why” with no network/API call.
- [x] Save/unsave ideas; expose saved ideas, statuses, and clearly mock historical outcomes.
- [x] Add portfolio, allocation, horizon, maximum idea count, favorites, theme selector, prompt editor, and prompt/input preview.
- [x] Show provider readiness without implying live/verified connectivity or exposing credential values.
- [x] Add widget tests for key dashboard, expand, save, settings, theme, prompt, and history interactions.
- [x] Format completed; `flutter analyze` reported no issues; all 8 widget tests passed; `flutter build web` succeeded.
- [x] Do not add APIs, database persistence, orders, or backend in this phase.

## Phase 2 — Market data

- [x] Define provider-neutral quote/bar contracts with source/retrieval timestamps, provider/feed identity, adjustment metadata, and freshness states.
- [x] Normalize and validate official Alpaca IEX latest-trade, latest-quote, and historical daily-bar payload shapes with fixture-based unit tests.
- [x] Verify and document Alpaca Basic plan price, official REST quota, IEX coverage/freshness, response fields, and individual-account OTC exclusion.
- [x] Add a loopback-only Alpaca Basic IEX HTTP adapter with server-environment credentials, explicit terms/caching gates, a bounded request rate, duplicate-request coalescing, pagination, and sanitized errors.
- [x] Add a loopback-only Settings health check for backend credential-presence/configuration flags, plus provider setup documentation; no third-party connectivity is claimed and unimplemented connectors stay disabled.
- [ ] Confirm individual Schwab Trader API application access, read-only permissions, market-data entitlements, account terms, and account-specific rate limits in the portal.
- [ ] Obtain and verify official Schwab quote, price-history, account-data endpoints and JSON schemas using an authorized test account.
- [ ] Decide between entitled Schwab data and documented free alternatives; reject paid tiers/trials.
- [ ] Verify Alpaca account and market-data terms; only then configure server-side credentials and permit any provider call.
- [ ] Wire the backend into the UI with visible IEX-only coverage, freshness, missing-data and provider-error states; keep unsupported/OTC symbols unavailable.
- [ ] Verify provider rate headers and cache rights in an authorized account; keep memory caching disabled unless permitted.
- [ ] Test delayed/stale/unavailable behavior and microcap symbol coverage; never infer full market coverage from single-venue data.
- [ ] Verify provider data retention, display, and GPT-processing permissions before storing or forwarding market data.

## Phase 3 — News, social, company filings

- [ ] Resolve tickers to SEC CIK and ingest SEC submissions/company-facts with an identifying User-Agent and fair-access rate limiter.
- [ ] Parse linked SEC filing documents (including Form 4 XML when needed) with source URLs and filed/received timestamps.
- [ ] Inventory official issuer IR RSS/news feeds and their per-site terms before ingestion.
- [ ] Obtain and verify Finnhub or any news provider's free entitlement, limits, license and retention rights before use; otherwise leave disabled.
- [ ] Verify Bright Data's current free-credit eligibility and that the account has no deposited funds or auto-recharge; enforce a local monthly ceiling and halt on exhaustion.
- [ ] Review current X/Reddit and Bright Data terms and obtain any required written authorization for automated scraping/model use; keep social collection disabled until permitted.
- [ ] Implement only one Bright Data adapter/API key for whichever public platform(s) are permitted; do not add direct X API or Reddit Data API integrations.
- [ ] Keep X disabled unless a legitimately free, permitted API becomes available.
- [ ] Keep Google web/news search disabled for automated extraction under the documented cost/access/terms constraints.
- [ ] Normalize, source-link, timestamp, deduplicate and retain only permitted research records.

## Phase 4 — Screening and GPT

- [ ] Define candidate universe and deterministic liquidity, price, volume, momentum and volatility filters.
- [ ] Compute indicators, spreads, portfolio risk and all price levels in ordinary code.
- [ ] Build verified evidence bundles and contrary-evidence checks.
- [ ] Add OpenAI Responses API structured output, schema validation and redacted prompt preview.
- [ ] Enforce call, token, input-size, frequency and estimated-cost budgets before requests.
- [ ] Keep “No suitable trades” valid; validate price, stop, target and evidence references.

## Phase 5 — Allocation and proposals

- [ ] Persist manual risk, budget, filters, holding period, favorites and watchlists.
- [ ] Calculate whole-share hypothetical sizes; prove aggregate value never exceeds budget.
- [ ] Ensure favorites do not bypass safety filters and all proposals remain hypothetical.

## Phase 6 — Journal and outcome evaluation

- [ ] Implement append-only recommendation/version/event storage and automatic logging of all generated ideas/no-trade decisions.
- [ ] Preserve input snapshots, market/research timestamps, model/prompt/strategy versions, and original trade-plan rules.
- [ ] Keep saved/favorite/ignored/paper-evaluation/expired/unfilled/completed states distinct.
- [ ] Add realistic entry, gap, stop/target ordering, costs and slippage simulation.
- [ ] Add journal filters and separate simulated from real broker outcomes.

## Phase 7 — Performance target

- [ ] Implement the exact metrics and classification rules in `PERFORMANCE_METRICS.md`.
- [ ] Report entry triggers, unfilled ideas, sample size, coverage, uncertainty and segment results alongside profitable-plan success.
- [ ] Preserve predefined rules and log strategy changes as new versions.
- [ ] Never claim the 85% target without adequate matured and out-of-sample samples.

## Phase 8 — Backtesting

- [ ] Replay point-in-time inputs chronologically with split/delist/halt/spread/slippage controls.
- [ ] Separate training/validation/held-out test periods and run walk-forward evaluations.
- [ ] Persist strategy/prompt/data versions and document unavoidable historical-data limitations.
- [ ] Use higher-resolution bars for stop/target sequence; otherwise resolve ambiguity conservatively.

## Phase 9 — Optional Schwab brokerage

- [ ] Reconfirm API terms, account eligibility and endpoint capabilities after the journal is established.
- [ ] Keep paper trading the default and live order permission disabled.
- [ ] Enforce long-only, cash-only rules in backend/application logic.
- [ ] Require editable proposal and a separate confirmation of the exact order before every live request.
- [ ] Record broker request, response, status and fills separately from simulations.
- [ ] Prohibit autonomous order placement, modification and cancellation.

## Phase 10 — Reliability and deployment

- [ ] Add secret-safe configuration and log redaction.
- [ ] Add provider timeouts, bounded retries, circuit-breaker/degraded-state behavior and diagnostics.
- [ ] Add local/self-hosted installation, backup/restore and recovery instructions.
- [ ] Test target platforms, network/privacy behaviors, provider limits, and no-paid-fallback guarantees.
