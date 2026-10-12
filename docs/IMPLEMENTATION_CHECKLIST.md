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

- [x] Replace Phase 1 mock ideas, sample outcomes and manual research UI with ten temporary unscreened live-quote cards in Ideas, session-only Saved, empty History, explicit freshness/coverage/errors and quota-aware automatic loading.
- [x] Pin Flutter Web to `localhost:3000` and backend launcher CORS to that origin, retaining backend port `8765`.
- [x] Verify the replacement with clean analysis, all 92 current tests, IDE build and web compilation; cover loading, refresh, saved/navigation retention, request pacing, failures and stale responses.
- [ ] Verify live population after restarting the credential-configured backend: the running service's 2026-10-11 smoke check reported Alpaca credentials/terms absent (quotes HTTP 503) and rejected `http://localhost:3000` (HTTP 403). UI fixture checks are complete, but current live prices remain blocked.

- [x] Implement and verify Twelve Data Basic quote/daily-bar normalization, server-only header authentication, durable free quota caps, safe failures and Settings readiness. Full suite: 37 tests passed; Flutter/backend analysis, IDE build, web build and credential-free checks for both provider selections passed.
- [ ] Verify Twelve Data account credentials with an authorized personal research/test request; do not interpret health presence as authentication.
- [ ] Resolve Twelve Data Basic display/sharing, retention and GPT-forwarding rights before any production/shared dashboard or model use; no paid licensing fallback.
- [x] Define provider-neutral quote/bar contracts with source/retrieval timestamps, provider/feed identity, adjustment metadata, and freshness states.
- [x] Normalize and validate official Alpaca IEX latest-trade, latest-quote, and historical daily-bar payload shapes with fixture-based unit tests.
- [x] Verify and document Alpaca Basic plan price, official REST quota, IEX coverage/freshness, response fields, and individual-account OTC exclusion.
- [x] Add a loopback-only Alpaca Basic IEX HTTP adapter with server-environment credentials, explicit terms/caching gates, a bounded request rate, duplicate-request coalescing, pagination, and sanitized errors.
- [x] Add a loopback-only Settings health check for backend credential-presence/configuration flags, plus provider setup documentation; no third-party connectivity is claimed and unimplemented connectors stay disabled.
- [ ] Confirm individual Schwab Trader API application access, read-only permissions, market-data entitlements, account terms, and account-specific rate limits in the portal.
- [ ] Obtain and verify official Schwab quote, price-history, account-data endpoints and JSON schemas using an authorized test account.
- [ ] Decide between entitled Schwab data and documented free alternatives; reject paid tiers/trials.
- [ ] Verify Alpaca account and market-data terms; only then configure server-side credentials and permit any provider call.
- [x] Wire the loopback backend to Flutter with validated provider/feed identity, coverage, freshness, missing-data and sanitized errors; originally a manual view, now replaced by automatic temporary Ideas.
- [x] Implement raw daily-history client support for the last 30 calendar days, preserving trading-date/timezone metadata; the original manual history table was removed at user request.
- [x] Verify browser-safe injected HTTP/service ownership, strict response validation, forbidden remote URLs, sanitized arbitrary error bodies and stale-response guards with fixture and widget tests.
- [x] Validate the research UI with formatting, clean `flutter analyze`, all 101 Flutter tests, `flutter build web` (including its Wasm dry run), and a successful IDE build. No live-provider requests were made for this validation; authentication/rights checks remain unchecked above.
- [ ] Verify provider rate headers and cache rights in an authorized account; keep memory caching disabled unless permitted.
- [ ] Test delayed/stale/unavailable behavior and microcap symbol coverage; never infer full market coverage from single-venue data.
- [ ] Verify provider data retention, display, and GPT-processing permissions before storing or forwarding market data.

## Phase 3 — News, social, company filings

### Current bounded local-research increment

- [x] Verify existing frontend research contract against the implemented POST route.
- [x] Verify quote/daily-bar/SEC handlers with deterministic fixtures and explicit unavailability; SEC filing dates remain date-only, with actual retrieval timestamps.
- [x] Verify exact symbol-only arguments, native call IDs, complete batch validation, three-turn/four-tool budgets and shared per-model-call accounting.
- [x] Verify unsupported/unsafe citations and local-provider failures fail explicitly without OpenAI or market-provider fallback.
- [x] Demonstrate the configured LM Studio native tool-request/result/final cycle with synthetic data only: `google/gemma-4-e4b`, two actual chat calls, one validated `get_market_quote`, linked result received, final synthetic price `17.375` reproduced. No market/SEC network or OpenAI request.
- [x] Run formatting, clean Dart backend/Flutter analysis, 94 targeted tests, all 190 regression tests, IDE build and same-origin Flutter Web compilation (Wasm dry run passed). Ordinary suites intentionally skip the one native opt-in test; it passed independently.
- [ ] Verify authorized live quote/bar/SEC access separately; fixture success is not provider authentication, account entitlement or data-use permission.
- [ ] Complete the deterministic daily-indicator engine beyond its first slice: trend/EMA, RSI/MACD, ATR/volatility, dollar volume/liquidity and explicit application integration.

**Validation notes:** initial integration runs failed on SEC constructor alignment, a frontend helper's scope, a relative-link citation guard and synthetic test-clock/date expectations. These were corrected; the final targeted/full suites and analyzers have no outstanding failures. A SEC filing date is not converted to an invented midnight publication timestamp. Quote fixtures also cover crossed bid/ask rejection and an old trade price paired with a newer quote. SEC fixtures cover permissions/User-Agent, safe links/issuer/date metadata, conservative shared pacing/quotas/cooldowns, malformed and oversized responses, transport failures and timeouts.

