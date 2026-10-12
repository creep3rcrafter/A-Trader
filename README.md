# A-Trader

A private, free-first microcap swing-trading research app. Ideas now shows ten temporary, unscreened stocks with real latest-available provider quotes. No trade recommendations or orders are generated.

## Local provider setup

### One-time private setup and LAN access

Run `.\scripts\setup_local.ps1` to enter provider credentials privately, review permissions, select an LM Studio model and set a LAN password. Windows user-bound encryption keeps the saved configuration out of source control; launch scripts load it on subsequent starts. Blank/absent OpenAI configuration allows local LM Studio instead, with no paid hosted fallback.

Run `.\scripts\start_lan.ps1 -AcknowledgePrivateNetworkOnly` to build and serve the password-protected web app and APIs together on port **3000**. Open the printed LAN address from another device on the same private network. Do not run the Flutter development server on port 3000 at the same time. Keep LM Studio on the host computer's loopback interface; other devices only access A-Trader.

LAN HTTP is not transport-encrypted. Use only a trusted private network; never expose this port through your router or allow it on public networks. Firewall permission, when needed, must be restricted to the Private profile/local subnet. A password does not replace HTTPS or a VPN on untrusted networks. Provider display rights must permit shared/device access before enabling LAN market data.

### Development-only launch

Start Flutter Web with `.\scripts\start_web.ps1` (fixed `http://localhost:3000`).
In a separate PowerShell window with provider credentials and terms flags configured, run `.\scripts\start_backend.ps1` (backend `http://127.0.0.1:8765`, allows that exact web origin). Stop old instances first; occupied ports fail rather than switching ports. The IDE's `main.dart` Flutter configuration also pins the web hostname and port.

Quotes load automatically once, with an explicit Refresh button and no polling. Twelve Data requests are paced eleven seconds apart; quota/configuration failures stop the run and display errors instead of mock prices. Source times, freshness and partial-feed limitations remain visible. Saved stocks are session-only; History remains empty until journaling is implemented.

See [docs/LOCAL_PROVIDER_SETUP.md](docs/LOCAL_PROVIDER_SETUP.md) before configuring provider credentials. Keys belong only in the local backend process environment, never in Flutter or browser settings. Settings can check environment-variable presence through the loopback health endpoint; it does not test provider authentication or access.

## Project documents

- [Roadmap](docs/PROJECT_ROADMAP.md)
- [Implementation checklist](docs/IMPLEMENTATION_CHECKLIST.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Provider research](docs/DATA_PROVIDER_RESEARCH.md)
- [Performance metrics](docs/PERFORMANCE_METRICS.md)
