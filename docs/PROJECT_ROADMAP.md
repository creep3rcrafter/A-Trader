# A-Trader Project Roadmap

**Reviewed:** 2026-10-10
**Product:** Private microcap swing-trading research assistant. No broker orders are sent.

## Project goals

- Produce explainable, timestamped hypothetical trade plans from verified inputs.
- Keep quantitative calculations deterministic and keep GPT limited to interpreting sourced evidence.
- Treat provider cost, permissions, provenance, data freshness, and market-data licensing as design constraints.
- Keep one-user/local-first operation possible; do not require paid hosting or any paid non-OpenAI service.
- Measure outcomes with predeclared, realistic entry and exit rules. Never imply an 85% success rate before adequate out-of-sample evidence exists.

## Current baseline and architecture

The starting repository was a Flutter 3.44.2 / Dart 3.12.2 application with a single counter screen, one counter widget test, and only Flutter SDK plus Cupertino icons as runtime dependencies. There was no existing routing, state-management, persistence, backend, API client, or business architecture to preserve.

Phase 1 keeps the application Flutter-only and dependency-free: responsive Material UI, a small in-memory app state, explicit mock records, and theme/prompt/settings controls. Later phases should introduce feature-focused UI, repositories and provider adapters only as integrations are actually built. The suggested long-term path is a local/self-hosted backend for secrets, scheduled research, provider quotas, and append-only history, with the Flutter app as the client. No backend or live provider is included in Phase 1.

## Milestones and acceptance criteria

### Current incremental scope and next phase (2026-10-12)

The current working tree already contains the Flutter watchlist, Ask AI, Dart server, provider adapters and the frontend research action/contract. Before this increment the backend research route, native tool dispatcher and SEC metadata adapter were missing. Historical phase checkmarks below are not evidence that today's live credentials, provider rights, tool calling or trading performance work.

This increment completes only bounded local research wiring and tests. Opportunity scoring, computed trade plans, durable evidence/history, permitted news/social ingestion, dynamic discovery, paper outcomes and backtesting remain unimplemented. No live quote/SEC authorization is inferred from synthetic tests, and no win-rate claim is supported.

**Verified outcome:** 94 targeted and 190 full regression tests passed; the opt-in real `google/gemma-4-e4b` cycle independently completed two model calls/one validated synthetic quote tool, received its linked result and returned the exact fixture price. Formatting, Flutter/backend analysis, IDE build and same-origin Flutter Web compilation passed. Live provider authentication/rights and live SEC access remain unverified.

### Deterministic daily-indicator engine: first slice and remaining design

Implement a pure Dart service over the existing `MarketBar` model; reuse `dailyBars` rather than add APIs/dependencies. Start with a typed input validator and session counts, returns, SMA and relative volume; then add the remaining formulas below in independently tested slices. Do not combine this work with scoring, trade plans, discovery or AI-generated numbers.

**Current slice scope:** a reusable calculation layer for validated completed daily bars, session counts/ratios, close returns, SMA and relative volume. It does not change the existing quote/research endpoints or automatically fetch extra bars, invoke AI, expose new UI recommendations or spend provider quota. Caller-supplied expected session dates and an explicit last-completed-session cutoff are required to establish complete calculation windows; no holiday calendar or timezone library is added. Without established coverage, metric results must remain explicitly unavailable rather than calculate over an implicitly compressed session history.

**Implemented first-slice API:** `DailyIndicatorEngine.calculate(config: DailyIndicatorConfig(...), bars: List<MarketBar>)` returns immutable, typed metrics with serializable formula/unit/window/source metadata. The validator rejects malformed/mixed series; metrics distinguish insufficient, stale, incomplete and unverified data. Session windows use supplied expected dates rather than assuming weekday calendars.

**First-slice validation:** 28 focused indicator tests and all 218 regression tests passed; formatting, Flutter/backend analysis, IDE validation and existing same-origin Web compilation passed. The local native-model smoke test is intentionally opt-in/skipped here because this pure calculation increment makes no model calls. API/UI integration and remaining formulas are still unchecked, not implied by these results.

Raw-price comparability requires an explicit caller confirmation; neither a raw feed nor an adjustment label alone verifies corporate-action history. Adjusted close returns remain arithmetic series returns, not verified investable total returns. Partial-feed relative volume compares that same feed's returned volumes, not market-wide volume or executable liquidity.

