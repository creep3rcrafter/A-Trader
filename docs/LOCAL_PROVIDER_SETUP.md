# Local Provider Setup

**Status:** credential-presence detection only; this is not a provider connection test.

Provider credentials must stay in the local backend process environment. Never paste them into Flutter settings, browser storage, source files, build arguments, or issue logs. The Settings screen's **Check local connections** action calls only the loopback `/health` endpoint and displays whether configured environment variables are present. It does not authenticate with providers, verify an account, or confirm data entitlements.

## Environment variable names

Configure only credentials for providers you are authorized to use:

| Provider | Backend variable names | Current status |
|---|---|---|
| Alpaca market data | `ALPACA_API_KEY_ID`, `ALPACA_API_SECRET_KEY` | Quote/bar adapter implemented; calls also require `ALPACA_MARKET_DATA_TERMS_CONFIRMED=true`. The app currently reports readiness, not successful provider authentication. |
| Schwab Trader API | `SCHWAB_CLIENT_ID`, `SCHWAB_CLIENT_SECRET` | Presence detection only. App approval, entitlements, OAuth, and adapter remain unverified/unimplemented. |
| Alpha Vantage | `ALPHA_VANTAGE_API_KEY` | Presence detection only; connector not implemented. |
| Bright Data | `BRIGHT_DATA_API_TOKEN` | Presence detection only; connector remains disabled pending applicable permissions and terms. |
| OpenAI | `OPENAI_API_KEY` | Presence detection only; connector not implemented. |
| SEC EDGAR | None | Public endpoints do not require an API key; the integration is not implemented. |

The backend also accepts `A_TRADER_PORT` (default `8765`) and `A_TRADER_ALLOWED_ORIGIN` for the exact Flutter Web origin. Browser requests are rejected unless that origin is explicitly configured. The service binds to `127.0.0.1` only. Do not expose or forward this local service to a public network.

## Windows setup

Set the variables in the environment of the PowerShell process that will run the backend, then start or restart the local service from the project root. For a safer setup, use a local secret manager or Windows environment-variable settings rather than typing secret values into shell commands; ordinary environment variables are still accessible to processes running as your user.

For Alpaca, leave `ALPACA_MARKET_DATA_TERMS_CONFIRMED` unset until you have reviewed and accepted the provider's current data-use terms. Leave `ALPACA_DATA_CACHING_PERMITTED` unset unless the intended caching is permitted. Credentials alone do not enable requests.

Open Flutter **Settings → Research & data providers**, confirm the local service URL is loopback (for example, `http://127.0.0.1:8765`), then choose **Check local connections**. A positive credential-presence result means only that the backend process received a non-empty environment variable. It does not establish valid credentials, approval, API access, entitlements, or a successful provider response.

## Current limits

- The settings form intentionally has no API-key input and does not save secrets.
- Only the gated Alpaca IEX quote and daily-bar routes are implemented; credentials for the other listed providers do not activate integrations.
- Schwab access is not assumed from thinkorswim usage; wait for app approval and verify market-data entitlements in the official portal.
- This status check performs no market-data, news, filing, social, or OpenAI request.
- No provider may silently fall back to a paid tier or service.
