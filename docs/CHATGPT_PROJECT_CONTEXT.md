# A-Trader: Context for Planning the Next Development Step

**Snapshot date:** 2026-10-12
**Purpose:** Give ChatGPT enough accurate context to write a focused implementation prompt for the coding assistant working in the existing repository.

## What I want ChatGPT to do

Read this document and help me choose the next small, complete development increment. Then write a copy-and-paste prompt for my coding assistant.

The prompt should specify scope, dependencies, acceptance criteria, tests, documentation updates, and what must remain out of scope. Tell the coding assistant to inspect the current repository first: work may have progressed since this snapshot. Do not describe planned or partially implemented features as finished.

Do not generate a replacement application or ask for my API keys. Prefer completing and verifying the current local-model tools before starting a large discovery pipeline.

## Product and intended outcome

**A-Trader** is a private, non-commercial AI-assisted microcap swing-trading research application for me and a few other users. I use Charles Schwab thinkorswim, but there is no implemented Schwab integration.

Eventually, the application should:

- Discover relevant stocks from permitted, current research instead of a fixed watchlist.
- Evaluate buying momentum, volume/liquidity, volatility, catalysts, favorable and unfavorable articles, filings, dilution, and other risks.
- Rank opportunities for my selected holding period using explainable factors, not invented probabilities.
- Produce realistic hypothetical entry, stop-loss, target, and position-size values calculated and validated in ordinary code.
- Record every recommendation, including ignored ideas and no-trade decisions, and evaluate subsequent hypothetical outcomes conservatively.

Flutter Web, Windows desktop, and mobile are target platforms. Recent compilation and launch work primarily covers Web; this is not evidence of complete cross-platform deployment.

## Non-negotiable constraints

- **OpenAI is the only API provider allowed to incur charges.** It is optional. Every other external API must have legitimate, usable permanent-free access.
- No paid trials, billing-enabled default fallbacks, paid market feeds, quota-overrun charges, prohibited scraping, or access-control bypasses.
- Verify official API documentation, actual endpoint schemas, quotas, authentication, and display/retention/model-processing rights before integrations.
- Keep credentials server-side and out of browser bundles, source control, logs, and model prompts.
- Never fabricate prices, catalysts, citations, outcomes, trade levels, or confidence statistics.
- Missing, stale, delayed, or unavailable data must be visible. "No suitable trades" is a valid result.
- Quantitative screening, risk controls, trade levels, allocation, and outcome calculations belong in deterministic code. Models interpret sourced evidence.
- No autonomous order placement, modification, or cancellation. Current scope is research and hypothetical trading only.
- Never claim an 85% win rate or a calibrated chance of profit without adequate out-of-sample evidence.
- Reuse the existing code, minimize dependencies, implement small testable increments, and conserve coding-assistant usage.

## Current repository and architecture

- Repository: `creep3rcrafter/A-Trader`.
- Windows workspace: `C:\Users\brend\a_trade`.
- Flutter SDK command: `C:\Users\brend\FlutterSDK\flutter\bin\flutter.bat`.
- Dart command: `C:\Users\brend\FlutterSDK\flutter\bin\dart.bat`.
- Previously audited Flutter 3.44.2 / Dart 3.12.2; verify current versions before relying on them.
- Frontend: responsive Flutter Material UI, built-in widget/app state, Ideas/Saved/History navigation and Settings. No large state-management framework.
- Backend: local Dart HTTP service, provider adapters, server-side configuration, request validation, quota controls, and sanitized errors.
- HTTP clients use `package:http`; market records have provider/feed identity, source and retrieval timestamps, and coverage/freshness metadata.
- Most application preferences and saved ideas remain in memory. There is no recommendation database or append-only journal.
- Existing work is in the working tree; do not reset unrelated changes or commit/push unless requested.

## Implemented features

### Market data and Ideas

Alpaca Basic IEX is the explicitly selected default provider. Twelve Data Basic is optionally selectable. Credentials and separate permission confirmations are required; provider errors do not silently switch providers.

Quote and daily-bar adapters normalize and validate responses. Alpaca uses a free single-exchange IEX feed, not consolidated market-wide data or NBBO; individual Basic coverage does not include OTC securities. Twelve Data has conservative local free-quota limits and durable quota state.

Ideas currently loads ten **temporary, unscreened** stocks:

`SOFI`, `RKLB`, `BBAI`, `MVIS`, `OCGN`, `SENS`, `GEVO`, `FCEL`, `ONDS`, `KULR`.

Cards show latest-available prices, provider/feed, timestamps, freshness, coverage, and expandable quote details. They are not automatically selected microcaps or ranked trade recommendations. Saved is session-only; History has no fabricated outcomes. Mock production ideas and the manual Market data research screen were removed at my request.

