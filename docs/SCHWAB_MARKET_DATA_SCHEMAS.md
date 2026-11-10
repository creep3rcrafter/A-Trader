# Schwab Market Data schemas

User-supplied transcription from the authenticated Schwab Developer Portal, saved
2026-11-05. These are schema definitions and illustrative provider examples, not
live quotes, credentials, or proof of account-specific entitlements.

Source:
<https://developer.schwab.com/products/trader-api--individual/details/specifications/Market%20Data%20Production>

Related local references:

- `Trader API - Individual _ Products _ Charles Schwab Developer Portal.pdf`:
  streaming documentation.
- `Trader API - Individual _ Products _ Charles Schwab Developer Portal 2.pdf`:
  REST specification export; scrollable examples and collapsed schemas are
  incomplete in the PDF.

This document preserves the supplied field names, types, descriptions and
examples. Apparent documentation typos are retained. The source transcription
does not identify required fields; do not infer requiredness or nullability where
not stated. `[...]` and collapsed enum placeholders indicate missing details,
not empty definitions. The local OAuth foundation now uses explicitly
community-corroborated token exchange/refresh behavior; these schemas do not
establish the official token HTTP contract. See `LOCAL_PROVIDER_SETUP.md` for
provenance, remaining live-consent verification and commands. The schema
definitions below remain unchanged.

## QuoteEquity

Description: Quote data of Equity security.

| Field | Type | Example | Description |
|---|---|---|---|
| `52WeekHigh` | number (`double`) | `145.09` | Higest price traded in the past 12 months, or 52 weeks |
| `52WeekLow` | number (`double`) | `77.581` | Lowest price traded in the past 12 months, or 52 weeks |
| `askMICId` | string | `XNYS` | ask MIC code |
| `askPrice` | number (`double`) | `124.63` | Current Best Ask Price |
| `askSize` | integer (`int32`) | `700` | Number of shares for ask |
| `askTime` | integer (`int64`) | `1621376892336` | Last ask time in milliseconds since Epoch |
| `bidMICId` | string | `XNYS` | bid MIC code |
| `bidPrice` | number (`double`) | `124.6` | Current Best Bid Price |
| `bidSize` | integer (`int32`) | `300` | Number of shares for bid |
| `bidTime` | integer (`int64`) | `1621376892336` | Last bid time in milliseconds since Epoch |
| `closePrice` | number (`double`) | `126.27` | Previous day's closing price |
| `highPrice` | number (`double`) | `126.99` | Day's high trade price |
| `lastMICId` | string | `XNYS` | Last MIC Code |
| `lastPrice` | number (`double`) | `122.3` | Not supplied |
| `lastSize` | integer (`int32`) | `100` | Number of shares traded with last trade |
| `lowPrice` | number (`double`) | Not supplied | Day's low trade price |
| `mark` | number (`double`) | `52.93` | Mark price |
| `markChange` | number (`double`) | `-0.01` | Mark Price change |
| `markPercentChange` | number (`double`) | `-0.0189` | Mark Price percent change |
| `netChange` | number (`double`) | `-0.04` | Current Last-Prev Close |
| `netPercentChange` | number (`double`) | `-0.0756` | Net Percentage Change |
| `openPrice` | number (`double`) | `52.8` | Price at market open |
| `quoteTime` | integer (`int64`) | `1621376892336` | Last quote time in milliseconds since Epoch |
| `securityStatus` | string | `Normal` | Status of security |
| `totalVolume` | integer (`int64`) | `20171188` | Aggregated shares traded throughout the day, including pre/post market hours. |
| `tradeTime` | integer (`int64`) | `1621376731304` | Last trade time in milliseconds since Epoch |
| `volatility` | number (`double`) | `0.0094` | Option Risk/Volatility Measurement |

## EquityResponse

Description: Quote info of Equity security.