**Current follow-on scope:** extend this foundation with SMA slope/trend, EMA and RSI using the declared initialization conventions and golden vectors. Expose the same deterministic results through an explicit card action and the bounded local research tool, with source/coverage/freshness metadata and typed unavailable values. Model interpretations must not replace code-computed values. Keep MACD, ATR, realized volatility, dollar-volume/liquidity thresholds, scoring and trade plans for later independently testable increments.

**Calculation conventions implemented in the follow-on:** `daily-indicators-v2`, default trend lag one session and RSI period 14. EMA and RSI retain the full expected history's seed/warmup metadata; missing/stale input anywhere in that recursive history makes them unavailable. SMA trend uses the required N+K trailing expected sessions. Raw arithmetic summaries remain labelled as potentially distorted by unverified corporate actions, while raw economic-return interpretation is still gated.

**Follow-on verified:** explicit quote-card action and symbol-only `get_technical_indicators` share the bounded deterministic backend service. All 274 regressions, Flutter/backend analysis, formatting, IDE validation and same-origin Web/Wasm dry run passed. Both real native LM Studio quote and indicator tool cycles passed separately using synthetic fixtures; no live market/SEC or OpenAI calls. History is bounded to 120 calendar days/records, with a conservative independent US-equity calendar for 2025–2030; unsupported years and missing sessions are explicit. Live access/rights remain unverified.

**Next small increment:** add deterministic MACD (SMA-seeded EMA 12/26, signal EMA 9 and histogram) with declared seed/history/insufficient-data rules, independent golden vectors and the same card/tool contract. Keep ATR/volatility and dollar-volume/liquidity for subsequent slices; do not introduce scoring, plans or performance claims.

**Input contract:** one symbol/provider/feed; positive finite consistent OHLC, nonnegative integer volume; strictly increasing unique completed exchange-session dates; consistent known adjustment and timezone/timestamp semantics. Require an explicit analysis cutoff, requested trading-session lookbacks, freshness limit and coverage expectation. Reject mixed raw/adjusted series and future/unfinished sessions. Preserve source/retrieval times, actual count, date range, provider coverage and formula/version/parameters with every result. Do not treat sparse IEX or unverified partial volume as consolidated volume.

**Availability contract:** each metric is a typed value or unavailable with a specific reason and required/observed counts. Invalid input fails validation explicitly; insufficient samples, zero denominators, stale/incomplete coverage or unsupported volume semantics must not become zero, infinity or an invented neutral signal. Do not forward-fill missing bars or assume weekends/holidays are missing sessions without an explicit exchange calendar. No calendar dependency is required in the first slice: callers supply expected completed session dates, or coverage remains explicitly unverified.

| Metric | Formula / convention | Minimum completed sessions |
|---|---|---|
| Session colors | Green if `close > open`, red if `close < open`, flat otherwise, over last `N` sessions; green/red fractions divide by all `N`, flats reported separately; green:red is undefined when red is zero | `N` |
| Lookback return | `close[t] / close[t-N] - 1`; fractional units, not percent; retain adjustment identity | `N+1` |
| Relative volume | `volume[t] / mean(volume[t-N .. t-1])`; exclude latest session from baseline; zero mean unavailable; partial-volume limitation preserved | `N+1` |
| SMA / trend | Arithmetic mean of last `N` closes; normalized slope `(SMA[t] / SMA[t-K]) - 1`; positive/negative/zero = rising/falling/flat; no inferred probability | `N` for SMA, `N+K` for slope |
| EMA | Seed with first `N`-close SMA; subsequent `EMA[t] = alpha*close[t] + (1-alpha)*EMA[t-1]`, `alpha=2/(N+1)` | `N`; disclose initialization/warmup |
| RSI (default 14) | Wilder means of positive/negative close deltas, seed with first 14 deltas; recurse `(previous*13 + delta)/14`; `100 - 100/(1+avgGain/avgLoss)`; zero loss and positive gain = 100, zero gain and positive loss = 0, both zero = 50 (explicit convention) | 15; seed instability disclosed |
| MACD (12,26,9) | EMA12 minus EMA26 using the seed above; signal EMA9 of available MACD values; histogram = MACD minus signal | 26 for MACD, 34 for signal/histogram |
| ATR (default 14) | `TR = max(high-low, abs(high-prevClose), abs(low-prevClose))`; first bar has no previous close and is excluded; initial 14-TR mean then Wilder smoothing; ATR percent = ATR/latest close | 15 |
| Realized volatility | Sample standard deviation (`N-1` divisor) of last `N` log close returns; annualized by `sqrt(252)` only when explicitly requested for daily sessions; report base and annualization assumption | `N+1`, `N>=2` |
| Dollar volume / liquidity | Daily proxy `close*volume`; trailing arithmetic mean over `N`; optional caller-defined minimum threshold comparison outside AI; not actual traded notional or executable depth | `N`; volume scope required |
| Freshness / coverage | Last completed-session date versus explicit cutoff/expected session set; source retrieval age versus caller limit; enumerate missing/duplicate dates and actual/expected coverage ratio | Explicit cutoff/expectations; otherwise unverified |

