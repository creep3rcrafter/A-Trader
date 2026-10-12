# Local Provider Setup

**Status:** Settings checks credential presence only. The backend quote/bar routes can make actual requests after credential and terms configuration; Settings is not a provider connection test.

Provider credentials must stay in private server-side configuration and the backend process environment. Never paste them into Flutter settings, browser storage, source files, build arguments, or issue logs. The Settings screen's **Check local connections** action calls `/health` through loopback in development or the authenticated same-origin LAN server. It does not authenticate with providers, verify an account, or confirm data entitlements.

## One-time private configuration

From the project root run `.\scripts\setup_local.ps1`. Enter keys using its private prompts, confirm only permissions you have actually reviewed, choose an installed local model and set a strong LAN password. Subsequent launch scripts load the Windows user-bound encrypted configuration; keys need not be re-entered for every run. Re-run setup when keys rotate or permissions change. Existing process environment values override saved defaults.

The LAN password requires at least **12 characters**, with no uppercase, number, symbol or character-mix rules. Characters and spaces are preserved exactly; choose something difficult to guess. Leaving the setup password blank keeps LAN hosting disabled.

Encryption protects the saved file at rest under the same Windows user account; it does not protect against malware or other processes running as that user. Do not copy decrypted credentials into logs or source control. The encrypted file is machine/user-bound rather than a portable credential backup. Rotate any keys previously pasted into documents or shared output.

Saved configuration is `.local\private_config.dpapi`. Re-run setup and type `REPLACE` when prompted to replace existing values. To remove saved credentials, delete only that file, stop the server and close the credential-bearing PowerShell session; deleting the file does not clear a running process or separately configured environment variables. Setup never starts a server or creates a scheduled task.

## Password-protected LAN web mode

Run `.\scripts\start_lan.ps1 -AcknowledgePrivateNetworkOnly` instead of separate web/backend development launchers. It builds the web app with `A_TRADER_SAME_ORIGIN=true` and serves both web content and APIs on port **3000**. Stop any Flutter development server using that port first. Other devices use the host computer's printed LAN URL and sign in with the setup password; their `localhost` is not the host computer, so no client-side loopback backend address should be entered.

Keep both provider credentials and LM Studio on the host computer. Review provider rights before shared/device display; a personal research flag is not a shared production entitlement. Login protection does not grant market-data rights.

LAN hosting requires `A_TRADER_AUTH_PASSWORD`. Quotes additionally require `ALPACA_LAN_DISPLAY_TERMS_CONFIRMED=true` or `TWELVE_DATA_LAN_RIGHTS_CONFIRMED=true`, independent of each provider's existing terms gate. Do not confirm rights you have not verified. Defaults permit only localhost/loopback and current server-interface IP origins on the serving port; `A_TRADER_LAN_ORIGINS` can replace these with comma-separated exact HTTP origins. Restart after network/IP changes. Unauthorized API requests return HTTP 401; sessions expire 24 hours after login (not sliding) and login attempts are throttled. Logout or server restart invalidates sessions sooner.

### Explicit temporary public HTTP testing

This is an insecure testing exception, **not HTTPS or production deployment**. The default LAN launcher still disallows public hosting guidance. `scripts\start_public_test.ps1 -PublicIp YOUR_PUBLIC_IP -AcknowledgeUnencryptedPublicTesting` builds and starts the same password-authenticated web/API server on port 3000 with an exact allowlist for that public IP and loopback. No authentication, Origin or provider permission checks are disabled. Stop other port-3000 servers first. The script restores its deployment environment overrides on exit.

Passwords, bearer session cookies and displayed/provider/model data are unencrypted and can be intercepted even when no personal data is stored. Use a unique temporary password, rotate it afterward, avoid sensitive data and paid AI, and stop promptly after testing. A 24-hour session is not a 24-hour hosting limit. The app does not create firewall rules, forward router ports, verify ownership of the IP, or establish external reachability; CGNAT/ISP/router restrictions may prevent access. Remove any manually configured forwarding/firewall exception when finished. For normal outside-home use, provision a publicly trusted HTTPS certificate/reverse proxy or use a private encrypted connection; do not treat this flag as a security fix.

