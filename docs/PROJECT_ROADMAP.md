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

### Phase 0 — Audit and provider research

Deliver five maintained documents: this roadmap, implementation checklist, provider research, architecture, and performance metric definitions.

**Accept when:** the baseline and tradeoffs are recorded; sources are official where available; every provider recommendation states free access, constraints, and unresolved checks; a ranked free-provider set and exact phase checklist exist.

### Phase 1 — Responsive Flutter interface (current implementation)

Implement a dashboard of clearly labelled synthetic stock ideas; top-right settings; expandable evidence, indicators, and risks; mock Ask GPT Why; saved ideas and outcome-history view; configurable portfolio/risk settings, favorites, theme, prompt editor and preview, and clearly mock provider statuses.

**Accept when:** mobile/narrow and desktop/wide layouts remain usable; theme changes apply immediately; save/favorite/settings/prompt interactions work; mock data cannot be mistaken for live data; tests cover the primary interactions; no network requests, order placement, or persistence are present.

### Phase 2 — Free market-data layer

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