Refresh is explicit; there is no continuous polling. Twelve Data requests are paced, and quota/configuration/transport failures stop remaining requests.

**Verification boundary:** fixture tests and builds passed, but this snapshot does not establish that my saved credentials currently authenticate successfully, that every ticker has live coverage, or that my account permits every proposed data use. Settings health checks show configuration/readiness, not actual provider authentication.

### Local AI and optional OpenAI

Explicit **Ask AI** actions provide quote-only explanations. They do not discover stocks or generate validated trade plans.

- LM Studio OpenAI-compatible server: `http://127.0.0.1:1234/v1`.
- Default local model: `google/gemma-4-e4b`.
- Existing explanation routing uses OpenAI when its key is configured, otherwise LM Studio. Errors do not cause silent fallback.
- Assistant enablement, model-forwarding permission, and LM Studio local-only confirmation are required.
- LM Link/remote routing must be disabled for the local-only path.
- Prompt/output sizes, concurrency, call counts, and timeouts are bounded.
- Current call accounting is process-lifetime, not durable monthly cost tracking.

LM Studio model listing was reachable. That alone does not verify successful inference or native function/tool calling.

### Persistent credentials and local/LAN launch

Private configuration is encrypted with Windows current-user DPAPI in ignored `.local` storage. Launch scripts reload it so keys do not need to be entered at every start.

Development mode uses two processes:

```powershell
.\scripts\start_backend.ps1
.\scripts\start_web.ps1
```

The frontend uses `http://localhost:3000`; the backend uses `http://127.0.0.1:8765` with the matching allowed browser origin.

Trusted-private LAN mode builds and serves Web and APIs together on port 3000:

```powershell
.\scripts\start_lan.ps1 -AcknowledgePrivateNetworkOnly
```

Stop another server using port 3000 first. Keep LM Studio running for local AI.

LAN mode has password login, expiring sessions, login throttling, Host/Origin validation, and separate provider display-permission gates. Passwords require at least 12 characters with no character-class requirement.

**LAN HTTP is unencrypted.** Trusted private network only; no router forwarding or Internet exposure. No automatic firewall changes. Cross-device login/data/model access still needs verification.

## Current unfinished increment: local research tools

My latest instruction was:

> start by just making the tools for the local model and test that out and if we need searxng we can add it later.

The intended first tools are bounded, read-only:

| Tool | Purpose |
|---|---|
| `get_market_quote` | Retrieve a validated quote for the requested ticker. |
| `get_daily_bars` | Retrieve bounded daily price/volume history. |
| `get_sec_filings` | Retrieve recent SEC filing metadata, not arbitrary documents or web pages. |

The frontend **Research with local tools** action and client are implemented. They submit one ticker, the configured holding horizon, and a default seven-calendar-day research lookback. The UI renders executed tools, limitations, source URLs, publication dates where available, and retrieval times.

Expected route:

`POST /api/v1/assistant/research`

Expected request fields:

`symbol`, `prompt`, `holdingDays` (1-365), `lookbackDays` (1-30; default 7).

Expected response fields:

`explanation`, `provider: "lmstudio"`, `model`, `sources`, `toolsUsed`, `limitations`.

Each source has an HTTPS `url`, `title`, nullable `publishedAt`, and timestamped `retrievedAt`. The frontend rejects malformed metadata, unsafe URLs, and undeclared tools.

**Backend implementation was delegated and its completed result had not been received at this snapshot.** Do not assume the endpoint, tool loop, SEC configuration, or real-model experiment is finished. The coding assistant should reconcile the current implementation first.

Requested backend safeguards include:

- Local-only research, even if an OpenAI key is configured; no surprise paid calls.
- At most three model turns and four tool executions, with each actual model request charged against the shared process call budget.
- Exact validated arguments; tools limited to the requested ticker.
- SEC permission gate, identifying User-Agent, bounded dates/results, and conservative rate limiting.
- Explicit unavailable results when configuration or data is missing.
- Backend-owned evidence references; no invented source URLs.
- No shell, arbitrary URL browsing, credential, social, news, or order tools.
- A real LM Studio native-tool-call experiment using clearly synthetic quote fixtures, without live provider credentials or SEC requests.

Latest parent-side validation: 37 targeted frontend tests passed; analysis and a same-origin Web build passed before a final metadata-validation adjustment, whose 16 assistant-client tests then passed. Final integrated backend/frontend validation remains outstanding. Earlier integrated pre-tool work passed 141 tests. Do not treat either count as proof that the unfinished backend tools work.

## Known gaps and requested improvements