| Field | Type | Example / values | Description |
|---|---|---|---|
| `assetMainType` | `AssetMainType`, string | `BOND`, `EQUITY`, `FOREX`, `FUTURE`, `FUTURE_OPTION`, `INDEX`, `MUTUAL_FUND`, `OPTION` | Instrument's asset type |
| `assetSubType` | `EquityAssetSubType`, string, nullable | `COE`, `PRF`, `ADR`, `GDR`, `CEF`, `ETF`, `ETN`, `UIT`, `WAR`, `RGT` | Asset Sub Type (only there if applicable); source enum has a trailing comma |
| `ssid` | integer (`int64`) | `1234567890` | SSID of instrument |
| `symbol` | string | `AAPL` | Symbol of instrument |
| `realtime` | boolean | `true` | is quote realtime |
| `quoteType` | `QuoteType`, string, nullable | `NBBO`, `NFL` | NBBO - realtime, NFL - Non-fee liable quote; source enum has a trailing comma |
| `extended` | `ExtendedMarket` | See below | Quote data for extended hours |
| `fundamental` | `Fundamental` | See below | Fundamentals of a security |
| `quote` | `QuoteEquity` | See above | Quote data of Equity security |
| `reference` | `ReferenceEquity` | See below | Reference data of Equity security |
| `regular` | `RegularMarket` | See below | Market info of security |

The supplied `EquityResponse.quote` definition repeats `QuoteEquity` above with
the same fields, types, examples and descriptions.

### ExtendedMarket

Description: Quote data for extended hours.

| Field | Type | Example | Description |
|---|---|---|---|
| `askPrice` | number (`double`) | `124.85` | Extended market ask price |
| `askSize` | integer (`int32`) | `51771` | Extended market ask size |
| `bidPrice` | number (`double`) | `124.85` | Extended market bid price |
| `bidSize` | integer (`int32`) | `51771` | Extended market bid size |
| `lastPrice` | number (`double`) | `124.85` | Extended market last price |
| `lastSize` | integer (`int32`) | `51771` | Regular market last size |
| `mark` | number (`double`) | `1.1246` | mark price |
| `quoteTime` | integer (`int64`) | `1621368000400` | Extended market quote time in milliseconds since Epoch |
| `totalVolume` | number (`int64`) | `12345` | Total volume |
| `tradeTime` | integer (`int64`) | `1621368000400` | Extended market trade time in milliseconds since Epoch |

`totalVolume` is transcribed as **number (`int64`)**, not silently changed to an
integer declaration.

### Fundamental

Description: Fundamentals of a security.

| Field | Type / format | Example / values | Description |
|---|---|---|---|
| `avg10DaysVolume` | number (`double`) | Not supplied | Average 10 day volume |
| `avg1YearVolume` | number (`double`) | Not supplied | Average 1 day volume |
| `declarationDate` | string (`date-time`), pattern `yyyy-MM-dd'T'HH:mm:ssZ` | `2021-04-28T00:00:00Z` | Declaration date in yyyy-mm-ddThh:mm:ssZ |
| `divAmount` | number (`double`) | `0.88` | Dividend Amount |
| `divExDate` | string (`yyyy-MM-dd'T'HH:mm:ssZ`) | `2021-05-07T00:00:00Z` | Dividend date in yyyy-mm-ddThh:mm:ssZ |
| `divFreq` | `DivFreq`, integer, nullable | `1`, `2`, `3`, `4`, `6`, `11`, `12` | Dividend frequency: 1 - once a year or annually; 2 - 2x a year or semi-annualy; 3 - 3x a year (ex. ARCO, EBRPF); 4 - 4x a year or quarterly; 6 - 6x per yr or every other month; 11 - 11x a year (ex. FBND, FCOR); 12 - 12x a year or monthly |
| `divPayAmount` | number (`double`) | `0.22` | Dividend Pay Amount |
| `divPayDate` | string (`date-time`), pattern `yyyy-MM-dd'T'HH:mm:ssZ` | `2021-05-13T00:00:00Z` | Dividend pay date in yyyy-mm-ddThh:mm:ssZ |
| `divYield` | number (`double`) | `0.7` | Dividend yield |
| `eps` | number (`double`) | `4.45645` | Earnings per Share |
| `fundLeverageFactor` | number (`double`) | `-1` | Fund Leverage Factor + > 0 <- |
| `fundStrategy` | `FundStrategy`, string, nullable | Source shows `Array [ 6 ]`, actual enum values not expanded | FundStrategy "A" - Active "L" - Leveraged "P" - Passive "Q" - Quantitative "S" - Short |
| `nextDivExDate` | string (`date-time`), pattern `yyyy-MM-dd'T'HH:mm:ssZ` | `2021-02-12T00:00:00Z` | Next Dividend date |
| `nextDivPayDate` | string (`date-time`), pattern `yyyy-MM-dd'T'HH:mm:ssZ` | `2021-02-12T00:00:00Z` | Next Dividend date |
| `peRatio` | number (`double`) | `28.599` | P/E Ratio |