**Network safety:** this launch mode uses HTTP on a trusted private LAN, not encrypted Internet hosting. Passwords and session cookies are not protected from network interception without HTTPS. Do not forward the port in your router, use public Wi-Fi, or create a broad Public-profile firewall exception. If Windows prompts, restrict permission to a Private network/local subnet. External/untrusted access requires a separately configured HTTPS reverse proxy or private VPN, not disabling login/CORS.

## Local LM Studio fallback

Start LM Studio's local developer server on the host computer at `http://127.0.0.1:1234`. Use a downloaded model such as `google/gemma-4-e4b` and select its exact server model ID during private setup. The server's `/v1/models` endpoint lists available models, but listing alone does not prove generation succeeds. Keep LM Studio loopback-only; do not expose it directly to the network or substitute a hosted model provider.

`LM_STUDIO_BASE_URL` defaults to `http://127.0.0.1:1234/v1`; `LM_STUDIO_MODEL` defaults to `google/gemma-4-e4b`. Optional `LM_STUDIO_API_TOKEN` authenticates the local server if enabled. Disable LM Link/remote routing, then confirm `LM_STUDIO_LOCAL_ONLY_CONFIRMED=true`: localhost alone does not prove inference is local. Advertised remote models are rejected.

When no OpenAI key is configured, the assistant selects local LM Studio. Local-model failures never silently spend money through OpenAI; provider errors remain explicit. Analysis also requires explicit enablement and separate confirmation that your market data may be processed by the model. Local inference does not waive provider restrictions.

Both paths require `A_TRADER_ASSISTANT_ENABLED=true` and `A_TRADER_MODEL_FORWARDING_TERMS_CONFIRMED=true`. When an OpenAI key is present, `OPENAI_MODEL` defaults to `gpt-5-mini`; configure account budgets before enabling paid requests. Default per-process assistant limits are ten calls, two concurrent calls, 4000 prompt characters, 512 output tokens and a 45-second model timeout. Override with `A_TRADER_ASSISTANT_MAX_CALLS`, `A_TRADER_ASSISTANT_MAX_CONCURRENT`, `A_TRADER_ASSISTANT_MAX_INPUT_CHARS`, `A_TRADER_ASSISTANT_MAX_OUTPUT_TOKENS` and `A_TRADER_ASSISTANT_TIMEOUT_SECONDS`. Restarting resets these process call counts; durable monthly cost accounting is not implemented.

On a stock card, **Ask AI** sends the saved prompt and ticker to the backend, which fetches verified quote context. It explains limitations only; news, fundamental screening, entry/stop calculation, persistent recommendation records and measured performance are not implemented. No model request occurs merely by loading the page. A missing LM Studio server/model reports unavailable, never a fabricated answer.

## Environment variable names

Configure only credentials for providers you are authorized to use:

| Provider | Backend variable names | Current status |
|---|---|---|
| Twelve Data Basic | `TWELVE_DATA_API_KEY` | Explicitly selectable for local research/testing. Calls also require `TWELVE_DATA_RESEARCH_TERMS_CONFIRMED=true`. No shared display, paid add-ons, WebSocket trial, raw-data storage, or GPT forwarding. |
| Alpaca market data | `ALPACA_API_KEY_ID`, `ALPACA_API_SECRET_KEY` | Quote/bar adapter implemented; calls also require `ALPACA_MARKET_DATA_TERMS_CONFIRMED=true`. The app currently reports readiness, not successful provider authentication. |
| Schwab Trader API | `SCHWAB_CLIENT_ID`, `SCHWAB_CLIENT_SECRET` | Presence detection only. App approval, entitlements, OAuth, and adapter remain unverified/unimplemented. |
| Alpha Vantage | `ALPHA_VANTAGE_API_KEY` | Presence detection only; connector not implemented. |
| Bright Data | `BRIGHT_DATA_API_TOKEN` | Presence detection only; connector remains disabled pending applicable permissions and terms. |
| OpenAI | `OPENAI_API_KEY`, `OPENAI_MODEL` | Optional paid quote explanations through Responses API; enablement and model-forwarding permission required. No error-driven fallback. |
| LM Studio | `LM_STUDIO_BASE_URL`, `LM_STUDIO_MODEL`, optional `LM_STUDIO_API_TOKEN` | Local quote explanations when OpenAI key absent; local-only confirmation, assistant enablement and model-forwarding permission required. |
| SEC EDGAR | `SEC_USER_AGENT`, `A_TRADER_SEC_TERMS_CONFIRMED` | Bounded recent filing metadata only; no API key, identifying contact and explicit permissions required. Live access remains unverified. |