**Tests:** hand-calculated small arrays; flat/up/down series; RSI zero-gain/loss conventions; EMA/Wilder seed checkpoints; independently calculated MACD/ATR/log-volatility golden vectors; previous-close gaps; zero volume; `N-1/N/N+1` boundaries; duplicate/out-of-order dates; missing sessions; mixed symbols/providers/adjustments; non-finite/invalid OHLC; incomplete/future/stale bars; exchange-date versus UTC behavior; partial-volume limitations; deterministic repeatability and prefix invariance (future bars cannot change earlier outputs).

**Accept when:** no model/provider dependency in the calculation layer; all formulas and fractional/price units are versioned and match golden fixtures within declared floating-point tolerance (e.g. `1e-10` absolute/relative for unit fixtures); every unavailable value explains why; all inputs/coverage provenance remain visible; no invented fills/signals/win rates; existing research/Ask AI/market routes regress cleanly. Raw bars crossing an unverified split cannot be treated as an economic return; adjusted analysis requires known comparable adjustment metadata from the existing adapter.

**Subsequent planning-only sequence:** explainable deterministic scoring (including no suitable trades), hypothetical sizing/entries/stops/targets, persistent evidence/history, permitted news/SEC/public-social research, dynamic candidates, conservative paper outcomes, historical/walk-forward validation, and only then weight optimization on development data with held-out out-of-sample reporting. Do not use model confidence as measured success.

### Phase 0 — Audit and provider research

Deliver five maintained documents: this roadmap, implementation checklist, provider research, architecture, and performance metric definitions.

**Accept when:** the baseline and tradeoffs are recorded; sources are official where available; every provider recommendation states free access, constraints, and unresolved checks; a ranked free-provider set and exact phase checklist exist.

### Phase 1 — Responsive Flutter interface (current implementation)

Implement a dashboard of clearly labelled synthetic stock ideas; top-right settings; expandable evidence, indicators, and risks; mock Ask GPT Why; saved ideas and outcome-history view; configurable portfolio/risk settings, favorites, theme, prompt editor and preview, and clearly mock provider statuses.

**Accept when:** mobile/narrow and desktop/wide layouts remain usable; theme changes apply immediately; save/favorite/settings/prompt interactions work; mock data cannot be mistaken for live data; tests cover the primary interactions; no network requests, order placement, or persistence are present.

### Phase 2 — Free market-data layer

**Tool-first research change:** The user has deferred Bright Data/SearXNG selection and requested an initial LM Studio tool-use experiment. Add only bounded read-only market-data and recent SEC-metadata tools first, showing actual executed tools, sources and missing capabilities. Broad stock discovery, article/social ingestion, factor-based ranking and validated trade-price calculations remain incomplete; no model claim substitutes for those features.

**2026-10-12 local deployment increment:** Add user-bound encrypted server configuration, password-protected trusted-LAN hosting on port 3000, and explicit Ask AI quote explanations using LM Studio when no OpenAI key is configured. Shared-display and model-processing permissions remain separate default-deny gates. This does not complete screening, durable prompt/recommendation journaling, accuracy measurement or secure Internet deployment. LM Studio model listing was reachable; generation and cross-device access still require user configuration and verification.

**2026-10-11 update:** Alpaca IEX is the selected default; Twelve Data Basic remains explicitly selectable for local personal market research/testing. Quotes and daily bars use server-side adapters once credentials and terms are configured; no API key is sent from Flutter. Twelve Data Basic's non-display restriction prevents assuming permission for a shared production dashboard. Enforce free quotas, exclude OTC/paid feeds, and obtain free display/retention/GPT permissions before those later features. Provider errors never trigger an automatic switch.

**Temporary live Ideas UI:** At the user's request, mock ideas/outcomes and the manual Market data section were removed. Ideas automatically loads ten unscreened watchlist quotes through the saved loopback service URL, with source/feed identity, timestamps, freshness, partial-feed coverage and explicit errors. Saved filters those stocks in memory; History has no fabricated results. Refresh is explicit, Twelve Data calls are paced, and quota/configuration failures stop the run. No screening, trade-plan generation or GPT forwarding occurs. Web launch is fixed at `localhost:3000`, with the backend on `127.0.0.1:8765`. Fixture/widget validation and compilation do not establish account data-use rights.