The source `divFreq` enum has a trailing comma. The `avg1YearVolume` description,
leverage description and dividend-date descriptions above are preserved as
provided, not interpreted or corrected.

### ReferenceEquity

Description: Reference data of Equity security.

| Field | Type / constraints | Example | Description |
|---|---|---|---|
| `cusip` | string | `A23456789` | CUSIP of Instrument |
| `description` | string | `Apple Inc. - Common Stock` | Description of Instrument |
| `exchange` | string | `q` | Exchange Code |
| `exchangeName` | string | Not supplied | Exchange Name |
| `fsiDesc` | string, maxLength `50` | Not supplied | FSI Desc |
| `htbQuantity` | integer (`int32`) | `100` | Hard to borrow quantity. |
| `htbRate` | number (`double`) | `4.5` | Hard to borrow rate. |
| `isHardToBorrow` | boolean | `false` | is Hard to borrow security. |
| `isShortable` | boolean | `false` | is shortable security. |
| `otcMarketTier` | string, maxLength `10` | Not supplied | OTC Market Tier |

### RegularMarket

Description: Market info of security.

| Field | Type | Example | Description |
|---|---|---|---|
| `regularMarketLastPrice` | number (`double`) | `124.85` | Regular market last price |
| `regularMarketLastSize` | integer (`int32`) | `51771` | Regular market last size |
| `regularMarketNetChange` | number (`double`) | `-1.42` | Regular market net change |
| `regularMarketPercentChange` | Not expanded: `[...]` | Not supplied | Not supplied |
| `regularMarketTradeTime` | integer (`int64`) | `1621368000400` | Regular market trade time in milliseconds since Epoch |

## Candle

No descriptions, examples, required-field list or timezone interpretation were
included in this supplied schema.

| Field | Type |
|---|---|
| `close` | number (`double`) |
| `datetime` | integer (`int64`) |
| `datetimeISO8601` | string (`yyyy-MM-dd`) |
| `high` | number (`double`) |
| `low` | number (`double`) |
| `open` | number (`double`) |
| `volume` | integer (`int64`) |

## CandleList

| Field | Type |
|---|---|
| `candles` | array of `Candle` (same seven fields defined above) |
| `empty` | boolean |
| `previousClose` | number (`double`) |
| `previousCloseDate` | integer (`int64`) |
| `previousCloseDateISO8601` | string (`yyyy-MM-dd`) |
| `symbol` | string |

## Integration boundaries

### Observed REST history boundary behavior (2026-11-05)

Debugger inspection of an authorized daily-history response showed 23 candles
for a requested start of `2026-10-06T00:00:00Z`, including one preceding candle
at `2026-10-05T05:00:00Z`. `datetimeISO8601` was absent. The adapter now validates
the entire bounded response (including OHLCV, timestamps, ordering and duplicates)
before excluding candles outside the requested timestamp/session-date window.
It does not relabel UTC-date proxies as exchange dates or alter the requested
window to accept the extra candle.

After the fix, one authorized AAPL quote plus 30-day history smoke succeeded:
22 in-window daily bars; quote metadata reported `realtime=true` and
`quoteType=NBBO`. No orders, retries or alternate-provider calls were made.
This verifies this live request, not guaranteed feed entitlement or future
availability. Adjustment/timezone remain unknown and indicators remain gated.
Seventy adapter/contract tests and all 416 regression tests passed (three
optional tests skipped); backend analysis and IDE build passed.

