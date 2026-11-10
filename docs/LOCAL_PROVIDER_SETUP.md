# Local Provider Setup

**Status:** Settings checks credential presence only. The backend quote/bar routes can make actual requests after credential and terms configuration; Settings is not a provider connection test.

## Automatic status and Windows desktop backend controls

Settings checks the selected local service immediately and every **30 seconds**
while that screen is open, on every platform. The circle is neutral while
checking, green with a checkmark for a valid `/health` response, or red with an X
and an explanation when unreachable/invalid/unauthorized. Requests do not overlap;
editing the URL discards stale results, and closing Settings cancels polling.
These checks do not request quotes, invoke a model, verify provider credentials,
or test market-data entitlements.

**Start backend / Stop backend appear only in the native Windows desktop app,**
never in a browser (even on Windows), macOS, or Linux. Start is explicit, never
automatic. It checks health again before launching and only supports
`http://127.0.0.1:8765` or `http://localhost:8765`. A reachable external backend
disables Start; Stop is enabled only for the process this app launched. A port
conflict or failed health check never grants ownership of another process.
No HTTP process-control routes are exposed.

This is a **source-checkout desktop workflow**, not a self-contained backend
distribution. Run `flutter pub get` at the root and `dart pub get` in `backend`
first. Keep the checkout and installed Flutter/Dart SDK available; desktop Start
locates the checkout from executable ancestors or the working directory. It
requires `scripts\desktop_backend.ps1`, `scripts\private_config.ps1`, backend
source and restored root Flutter packages (`.dart_tool\package_config.json`,
created by `flutter pub get` in the repository root). The backend shares that
package configuration; it has no separate pubspec. Desktop launch removes
`A_TRADER_WEB_ROOT` from the backend environment entirely: an empty value is
treated as an invalid web-build directory, not as disabled static hosting.
The actual desktop supervisor was verified to start the backend with a healthy
HTTP 200 `/health` response and release its port on Stop, without market/model
requests. An installed desktop executable without
those files reports a setup error; it does not download tools, install services,
request elevation or modify firewall rules. Windows PowerShell must permit the
local script under your existing execution policy.

The supervisor imports the same current-user DPAPI saved provider/model settings
as `scripts\start_backend.ps1`; SDK discovery uses `A_TRADER_FLUTTER_ROOT`, then
`FLUTTER_ROOT`, then the setup script's existing development default. Desktop
launch always overrides inherited bind/port/auth/web-root settings to
**127.0.0.1:8765, authentication off, no web root**: it cannot accidentally launch
a LAN server. Use the existing terminal scripts for other ports or LAN hosting.
Backend output is discarded rather than displayed with potentially sensitive
diagnostics.

The app retains ownership across Settings navigation. Stop signals a uniquely
named, random Windows kernel event; the supervisor terminates only its retained
Dart child process handle. The supervisor also retains the owning app's process
handle and cleans up its child when the app exits, including abrupt termination.
This local OS signal is not an HTTP endpoint. Independently started backends are only
observed and never killed. Startup may take several seconds; reachability is
checked during startup and then on the normal interval. A green indicator alone
is evidence of reachability, not of process ownership.

Validation: `flutter test test\local_connection_status_test.dart
test\backend_process_test.dart test\widget_test.dart` exercises automatic status
and ownership controls with fake services. Run
`.\scripts\test_desktop_backend.ps1` on Windows for real supervisor start/stop,
abrupt app-exit cleanup, inherited environment isolation and unrelated-process safety.
The latter uses harmless Dart fixtures in a uniquely named checkout subdirectory,
removes them afterward, and never reads saved credentials or starts a real backend.

## Schwab local-only OAuth (2026-11-05)

**Auth foundation implemented; successful live authorization is user-reported.** The user reports
the Market Data app is **Ready for Use** and confirms this exact registered
callback (including port/path, no trailing slash):
`https://127.0.0.1:8766/oauth/schwab/callback`.
The user reported the exact terminal success: “Schwab authorization saved
privately with Windows DPAPI. Market-data adapter remains disabled.” This is
operator evidence of consent/persistence, not an independently observed quote,
entitlement, or official token-contract verification. The subsequent read-only
quote/history adapter is implemented below, but never selected automatically.
No chart, account, order or streaming endpoint is added.

Run locally in Windows PowerShell, from the repository root:

```powershell
.\scripts\setup_schwab.ps1
.\scripts\authorize_schwab.ps1
# Later: use saved tokens, refreshing only if within 60 seconds of expiry.
.\scripts\authorize_schwab.ps1 -Refresh
```