Add a provider-independent market-data model and repository. The current Phase 2 foundation defines and tests normalized quote/bar contracts, Alpaca response mapping, and a loopback-only Alpaca IEX adapter. Settings can query the local service's `/health` route for server-side credential-presence flags; this is configuration visibility only, not third-party connectivity or entitlement verification. First verify the user's individual Schwab Trader API eligibility and market-data entitlements in the authenticated portal. Alpaca Basic IEX is only a constrained candidate: it is one exchange, omits OTC data for individual accounts, and is not consolidated. Record venue/coverage, delay, stale/missing data, splits, quote limitations, rate limits, and permitted storage/display before enabling any network adapter.

**Accept when:** provider-specific responses normalize to timestamped OHLCV/quote records; no provider is called when disabled or at quota; errors and stale/delayed/unavailable data are visible; test fixtures are identified as fixtures; real requests are opt-in and can be tested without exposing credentials to web clients.

### Phase 3 — Filings, news, and public research

Prioritize SEC EDGAR submissions/company facts and issuer investor-relations sources with links and timestamps. For social data, use at most one provider integration: Bright Data Social Media Scraper API, which can target X or Reddit with one Bright Data API key. It has a recurring but capped free allowance; keep it disabled unless current platform permissions and Bright Data terms clearly authorize the intended public-data collection and model processing. Do not make direct X API or Reddit Data API integrations. Never scrape authenticated/private content, bypass access controls, or continue past the free quota.

**Accept when:** normalized records retain source URL, publication/retrieval times, ticker mapping, and deduplication key; unsupported providers fail closed and cannot be silently replaced by a paid provider.

### Phase 4 — Screening and GPT analysis

Use deterministic screening/calculation before optional OpenAI calls. Analyze momentum, volume/liquidity/spreads, volatility/trend, filings/news, dilution/corporate actions, contradictory evidence, and microcap risks. Require structured output and validate ranges, evidence references, and risk limits in application code.

**Accept when:** no-trade is a valid result; every recommendation is explainable and tied to an immutable timestamped input snapshot; model confidence is not reported as a calibrated probability; usage, token counts, and estimated OpenAI cost are tracked.

### Phase 5 — Portfolio proposals and favorites

Support manual portfolio configuration, allocation budget, horizon, maximum idea count, screening thresholds, watchlists, and favorites. Calculate whole-share position sizes outside GPT and keep proposed trades explicitly hypothetical.

**Accept when:** sum of proposal allocations cannot exceed configured budget; favorites receive attention but never bypass safety filters; no brokerage integration exists in this phase.

### Phase 6 — Append-only journal and outcomes

Persist all generated ideas before user selection, including ignored/no-trade outcomes, source snapshots, strategy/prompt versions, validity rules, proposals, subsequent observations, simulated events, and final classification. Keep saved/favorite/ignored/paper-evaluation/expired/unfilled/completed states distinct.

**Accept when:** original recommendations are immutable; subsequent analysis creates a version; journal filters and simulated-versus-broker result separation work; fills are not inferred from a daily range without documented conservative execution assumptions.

### Phase 7 — Predeclared performance evaluation

Implement profitable trade-plan success, entry-trigger/fill quality, stop-loss quality, target quality, and overall return/risk metrics using the definitions in `PERFORMANCE_METRICS.md`.

**Accept when:** unfilled ideas count in entry-trigger statistics but not as trade wins/losses; sample size, date range, coverage and uncertainty are reported; results use the same predeclared rules and preserve failures.

### Phase 8 — Reproducible historical tests

Build chronological walk-forward and held-out backtests with strategy/prompt versioning. Document survivorship, point-in-time, delisting, corporate-action, halt, spread/slippage, and missing-news limitations. Never tune on the final test set.

**Accept when:** a run is reproducible from its stored inputs/settings; same-bar stop/target ambiguity resolves against the strategy unless finer data establishes ordering; reports distinguish historical simulation from live performance.

### Phase 9 — Optional human-confirmed Schwab integration

Only after journal and evaluation features are working, consider individual Trader API read-only functionality, then a separately gated human-confirmed order workflow. Default is paper-only. No autonomous placement, amendment, or cancellation.

**Accept when:** account data scope is minimized; long-only/cash-only restrictions are enforced outside GPT; every exact live order requires a separate explicit confirmation; broker fills/status are recorded separately; live execution is disabled by default.