1. **Freshness presentation:** quotes older than one minute are marked stale. Overnight/weekend last trades and sparse IEX trades can therefore all appear stale. Add accurate market-session/last-available context eventually; never relabel old prices as live. An authoritative calendar/session source has not been implemented.
2. **No dynamic discovery:** the fixed ten-stock list remains. No permitted news/search-based candidate discovery exists.
3. **No article or social ingestion:** there are no working web-search, article-reading, or public-social tools.
4. **No opportunity ranking:** momentum, volatility, liquidity, catalysts, dilution, and contradictory evidence are not combined into a validated ranking.
5. **No trade-plan engine:** deterministic entry/stop/target/sizing calculations are not implemented.
6. **No durable research/recommendation journal:** evidence snapshots, versions, all generated ideas, and outcome events are not persisted.
7. **No performance engine:** realistic fills, slippage, gap behavior, same-bar ambiguity, metrics, and walk-forward backtesting remain planned.
8. **No brokerage integration:** Schwab access/entitlements need verification; no orders are sent.

## Search and source-provider direction

I initially considered Bright Data, then suggested SearXNG with local-model/GPT tools for news, articles, SEC filings, and public discussion. The current decision is **tools first; SearXNG only if needed later**.

Bright Data is not integrated and should not be made a dependency of the next increment. Any future use requires verified recurring-free eligibility, a hard no-paid-overrun configuration, and source collection/model-processing permissions.

SearXNG is not running or integrated. Self-hosting does not grant rights to scrape or republish upstream content. Its search JSON format must be enabled; time filters do not guarantee exact seven-day publication dates. Search results are not article contents or proof of a catalyst.

SEC is the preferred initial free filing source. Proposed endpoints are the SEC ticker/CIK mapping and submissions JSON. Official SEC documentation requests returned HTTP 403 during the latest research attempt; this was not bypassed. Live SEC access, identifying User-Agent setup, and actual filing retrieval remain unverified at this snapshot.

## Relevant code and maintained documents

| Path | Role |
|---|---|
| `lib\main.dart` | App state, Settings, navigation, configured holding horizon. |
| `lib\market_data\live_ideas_view.dart` | Temporary quotes, Saved state, Ask AI and research UI. |
| `lib\market_data\market_data.dart` | Provider-neutral quote/bar models. |
| `lib\market_data\local_market_data_service.dart` | Validated backend market-data client. |
| `lib\providers\assistant_service.dart` | Explanation/research client and evidence validation. |
| `lib\providers\local_service_url.dart` | Loopback/exact same-origin URL boundary. |
| `backend\lib\assistant.dart` | Model clients, permission gates, bounded explanations. |
| `backend\lib\server.dart` | HTTP routes, authentication, browser/static protections. |
| `backend\bin\market_data_server.dart` | Backend configuration and service wiring. |
| `scripts\setup_local.ps1` | Private configuration setup entry point. |
| `scripts\start_backend.ps1`, `scripts\start_web.ps1`, `scripts\start_lan.ps1` | Launch modes. |
| `test\assistant_service_test.dart`, `test\live_ideas_widget_test.dart` | Frontend research/client behavior. |
| `test\backend_server_test.dart` | Server/authentication/assistant behavior. |
| `docs\PROJECT_ROADMAP.md` | Long-term phases and acceptance criteria. |
| `docs\IMPLEMENTATION_CHECKLIST.md` | Verified versus outstanding implementation tasks. |
| `docs\DATA_PROVIDER_RESEARCH.md` | Official sources, free access, quotas and restrictions. |
| `docs\ARCHITECTURE.md` | Current and target architecture and boundaries. |
| `docs\PERFORMANCE_METRICS.md` | Exact outcome and evaluation definitions. |
| `docs\LOCAL_PROVIDER_SETUP.md` | Configuration, permissions and launch instructions. |

Historical Phase 1 descriptions in the maintained documents refer to an earlier mock-only implementation. Use their dated updates and actual code to establish current behavior.

## Suggested structure for the next coding prompt

Ask the coding assistant to:

1. Inspect the in-progress research implementation and confirm what is actually complete.
2. Finish and verify the bounded local tool loop and its frontend contract before expanding scope.
3. Demonstrate an actual native LM Studio tool request, server execution, and follow-up response. Clearly distinguish synthetic fixtures from authorized real market/SEC research.
4. Test disabled permissions, unavailable inputs, malformed arguments, tool/turn budgets, unsafe citations, and model/provider failures.
5. Update setup instructions and the implementation checklist to match verified behavior.
6. Run the relevant formatter, analyzer, tests, and Web build; report actual blockers without claiming success.

After that increment is verified, propose one bounded next phase toward evidence-based discovery/ranking. Identify what free, permitted sources and deterministic calculations it needs. Do not bundle web/social ingestion, stock discovery, trade plans, journaling, and backtesting into one rewrite.
