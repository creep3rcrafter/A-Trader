# A-Trader Architecture

**Reviewed:** 2026-10-10

## Starting repository

The repository is a fresh Flutter application (`a_trade`) on Flutter 3.44.2 / Dart 3.12.2. It contained only `lib/main.dart` with a counter demo, a matching `test/widget_test.dart`, the standard Flutter lint configuration, and no API, database, router, state-management, or backend packages. Git status reported no VCS roots in the IDE. Phase 1 therefore does not migrate an existing architecture.

## Phase 1 architecture

- **Presentation:** Flutter Material widgets; responsive dashboard using available width rather than a separate web/desktop implementation. Small screens use a single column; wide screens can use a constrained content grid. Large charts stay hidden.
- **State:** local widget/app state for the theme, settings, current ideas, and saved statuses. Built-in Flutter `StatefulWidget` state avoids adding a package before complexity requires one.
- **Data:** in-code fixtures explicitly named and presented as mock. There are no HTTP clients, secrets, persistence, or claims of provider connectivity.
- **Navigation:** a small dashboard/saved/history view selector plus a settings screen/dialog; preserve the current page across theme changes.
- **Tests:** widget tests use Flutter's test binding; no external API, clock, or network dependency.

## Phase 2 market-data foundation

- **Domain contract:** `lib/market_data/market_data.dart` defines provider/feed identity, source and retrieval timestamps, quote/bar fields, corporate-action adjustment metadata, and a repository interface independent of any one vendor.
- **Normalization:** the Alpaca normalizer maps the documented IEX trade, quote, and daily-bar response shapes into that contract, merges quote/trade timestamps without discarding provenance, and rejects malformed or internally inconsistent data.
- **Freshness:** quote freshness is derived from the source timestamp and caller-supplied maximum age. Delayed feeds are always marked delayed; stale and future-dated data are not treated as current.
- **Network/security:** `backend/bin/market_data_server.dart` is a loopback-only Alpaca IEX adapter. It reads credentials from server environment variables, requires explicit data-terms confirmation, forces the free IEX feed, caps outbound requests below the documented historical limit, deduplicates concurrent requests, and only enables brief in-memory caching when separately permitted. No user credential or provider request is embedded in Flutter. The mock dashboard is not wired to this backend; actual provider calls remain disabled until configuration and rights checks are complete.
- **Local service boundary:** read-only JSON endpoints expose normalized `/api/v1/market-data/quote` and `/api/v1/market-data/bars` results plus `/health`. Browser requests require a single exact configured origin; the process binds only to loopback and never exposes a LAN/public listener. Provider errors are sanitized and no paid fallback is attempted.
- **Coverage:** Alpaca Basic IEX is a single-venue source for supported US stocks/ETFs, not consolidated market data, and its standard individual plan does not provide OTC data. Unsupported and absent symbols remain unavailable; they are not replaced by fabricated or paid data.
- **Provider setup UI:** Settings accepts only a loopback service URL and calls `/health`; it never accepts or stores provider secrets. The backend reports booleans for configured credential presence, enabled state, and implementation status, without returning values. These are readiness indicators only—not provider authentication or entitlement checks. Windows environment setup and current connector limitations are documented in `LOCAL_PROVIDER_SETUP.md`.

## Target architecture when later phases are approved by the checklist

```text
Flutter UI (dashboard, settings, idea details, journal)
    -> presentation state/view models (user intent, formatting, UI loading/error state)
    -> domain services (screening, portfolio sizing, prompt validation, outcome rules)
    -> repositories (market data, research, recommendations, journal, preferences)
    -> provider adapters (Schwab/approved free feed, SEC, authorized IR/news, OpenAI)
    -> local/self-hosted backend + append-only database (credentials, scheduling, quotas, history)
```

Build only the abstractions needed for the next phase. All quantitative logic (indicators, allocation, entry/stop/target constraints, fill simulation, metrics) belongs in deterministic application code, not GPT. Provider adapters normalize to internal records while retaining provider, source timestamp, retrieval timestamp, freshness/delay, adjusted/raw status, exchange/feed, and missing-data indicators.

## Provider and data flow

1. Configuration disables providers by default and records access/limits/status without exposing API secrets to UI.
2. A scheduled or explicit user action first checks quota/cache/deduplication; disabled or exhausted providers do not receive requests.
3. Provider-specific raw responses are validated, normalized, source-stamped, and stored only when the provider permits the intended retention/use. Social collection uses one optional Bright Data adapter/key for X and/or Reddit, not direct platform API clients; it remains disabled until terms authorize collection and subsequent model processing.
4. Deterministic screening rejects incomplete, stale, illiquid, unsupported, or unsafe candidates before any OpenAI call.
5. The UI shows exactly which timestamped evidence will be sent. Optional OpenAI analysis uses only verified research and structured output; output is schema-checked and numeric constraints are revalidated.
6. Every generated recommendation and no-trade decision is journaled before user save/ignore choice. New analysis is a new version, not an overwrite.
7. Outcome evaluation uses future observations only after the original plan is sealed and uses conservative execution assumptions.

## Security and privacy

- No third-party API credentials in Flutter Web, source control, mock data, or logs. A local secure store may protect personal desktop/mobile credentials only if its threat model is documented; a backend is needed for multi-user/shared automation.
- Never put OpenAI or Schwab secrets into app assets, build-time public defines, URL query parameters displayed in logs, or prompt previews. Redact headers/tokens and account identifiers in diagnostic output.
- Browser requests to providers with CORS restrictions are not a reason to expose a credential or proxy through an untrusted public endpoint. Use a local/self-hosted backend or disable the feature.
- OpenAI API data is not used for model training by default, but abuse-monitoring retention can be up to 30 days by default; Zero Data Retention requires eligibility/approval. Send minimal data and avoid personal account details.
- Provider retention/display/AI processing rights must be verified before storing market data or forwarding it to OpenAI. SEC/issuer public text still requires provenance and ordinary copyright/terms review.
- Live brokerage capability is out of scope through Phase 8. A later brokerage integration must enforce paper-only default, long-only/cash-only restriction, human confirmation, and no autonomous order lifecycle actions in backend logic.

## Persistence plan

Phase 1 is intentionally in-memory and resets on app restart. Phase 5+ preferences may begin with local storage, but recommendations/outcomes require durable append-only storage and backups. Prefer a local self-hosted service/database with migrations and export/restore over paid hosting. Retain references or normalized permitted facts rather than copying licensed data when terms do not allow storage. Exact database choice is deferred until journal schema and single-device/multi-user needs are established.

## Major decisions

- No third-party package added for Phase 1; the starter app has no state complexity justifying a framework.
- No navigation/router or persistent data package added until multiple screens or persistence require it.
- No real provider integration during Phase 1; mock fixture presentation is explicit.
- Phase 2's initial change adds tested market-data contracts and response normalization only; it does not enable provider requests before credentials, entitlements, and data-use terms are verified.
- The settings connection check is deliberately loopback-only and checks backend environment-variable presence, not third-party connectivity. Alpaca requests remain separately gated by credentials and terms confirmation; all other planned connectors remain unimplemented.
- Social-media provider choice is Bright Data only, subject to written/terms-based permission for any platform collection; no direct X or Reddit API clients. Use a dedicated unfunded account, disable auto-recharge, enforce a local allowance below 5,000 shared monthly credits, and stop at quota exhaustion.
- Schwab is researched first but not assumed accessible merely because the user uses thinkorswim.
- OpenAI is the sole planned paid API. All other providers must have durable usable free access or stay disabled.
- “No suitable trades” and unavailable data are first-class results; never fill candidate slots with invented market data.