### Phase 10 — Reliability and local deployment

Add backup/restore, diagnostics, secure credential storage, provider failure handling, tests, and self-hosted/local deployment documentation.

**Accept when:** secrets are absent from browser bundles/logs/source control; limits, caching, retries, and provider-disable controls are verified; recovery and offline/degraded behavior are documented; no paid hosting or external paid dependency is required.

## Ranked provider direction

1. **SEC EDGAR (filings and company facts):** official, unauthenticated public endpoints, no usage fee, fair-access requirement and a 10-request/second ceiling. Strongest free research source, but not a price feed.
2. **Schwab Trader API Individual (conditional first market-data choice):** investigate first because the user already has a Schwab account. Access is by approved individual app tied to own brokerage account; thinkorswim use does not itself grant API access or market-data entitlement. Public endpoint details/quotas must be checked in the authenticated developer portal and account.
3. **Alpaca Market Data Basic IEX (conditional fallback):** $0 Basic plan and API credentials; real-time one-exchange IEX feed, 200 historical requests/minute, and US-stock/ETF scope. Official FAQ excludes OTC market data for individual Basic accounts. It is not representative market-wide pricing and coverage must be checked per eligible listed symbol. No paid SIP fallback.
4. **Alpha Vantage free standard daily series (secondary fallback):** documented API key flow, small free daily request allowance, suitable for daily EOD research only. Intraday/realtime/delayed US intraday access is marked premium and is excluded.
5. **Bright Data Social Media Scraper API (conditional):** one API key and one provider adapter for X and/or Reddit public posts; 5,000 shared monthly free credits, no card required, and a hard stop only when the account has no deposited funds. Use a dedicated unfunded account, disable auto-recharge, never deposit money, and stop at the application quota. Social-platform terms remain a separate authorization gate; do not call it if scraping is not permitted.
6. **Issuer IR pages and SEC filing RSS/feeds:** manual/source-link fallbacks for catalysts; automate only through documented feeds/endpoints and site terms.

**Not default:** Finnhub's API docs are accessible, but current endpoint-specific free quotas, listings coverage, and data-rights terms could not be verified from its interactive documentation without an account. Massive's official bars endpoint is documented, but free Stocks Basic access is end-of-day and two-year history; verify the current account plan and exact quota/terms before implementation. Do not assume either is suitable for microcaps.

**Excluded under the strict cost rule:** direct X API is pay-per-resource; paid for reads. Direct Reddit Data API integration is not planned; Reddit's user agreement prohibits automated collection/scraping without permission. Bright Data's free tier is a real recurring 5,000-credit monthly allowance, not a time-limited trial, but free credit exhaustion may switch to paid wallet balance if funds are deposited. Google Custom Search is closed to new customers and its existing free quota is tied to billing-capable service ending 2027. Google News RSS terms restrict using bots to monitor/copy and republishing results, so it is not a default machine-ingestion source.

## Cost and operational assessment

- The only intended charge-bearing API is OpenAI, always optional and budget-limited. Its current token pricing is model-dependent and must be fetched from the official pricing page at implementation time.
- The listed free market-data plans are limited in request rate, venue coverage, history, freshness, or permissions. They do not support assuming full real-time consolidated microcap data at zero cost.
- SEC and manual issuer research are the strongest no-cost fallback; unavailable quotes mean the app must degrade to “data unavailable/no suitable trade,” not fabricate an entry.
- No external backend/hosting is assumed. Phase 1 runs fully offline. Later users can run the backend locally; any shared/self-hosted deployment remains optional and requires secure credential isolation.

## Official references

- [Flutter architecture recommendations](https://docs.flutter.dev/app-architecture/recommendations)
- [Schwab Developer Portal — individual role](https://developer.schwab.com/user-guides/individual-developer/about-individual-developer-role) (login-gated when checked)
- [Schwab Trader API — individual product](https://developer.schwab.com/products/trader-api--individual)
- [SEC EDGAR API documentation](https://www.sec.gov/edgar/sec-api-documentation)
- [SEC developer fair-access guidelines](https://www.sec.gov/developer)
- [Alpaca historical stock data](https://docs.alpaca.markets/us/docs/historical-stock-data-1)
- [Alpha Vantage API documentation](https://www.alphavantage.co/documentation/)
- [Massive custom bars API](https://www.massive.com/docs/rest/stocks/aggregates/custom-bars)
- [OpenAI API pricing](https://developers.openai.com/api/docs/pricing)
- [OpenAI structured outputs](https://developers.openai.com/api/docs/guides/structured-outputs)