The backend also accepts `A_TRADER_MARKET_DATA_PROVIDER` (`alpaca` by default, or explicitly `twelveData`), `A_TRADER_PORT` (default `8765`), and `A_TRADER_ALLOWED_ORIGIN` for the exact development Flutter Web origin. Development browser requests are rejected unless that origin is configured. Development mode binds to loopback; the explicit password-protected LAN launcher uses port 3000 with same-origin requests and Host/Origin validation. Do not expose or forward either mode to the public Internet. Providers are never switched automatically on errors.

## Windows setup

Development Flutter Web uses the fixed origin `http://localhost:3000`; the backend listens separately at `http://127.0.0.1:8765`. From the project root run `.\scripts\start_web.ps1` for Chrome. In another PowerShell session run `.\scripts\start_backend.ps1`; it loads saved private configuration, sets `A_TRADER_PORT=8765` and `A_TRADER_ALLOWED_ORIGIN=http://localhost:3000`. Setup alone stores credentials and confirms permissions; launch does not silently accept terms. Stop existing instances before restarting; do not change ports to bypass an occupied listener. The IDE `main.dart` configuration pins the same Flutter Web port.

Set the variables in the environment of the PowerShell process that will run the backend, then start or restart the local service from the project root. For a safer setup, use a local secret manager or Windows environment-variable settings rather than typing secret values into shell commands; ordinary environment variables are still accessible to processes running as your user.

For Alpaca, leave `ALPACA_MARKET_DATA_TERMS_CONFIRMED` unset until you have reviewed and accepted the provider's current data-use terms. Leave `ALPACA_DATA_CACHING_PERMITTED` unset unless the intended caching is permitted. Credentials alone do not enable requests.

Open Flutter **Settings → Research & data providers**, confirm the local service URL is loopback (for example, `http://127.0.0.1:8765`), then choose **Check local connections**. A positive credential-presence result means only that the backend process received a non-empty environment variable. It does not establish valid credentials, approval, API access, entitlements, or a successful provider response.

## Alpaca IEX setup (default)

Alpaca requires **both** the API key ID and its secret key. Keep the account on free Basic; this adapter only uses market-data routes, never brokerage/order routes. Enter credentials privately in the PowerShell session that starts the backend:

```powershell
Set-Location 'C:\Users\brend\a_trade'
$key = Read-Host 'Alpaca API key ID' -AsSecureString
$secret = Read-Host 'Alpaca API secret key' -AsSecureString
$env:ALPACA_API_KEY_ID = [System.Net.NetworkCredential]::new('', $key).Password
$env:ALPACA_API_SECRET_KEY = [System.Net.NetworkCredential]::new('', $secret).Password
$key.Dispose()
$secret.Dispose()
Remove-Variable key, secret
$env:A_TRADER_MARKET_DATA_PROVIDER = 'alpaca'
# Set only after reviewing the account's applicable market-data terms:
$env:ALPACA_MARKET_DATA_TERMS_CONFIRMED = 'true'
.\scripts\start_backend.ps1
```

Leave `ALPACA_DATA_CACHING_PERMITTED` unset unless permitted. Stop the server and remove the credential environment variables when finished. Settings can confirm presence, but only an authorized quote/bar request verifies authentication. IEX is a single-venue feed, not consolidated prices or volume, and OTC data is excluded.

## Twelve Data research/testing setup (explicit selection)

Stay on **Basic Free** and obtain the key from <https://twelvedata.com/account/api-keys>. Do not paste it into chat. The following PowerShell example prompts privately rather than saving the literal key in shell history:

```powershell
Set-Location 'C:\Users\brend\a_trade'
$key = Read-Host 'Twelve Data API key' -AsSecureString
$env:TWELVE_DATA_API_KEY = [System.Net.NetworkCredential]::new('', $key).Password
$key.Dispose()
Remove-Variable key
$env:A_TRADER_MARKET_DATA_PROVIDER = 'twelveData'
# Set only after reviewing the account terms for personal research/testing:
$env:TWELVE_DATA_RESEARCH_TERMS_CONFIRMED = 'true'
.\scripts\start_backend.ps1
```