1. Setup privately prompts for **App Key** (`SCHWAB_CLIENT_ID`) and **App Secret**
   (`SCHWAB_CLIENT_SECRET`). Do not paste credentials, callback URLs containing
   codes, or tokens into chat, screenshots, logs or source files. Setup merges
   these two values into the existing current-user DPAPI private config,
   preserving other settings. Explicit process-environment values still override
   saved config. If changing app credentials, rerun setup (it invalidates this
   app's old local tokens). The general `setup_private_config.ps1` remains a
   replacement workflow; use the dedicated Schwab setup for incremental changes.
2. With explicit `YES`, setup creates a unique 90-day self-signed certificate for
   **127.0.0.1 only**, briefly in the current user's Personal certificate store,
   exports a password-protected PKCS12 bundle in memory, then removes that
   Personal-store entry. It installs **no trusted root**, opens no firewall port,
   and needs no HTTP.sys/admin HTTPS binding or OpenSSL. Its bundle/password are
   themselves DPAPI encrypted in ignored `.local\schwab\tls.dpapi`.
3. Authorization prints the local certificate thumbprint, requires
   **AUTHORIZE**, binds **127.0.0.1:8766 using HTTPS**, then opens the fixed Schwab
   HTTPS authorize endpoint once. No URL/code is printed. The browser may warn
   about the self-signed certificate **only at the exact local callback above**.
   Verify that address and its certificate/thumbprint before making a local
   exception. **Never bypass a warning on Schwab's site or any other address.**
   Review Schwab's consent screen and cancel if permissions exceed the approved
   Market Data app. No `readonly`/other scope is invented; app permissions are
   not narrowed by a claim in this client.
4. One matching state/code callback is consumed, the listener closes, and the
   code is exchanged server-side using the exact registered redirect URI.
   Successful exchange is reported **only after encrypted token persistence**.
   Browser text only acknowledges receipt; check the terminal for final status.
   Timeout, denial, port conflict, malformed callback or token errors do not
   print response bodies, state, codes, URLs, credentials or tokens.
5. Tokens are current-user Windows DPAPI ciphertext in ignored
   `.local\schwab\tokens.dpapi`; directories/files have current-user-only DACLs.
   Writes use an encrypted sibling then atomic replacement; no plaintext token,
   credential or private-key file is written. A per-directory exclusive lock
   serializes the supplied setup/authorize/refresh commands across processes.
   Do not copy these files to another user/machine or use them as a shared service.
   DPAPI/ACLs do not defend against malware running as this same Windows user.

State uses 32 secure random bytes, expires after five minutes, and is single-use.
The listener requires GET, the exact Host/port/path, one matching state, exactly
one code or error, no duplicate parameters and only known query fields. Optional
`session` is accepted but ignored, never used as authority or stored. Replies are
generic no-store/no-referrer text with restrictive CSP; no public OAuth/status
route is added to the existing HTTP service on 8765. The browser-launch child
receives a Windows environment allowlist, not imported provider credentials.

Refresh is coalesced per client instance and persisted before returning; rotated
refresh tokens replace the old token, while an omitted refresh token preserves
the previous one. Access expiry uses validated positive integer `expires_in`
(safety bound: at most one day), measured **before** the request, with a 60-second
refresh margin. No refresh-token lifespan is fabricated or reset. Requests have a
20-second total timeout, 64 KiB response bound, disabled redirects and no automatic
retry/fallback. An `invalid_grant` is terminal for that client instance and asks
for explicit reauthorization. Other provider errors are also sanitized; expiry,
revocation or uncertainty after a failed rotated-token save may require a new
browser consent. `-Refresh` never opens a browser automatically.

### OAuth evidence and remaining verification

The local official overview/refresh/introduction PDFs (`User Guides ... 3/4/5.pdf`)
and preserved `SCHWAB_MARKET_DATA_SCHEMAS.md` do **not** establish a complete
official token HTTP request/response contract. This is a community-corroborated
implementation, not a claim that the official token specification was verified:

- [schwab-py authentication guide](https://schwab-py.readthedocs.io/en/latest/auth.html):
  desktop-only browser flow, exact callback, local TLS and recurring consent.
- [schwab-py auth source, revision 43c4614](https://github.com/alexgolec/schwab-py/blob/43c4614965bdc434bd87fcd49f959db66338185e/schwab/auth.py):
  fixed `/v1/oauth/authorize` and `/v1/oauth/token`, authorization-code flow,
  Basic client authentication, redirect/state verification and refresh delegation
  to Authlib; no explicit scope is passed by `get_auth_context`.
- [Authlib OAuth client, revision eebcc80](https://github.com/authlib/authlib/blob/eebcc80438dc94ff9e71e678553f3dc5fee7c031/authlib/oauth2/client.py):
  default `client_secret_basic`, form token grants, refresh persistence and
  preservation of an omitted refresh token. This is library behavior, not an
  official Schwab guarantee.
- [SchwabPy community package example](https://pypi.org/project/schwab-client/):
  documents the optional callback `session` field. Only that compatibility field
  is adopted; its trading features, plaintext token approach and lifetime claims
  are not adopted.

Synthetic tests verify token requests/failures, state/CSRF/replay/expiry, refresh
rotation/coalescing, actual native Dart PKCS12 HTTPS callback roundtrips and real
current-user DPAPI/atomic replacement/ACL behavior. They make **no Schwab network
requests** and install no trusted certificate. They briefly generate/remove a
synthetic Personal-store certificate and bind loopback 8766, then clean their own
ignored fixture directory. No real credentials, browser consent, tokens or
entitlements were exercised by tests. The operator subsequently reported successful
private consent above. No additional PDF export is required to use this local flow.

### Read-only Schwab quote + daily history increment

The adapter reuses one OAuth client, serialized refresh and the existing protected
store. Backend refresh holds `.local\schwab\oauth.lock` across read/refresh/write
to exclude standalone setup/authorization and avoid overwriting rotated tokens.
Startup checks file presence only; Settings health is configuration, not a live
connection/entitlement test. Existing running processes are not changed.

Run privately from the repository root:

```powershell
.\scripts\setup_schwab_market_data.ps1
.\scripts\test_schwab_market_data.ps1 -Symbol AAPL
# In a new terminal when you intentionally start the backend:
.\scripts\start_backend.ps1
# Or use the existing authenticated same-origin LAN workflow:
# .\scripts\start_lan.ps1 -AcknowledgePrivateNetworkOnly
```

Setup merges rather than replaces other private settings and never resets tokens.
It requires explicit confirmation of permitted **personal/free** use
(`SCHWAB_MARKET_DATA_TERMS_CONFIRMED=true`), separately asks about LAN/shared
display (`SCHWAB_LAN_DISPLAY_TERMS_CONFIRMED=true`), and explicitly selects
`A_TRADER_MARKET_DATA_PROVIDER=schwab`. OAuth/app approval is **not** rights
confirmation. Do not approve paid access or rights your agreements do not grant.
LAN remains blocked without its separate confirmation; existing global
model-forwarding gates remain unchanged. Process environment overrides saved
settings. No default provider switch or automatic error fallback is introduced.

The optional smoke makes **one quote and one 30-calendar-day history request**,
only after these gates, printing symbol, timestamps, metadata, count and coverage
but no credentials/tokens/provider bodies. A missing/failed quote stops before
history; errors never retry. No live market-data smoke has been recorded for this
increment; fixtures are not provider verification.

Only fixed HTTPS `GET /marketdata/v1/quotes` and
`GET /marketdata/v1/pricehistory` are used. Bearer credentials stay server-side;
redirects/retries are disabled. The conservative **local process** cap is ten
requests/minute (not a claim about Schwab quotas); 403/429 impose a one-minute
cooldown and 401 requires explicit reauthorization/restart. Send/body deadlines
and 1 MiB quote / 2 MiB history bounds apply. No raw-data disk cache is added.

Quotes preserve `realtime`, `quoteType`, total volume (includes pre/post),
trade/quote timestamps, last and bid/ask. `schwabEquity` is not a SIP entitlement
claim. Explicit `realtime=false` is delayed; missing/unknown/non-NBBO metadata
cannot certify freshness, and old NBBO timestamps are stale. A current bid/ask
does not make an older last trade current. Daily percentages, previous close and
reference company labels are not fabricated; their normalized integration is deferred.

REST PDF pages 22–24 establish `periodType=year`, `frequencyType=daily`,
`frequency=1`, epoch-millisecond bounds and the extended-hours/previous-close
boolean parameters. Requests are past-only and at most **120 inclusive calendar
days**, with at most 120 strictly ordered, unique OHLCV records. Invalid symbols,
future/duplicate/out-of-window candles and inconsistent OHLC fail closed.
Supplied `datetimeISO8601` is labelled `providerTradingDate`; otherwise the
timestamp date is explicitly `utcDateProxy`. No exchange timezone is invented.
Corporate-action adjustment is **unknown**. Existing `adjustment=raw` requests
remain accepted for compatibility but results never claim raw; explicit adjusted
requests are rejected. Research and browser parsers preserve this limitation.
Schwab daily indicators return explicit unavailability **before fetching bars**;
do not compute economic returns or claim comparable adjustment.

**Expandable cards (Phase 1 redesign):** click a ticker/company header or its arrow
to reveal quote coverage and the existing manual indicator, research and Ask AI
actions. Several cards may stay open; refresh, Saved toggles and tab navigation
retain expansion for this session. Expanding alone makes no additional request.
Trade levels, returns, stop/risk/RR, position and status remain unavailable until
a deterministic plan engine and strategy configuration exist. Daily change needs
a verified prior regular-session close, not the last refresh. AI explanations are
not direction/confidence forecasts.

**Historical daily candle chart:** every stock card automatically shows its chart
below the Entry/targets disclaimer, without expanding or opening a dialog.
It uses the existing `dailyBars` endpoint with a 30-calendar-day window and a
custom painter, with no added chart package or provider API configuration.
The parent finishes a card's quote then history and renders the result before
requesting the next ticker. Initial load, service/URL changes and explicit
**Refresh quotes & charts** reload the cards; there is no automatic market-data
polling. Queued cards wait for earlier cards; loading, empty and unavailable
history are labelled without synthetic bars. Tap, hover, or use the slider to inspect
exact source OHLCV values. Missing trading dates are not interpolated. The chart
labels provider/feed, session-date provenance and adjustment metadata; history
with unknown adjustment may be plotted, but economic returns and deterministic
indicators retain their existing comparability/adjustment gates. This is
historical data, not a prediction. Intraday charts and separately labelled
experimental forecast overlays remain deferred.

Quotes and histories share pacing: after the first quote identifies the provider,
Schwab waits at least **7 seconds per request** (20 requests take at least
133 seconds), and Twelve Data waits **11 seconds per request**. Unknown-provider
requests conservatively wait eleven seconds. Alpaca remains sequential without an
added frontend delay; its existing shared 180-request/minute adapter limit,
pagination bounds and cooldown safeguards remain unchanged. Refresh preserves the
last request time; it cannot start while a load or explicit analysis is pending.
Changing service/URL or disposing the view invalidates old waits/results. Other
clients and manual tools still share backend quotas: a 429 stops this queue with
a safe cooldown message and no retry/provider switch. Configuration/transport
failures also stop remaining cards. A ticker 404 allows other requests to continue;
history failure never discards a valid quote. Indicators, research and AI remain
explicit actions, not part of automatic card loading.

Provider credentials must stay in private server-side configuration and the backend process environment. Never paste them into Flutter settings, browser storage, source files, build arguments, or issue logs. The Settings screen automatically calls `/health` through loopback in development or the authenticated same-origin LAN server. It does not authenticate with providers, verify an account, or confirm data entitlements.

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

### Optional DuckDuckGo search for local research

This is an explicitly user-approved **limited personal-use** search option, disabled by default. It reuses the package underlying <https://www.lmstudio.ai/jms/duck-duck-go-search> but **not** that plugin's unrestricted autonomous tool loop. Do not add the upstream server directly to this app's research agent: it also offers arbitrary page fetching and defaults to an automatic browser-impersonation fallback.

Install Python 3.10+ normally if needed, then from the repository root run:

```powershell
.\scripts\setup_ddg_search.ps1
```

This explicitly creates `.local\ddg-search` and installs the inspected `duckduckgo-mcp-server` **0.7.0 wheel with SHA-256 verification**, without the browser extra. Ordinary app requests never invoke `uvx`, pip, package downloads or a shell installer. Dependencies are resolved during this explicit setup, not fully transitively locked; review package updates before changing the pinned wheel. The bridge checks its installed distribution version on startup. A missing/wrong package, runtime or script fails unavailable; there is no paid/alternate fallback.

After personally reviewing current DuckDuckGo usage/display/AUP requirements and source/model-use permissions, set **all three** flags in the same PowerShell session that starts the backend:

```powershell
$env:A_TRADER_WEB_SEARCH_ENABLED = 'true'
$env:A_TRADER_WEB_SEARCH_PERSONAL_USE_CONFIRMED = 'true'
$env:A_TRADER_WEB_SEARCH_TERMS_CONFIRMED = 'true'
.\scripts\start_backend.ps1
```

These are session environment flags, not automatically accepted or saved by private credential setup. Existing LM Studio local-only, assistant enablement, source and model-forwarding gates still apply. Research stays on local LM Studio even if OpenAI is configured; quote-only Ask AI is unchanged. Choose **Research with local tools** for a ticker. The model may request `search_public_web({"symbol":"TICKER"})`; the server constructs the only query (`TICKER company news earnings`). Loading a page alone never searches, and a model that does not request the tool is not reported as having searched.

The fixed local adapter serves **search only**, returns up to three snippets/source links, and never opens result pages. It replaces upstream transport to enforce plain `httpx`, an honest application User-Agent and verified TLS, with no proxies, redirects, retries, browser headers/impersonation or CAPTCHA bypass. It stops on non-200, challenge, empty or failed responses. Backend limits are one attempt per 60 seconds, one in flight, ten per server process, plus the unchanged three-model-turn/four-tool research budget. A block latches search off for the process; do not restart repeatedly to evade it. Disable search and wait for permitted normal access. A successful response does not imply future availability.

Sources show **DuckDuckGo search snippet — page not fetched or verified**, actual retrieval time and unavailable publication date. Prices/indicators still require deterministic tools. Search coverage, snippet freshness and source truth are unverified. Keyless/free software is **not** a guaranteed permanent supported DuckDuckGo API, free service entitlement, permission to scrape/redistribute publisher content, or permission to display results publicly. Personal confirmation does not grant shared/public distribution rights; do not enable for other viewers without separately establishing applicable rights. No provider billing/add-ons are configured by this integration.

Validation commands (from the project root):

```powershell
.\.local\ddg-search\Scripts\python.exe -I -B scripts\test_ddg_search_bridge.py
& 'C:\Users\brend\FlutterSDK\flutter\bin\flutter.bat' test --no-pub test\web_search_test.dart test\research_tools_test.dart test\assistant_service_test.dart
# Optional ONE live provider attempt only after the above permissions:
$env:A_TRADER_DDG_LIVE_SMOKE = 'true'
& 'C:\Users\brend\FlutterSDK\flutter\bin\flutter.bat' test --no-pub test\web_search_test.dart --plain-name 'real conservative provider smoke' --reporter expanded
Remove-Item Env:A_TRADER_DDG_LIVE_SMOKE
```

Python tests use the real installed parser with a mocked HTTP transport; Dart fixtures cover the model-tool-result chain through the real HTTP backend to the frontend. Neither is a live LM Studio search verification. On 2026-11-05 one authorized live `MSFT` provider-only smoke returned usable source links through the real conservative stdio bridge; no linked page, market-data provider or OpenAI call was made. Native LM Studio search-tool behavior remains unverified; the existing synthetic quote/indicator native smoke tests remain separate and opt-in.

To disable: stop the backend, remove the three `A_TRADER_WEB_SEARCH_*` environment flags and restart. To uninstall the isolated runtime, remove only `.local\ddg-search` after stopping the backend. No OS service, firewall, domain or HTTPS setting is changed.

Configure only credentials for providers you are authorized to use:

| Provider | Backend variable names | Current status |
|---|---|---|
| Twelve Data Basic | `TWELVE_DATA_API_KEY` | Explicitly selectable for local research/testing. Calls also require `TWELVE_DATA_RESEARCH_TERMS_CONFIRMED=true`. No shared display, paid add-ons, WebSocket trial, raw-data storage, or GPT forwarding. |
| Alpaca market data | `ALPACA_API_KEY_ID`, `ALPACA_API_SECRET_KEY` | Quote/bar adapter implemented; calls also require `ALPACA_MARKET_DATA_TERMS_CONFIRMED=true`. The app currently reports readiness, not successful provider authentication. |
| Schwab Trader API | `SCHWAB_CLIENT_ID`, `SCHWAB_CLIENT_SECRET` | Read-only quote/history adapter implemented; explicit selection, private OAuth and personal/LAN rights gates required. Adjustment unknown; indicators unavailable. Live data/entitlements unverified. |
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

These are real data requests, one credit per symbol per endpoint, not recommendations or orders. Compare the source date/time and coverage metadata; quote prices are minute-candle values from a partial-volume feed, not guaranteed executable prices. OTC, premium endpoints and pre/post data are excluded. Daily bars use exchange-local trading dates. Ideas automatically loads quote then daily history for each of ten temporary stocks, finishing one card before the next, pacing both Twelve Data endpoints eleven seconds apart (20 requests take at least 209 seconds). Refresh requests another run; quota/configuration failures stop remaining requests with errors. The manual lookup/history UI and mock data have been removed.

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
- Gated Twelve Data, Alpaca IEX and explicitly selected Schwab quote/daily-bar adapters are implemented; credentials alone do not activate integrations.
- Schwab app readiness, callback and successful private OAuth are user-reported; real quote/history access and data-use entitlements remain unverified. Thinkorswim access alone is not evidence of API rights.
- This status check performs no market-data, news, filing, social, or OpenAI request.
- No provider may silently fall back to a paid tier or service.