- Quote timestamps explicitly described above are milliseconds since Epoch.
  The REST PDF also describes price-history datetime parameters as epoch
  milliseconds; the candle schema alone does not establish exchange-session
  timezone, adjustment policy or corporate-action comparability.
- Previous close, last trade, regular-market last and extended-hours values
  must not be silently substituted for each other. Validate their timestamps
  and session semantics before calculating/displaying daily returns.
- `realtime` and `quoteType` are source metadata, not blanket proof of feed
  entitlement, freshness, free access or redistribution/model-processing rights.
- The read-only adapter now normalizes these supplied fields; source schemas
  themselves do not establish entitlements, adjustment, or live connectivity.
  Selection/usage rights are explicitly gated. Orders and automatic provider
  switching remain disabled.

### REST daily request parameters (local REST PDF pages 22–24)

`periodType` allows `day`, `month`, `year`, `ytd`. Daily aggregation is allowed
with month/year/ytd, not day (minute only). `frequencyType=daily` supports only
`frequency=1`. The adapter uses `periodType=year` with explicit start/end epoch
milliseconds, omits `period`, and sets `needExtendedHoursData=false` and
`needPreviousClose=false`. It enforces its own 120-inclusive-calendar-day bound,
not a provider quota/retention claim. These pages do not establish adjustment or
exchange-session timezone semantics.

## OAuth guide supplied 2026-11-05

Local reference: `User Guides _ Charles Schwab Developer Portal 3.pdf`
(five pages), from
<https://developer.schwab.com/user-guides/get-started/authenticate-with-oauth>.

This guide establishes:

- OAuth 2 authorization-code flow: the user signs into Schwab's Login Micro Site
  and completes Consent and Grant; the application does not collect the Schwab
  login password.
- App client ID/secret identify the application; the secret must remain
  confidential and securely stored.
- Registered callback URLs must use HTTPS. The callback field allows multiple
  comma-separated URLs, with a combined 255-character limit.
- An initial token response includes a refresh token to store securely and use
  to obtain a replacement access token rather than repeating consent each time.
- API product permissions are tied to the app/client ID.

The PDF is an overview, not the token endpoint specification. It does not supply
the exact token request authentication method, form parameters, response schema,
access/refresh expiration rules, rotation behavior or callback state/PKCE
support. Several token-related terms are rendered as `******` in the supplied
PDF; do not infer missing details from those placeholders. The sequence diagram
is not available as extracted text.

Remaining source needed: the Trader API's **POST Token** endpoint documentation,
including both authorization-code and refresh-token grant requests/responses and
expiration/re-authorization requirements. Provider examples must be
documentation placeholders, never actual app secrets, codes or tokens.

### OAuth restart versus refresh guide

Local reference: `User Guides _ Charles Schwab Developer Portal 4.pdf`
(three pages), supplied 2026-11-05, from
<https://developer.schwab.com/user-guides/apis-and-apps/oauth-restart-vs-refresh-token>.

Verified from this guide:

- Normal access-token expiration can be handled by refreshing. The token lifetime
  is returned in `expires_in`, expressed in seconds; no fixed lifetime is stated.
- Preemptive automatic refresh is described as normal when not excessively
  frequent.
- A compromised or malfunctioning refresh token, changed requested scopes or
  authorized accounts, revocation, user credential/TFA changes, or policy changes
  can require restarting consent rather than refreshing.
- Restarting the OAuth flow and aborting after the first authorization step
  invalidates the current access token, according to the guide.
- The guide notes that a compromised or missing access token can be resolved
  using refresh; this does not remove the need to investigate compromise or
  protect token storage.
- Technical refresh failures should be surfaced and investigated, not hidden by
  provider switching or repeated consent loops.

This explains refresh behavior, but still does not specify the POST Token HTTP
request/response contract, client authentication, refresh rotation or refresh-token
lifetime. Do not infer those details from standard OAuth conventions alone.