Environment values are still readable by processes running as your user; use a trusted local session. Stop the server and remove `TWELVE_DATA_API_KEY` from that session when finished. No `.env` parser is used; creating an `.env` file does not configure this process.

In a second PowerShell terminal, test through the local service (no key in these URLs):

```powershell
Invoke-RestMethod 'http://127.0.0.1:8765/health'
Invoke-RestMethod 'http://127.0.0.1:8765/api/v1/market-data/quote?symbol=AAPL'
Invoke-RestMethod 'http://127.0.0.1:8765/api/v1/market-data/bars?symbol=AAPL&start=2026-10-01&end=2026-10-09&adjustment=raw'
```

These are real data requests, one credit per symbol per endpoint, not recommendations or orders. Compare the source date/time and coverage metadata; quote prices are minute-candle values from a partial-volume feed, not guaranteed executable prices. OTC, premium endpoints and pre/post data are excluded. Daily bars use exchange-local trading dates. Ideas automatically requests ten temporary stocks on load, pacing subsequent Twelve Data calls eleven seconds apart. Refresh requests another run; quota/configuration failures stop remaining requests with errors. The manual lookup/history UI and mock data have been removed.

Local quota counters (no key or raw data) live under ignored `.local`; do not delete them to bypass free limits. Sharing a key with other apps consumes provider quota too. Basic allows 8 credits/minute and 800/day; this service caps requests at **7 per rolling minute and 750 per UTC day**, persists reservations before sending, and stops on quota errors instead of upgrading or auto-retrying. A provider 429 conservatively pauses requests until the next UTC day because its error may indicate either daily or minute exhaustion.

Basic pricing currently says **internal non-display usage**. Personal research/testing does not imply permission to redistribute data to friends or display it in a production/shared dashboard. Verify free display, retention and GPT-processing rights before those features; no paid entitlement is assumed.

## Research with local tools

Use the existing card action **Research with local tools**, not Ask AI, for bounded quote, daily-bar, recent-SEC-metadata and deterministic-indicator evidence. This route is **LM Studio only even with an OpenAI key present**. It requires the existing assistant enablement, model-processing and local-only confirmations. Market credentials/terms and LAN display permission stay independently gated; missing data is reported, not replaced.

The request allows a 1-30 calendar-day lookback and 1-365 day hypothetical holding horizon. Daily bars exclude the unfinished current calendar day and are not an indicator engine. Up to three model turns/four tool executions consume the shared assistant limits; a three-turn research action costs three process calls, not one. The default ten-call cap resets only with a server restart; it is not durable cost accounting. No SearXNG, Bright Data, arbitrary browsing or brokerage tools are present.

SEC is default-deny. Re-run private setup to record reviewed permissions and an honest identifying User-Agent (application name plus your actual contact email), or set `A_TRADER_SEC_TERMS_CONFIRMED` and `SEC_USER_AGENT` privately in the backend launch environment. Never use a placeholder email for live access. The metadata adapter issues at most two fixed-endpoint requests per invocation, one second apart, and limits the shared client to ten requests per rolling minute. 403/429 causes at least a one-minute cooldown (longer valid `Retry-After` is honored). Responses are bounded to 8 MiB for the ticker map and 2 MiB for submissions. Each request has separate ten-second send/body timeouts; timeout reporting does not guarantee underlying HTTP cancellation. It does not download filing contents or bypass source restrictions. A filing date is not a news publication or trading signal. These setup flags do not establish that live access succeeds.

### Repeatable native LM Studio verification

From the repository root, after confirming LM Link/remote routing is disabled and local/model processing is permitted:

```powershell
. .\scripts\private_config.ps1
Import-ATraderPrivateConfig
$env:A_TRADER_NATIVE_TOOL_SMOKE = 'true'
& 'C:\Users\brend\FlutterSDK\flutter\bin\flutter.bat' test --no-pub test\research_tools_test.dart --plain-name 'real LM Studio native tool cycle with synthetic quote only' --reporter expanded
Remove-Item Env:\A_TRADER_NATIVE_TOOL_SMOKE
```

