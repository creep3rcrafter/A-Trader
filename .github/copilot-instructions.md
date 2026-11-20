# Copilot instructions

Use descriptive Dart names and preserve simulator-only execution: the Schwab
integration is a market-data adapter, not an order-placement path. Keep strategy
parameters in the shared `StrategyRegistry` and update their tests when behavior
changes.

See [`docs/CODE_MAP.md`](../docs/CODE_MAP.md) for feature entry points, storage,
test locations, extension points, and known verification gaps.

From the repository root, run:

```powershell
dart format lib test bin
flutter analyze
flutter test
flutter build windows
flutter build web
```

The Windows app can launch its bundled backend from the offline banner or
Settings. `flutter build windows` compiles and packages `atrader_backend.exe`;
keep it beside the desktop executable. For Web, run the standalone backend
with `dart run bin\server.dart` and the dashboard with `flutter run -d chrome`.
Review the root `README.md` before changing startup, OAuth setup, or backend
configuration.

Historical mode (`lib/historical_replay.dart`) replays Schwab minute history
through the live runtime on a simulated clock. Never let strategies or fills see
a quote or candle before its simulated time.