**Remaining verification boundaries:** no live market-data/SEC request or OpenAI call was made. Account authentication, permitted display/model processing, source coverage and live SEC access still need authorized setup; health is not an entitlement check. SEC timeout reporting does not guarantee underlying HTTP cancellation. Native local inference success establishes one synthetic tool cycle only, not reliable financial interpretations or performance.

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

### First deterministic indicator slice

- [x] Add a pure Dart calculation layer using existing `MarketBar` records without new APIs/dependencies.
- [x] Validate identity, adjustment, OHLCV, session ordering/date semantics, explicit completed-session cutoff and timestamp consistency.
- [x] Implement session colors/counts/fractions, green:red ratio, close returns, SMA and relative volume with declared formulas and units.
- [x] Return typed unavailability for insufficient samples, unverified/missing expected sessions, stale inputs, zero denominators and non-finite results; never fill gaps.
- [x] Preserve per-result provenance, feed-volume limitations and raw-price comparability gates.
- [x] Verify golden fixtures, boundaries, malformed input, date/freshness/coverage behavior, immutable output and deterministic/prefix behavior.
- [x] Run formatting, 28 focused indicator tests, all 218 regression tests, clean Flutter/backend analysis and IDE validation; existing research/Ask AI/market regressions pass. Same-origin Flutter Web compilation and Wasm dry run passed. The native LM Studio test remains opt-in and was skipped in this increment; no model/provider requests were required.
- [ ] Add the remaining MACD, ATR/volatility and liquidity indicators. No current stock screening or quantitative AI authority is implied.

**First-slice verification boundaries:** expected sessions and raw-price comparability are supplied by callers, not independently verified by this library. Timestamp-only bars use labelled UTC-date proxies, not exchange-timezone conversion. IEX volume remains partial; Twelve Data daily EOD volume uses the distinct complete-but-account-coverage-unverified label. Card/tool integration was added in the follow-on below. No new external API, credential, dependency, scoring, trade-plan or performance claim was added.

### Trend / EMA / RSI and explicit indicator integration

- [x] Extend deterministic calculations with normalized SMA slope/trend, SMA-seeded EMA and Wilder RSI, including flat/zero-gain/zero-loss conventions and versioned parameters.
- [x] Verify independent golden vectors, seed/warmup thresholds, missing/stale historical windows, numerical stability and serialization: 44 engine tests passed.
- [x] Expose a bounded read-only indicator endpoint using the existing gated daily-bar adapter without extra providers, retries or silent fallback.
- [x] Establish expected completed US sessions independently of returned bars; document regular holiday/calendar scope, delayed availability assumptions and exceptional-closure limitations.
- [x] Add symbol-only `get_technical_indicators` to local research; preserve three model turns/four tool executions, local-only routing and actual result/citation provenance.
- [x] Add an explicit card action showing deterministic values, unavailable reasons, source/date/feed, formula version and coverage/freshness limits; no automatic history or AI calls.
- [x] Validate frontend response shapes/units and lifecycle handling, including refresh/backend changes, unavailable data and sanitized failures: 30 client/card tests and eight service/calendar/HTTP tests passed, including actual endpoint-to-frontend parsing.
- [x] Verify the real local native indicator tool request/result/final cycle using synthetic bars only: configured `google/gemma-4-e4b` passed the opt-in indicator test; the native quote cycle also passed again. No live provider/SEC or OpenAI requests.
- [x] Run formatting, all 274 regression tests, clean Flutter/backend analysis, IDE validation and same-origin Flutter Web compilation/Wasm dry run. The two native tests are skipped in the ordinary suite and passed separately.

**Follow-on boundaries:** 120 calendar days/records, fixed 20-session SMA/EMA, one-session trend lag and 14-delta RSI; conservative static US-equity calendar for 2025–2030, not authoritative for exceptional closures. Recursive metrics require their entire supplied seed history. Raw arithmetic metrics carry corporate-action distortion caveats; raw close returns remain unavailable without comparability confirmation. Live credentials, permissions, data coverage and browser interaction with live history remain unverified. Initial mid-edit analyzer/test failures were corrected; no outstanding validation failures remain.

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

- [x] Add Windows user-bound encrypted private configuration and reusable setup/launch scripts so API credentials need not be re-entered at each start.
- [x] Add explicit password-protected trusted-private LAN web/API hosting on port 3000, session expiry, login throttling, Host/Origin validation and bounded static/API requests; no automatic firewall/public exposure.
- [x] Add explicit Ask AI explanations with server-side LM Studio fallback when OpenAI key absent, optional local auth, separate processing/locality rights gates and bounded/sanitized calls.
- [x] Verify integrated code with clean analysis, all 141 tests, IDE build, same-origin web build and synthetic DPAPI/launch parsing checks.
- [ ] Complete private setup, verify authorized live market/model requests, and confirm login/data/model access from a second LAN device. Model listing alone is not inference verification; LAN HTTP is not secure Internet deployment.
- [ ] Add secret-safe configuration and log redaction.
- [ ] Add provider timeouts, bounded retries, circuit-breaker/degraded-state behavior and diagnostics.
- [ ] Add local/self-hosted installation, backup/restore and recovery instructions.
- [ ] Test target platforms, network/privacy behaviors, provider limits, and no-paid-fallback guarantees.