This test uses the configured model/endpoint and optional local authentication token, but no market API credentials or SEC network calls. `SYNTH` and price `17.375` are **synthetic fixtures, not an actual security/quote**. It requires a native `tool_calls` request, backend execution, a linked tool-result message on the subsequent real model call and a final synthetic explanation containing the fixture value. A failure/no native call is a blocker, not proof of capability. Ordinary tests skip this opt-in test and simulate model HTTP responses instead.

**Verified in this increment (2026-10-12):** the configured `google/gemma-4-e4b` requested `get_market_quote`, the backend executed one validated synthetic lookup, and the next actual LM Studio request included its linked tool result. Two model turns produced: "The exact fixture lastPrice is 17.375 and it is synthetic, not live." The native smoke test passed in approximately six seconds. This establishes one native quote cycle for that configuration, not live data/SEC access, correctness of general financial interpretations or reliability for every prompt/model.

The indicator follow-on also passed **`real LM Studio native indicator tool cycle with synthetic daily history`** using the same configured model. Run both native tests by replacing the selector above with `--plain-name 'real LM Studio native'`. Both passed together in approximately 22 seconds: synthetic history only, disabled SEC, no live market or OpenAI calls. Native capability for these fixtures does not establish investment quality or reliability for arbitrary prompts.

### Daily indicator card and tool

After restarting the backend and loading the updated frontend, choose **Calculate daily indicators** on a quoted stock card. It sends `GET /api/v1/market-data/indicators?symbol=...` and consumes the configured provider's normal free history quota; it never calls a model. No indicator history is automatically fetched on load. Existing provider permissions, credentials, authentication and LAN display gates still apply. The same calculation is available to LM Studio as the symbol-only `get_technical_indicators` tool within the existing three-turn/four-tool budget.

Defaults are 20-session SMA/EMA, one-session SMA trend lag and 14-delta Wilder RSI. One raw history fetch is bounded to 120 calendar days/records, with five-minute retrieval freshness. A static regular US-equity calendar covers 2025–2030 and known regular holidays/the Carter closure; conservative 06:00 UTC availability proxies are not authoritative exchange closure/timezone conversion. Unsupported dates or missing expected bars are reported explicitly. Recursive EMA/RSI require the entire supplied seed history, unlike trailing-window metrics. Source dates/timestamps come only from validated completed bars.

Raw arithmetic indicators can be distorted by unverified corporate actions; raw close returns remain unavailable without explicit comparability confirmation. Missing data is not a neutral value, and displayed indicators are not trade signals. MACD, ATR/volatility, liquidity checks and opportunity scoring remain unfinished.

## Current limits

- The deterministic indicator engine needs no new API or credentials. The explicit **Calculate daily indicators** card action fetches bounded history through the already configured market-data adapter and consumes that provider's normal free quota, but makes no AI request. Indicators are not fetched merely by loading cards. Research's `get_technical_indicators` tool uses the same code-computed results and requires the existing local model-processing gates; it does not add quantitative model authority.

For code consumers, `DailyIndicatorEngine.calculate` accepts already retrieved bars and `DailyIndicatorConfig`. Supply the requested identity/adjustment, UTC `analysisCutoff`, date-only `latestCompletedSessionDate`, `maximumRetrievalAge`, session-count `lookback` and optional `expectedSessionDates`. Without expected dates, metrics report `coverageUnverified` (empty input reports insufficient data). Missing sessions in a metric's required window report incomplete coverage; older gaps outside that window do not suppress an otherwise valid metric. `corporateActionComparabilityConfirmed` defaults to false for raw-price returns. Invalid configuration/series fails validation; unavailable calculations carry reasons instead of fabricated numbers. This configuration is not a provider entitlement or verification of corporate actions.

- The settings form intentionally has no API-key input and does not save secrets.
- Gated Twelve Data and Alpaca IEX quote/daily-bar adapters are implemented; credentials for the other listed providers do not activate integrations.
- Schwab access is not assumed from thinkorswim usage; wait for app approval and verify market-data entitlements in the official portal.
- This status check performs no market-data, news, filing, social, or OpenAI request.
- No provider may silently fall back to a paid tier or service.
