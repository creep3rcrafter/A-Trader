/// Live-only quote validation and exchange-session candle aggregation.
///
/// The runtime never backfills a missing bar. A gap discards the unfinished
/// candle and clears strategy warm-up for that symbol until fresh bars arrive.
library;

import 'dart:math' as math;

import 'exchange_calendar.dart';
import 'simulator.dart';

enum FeedState {
  disconnected,
  connecting,
  live,
  stale,
  reauthorizationRequired,
}

class FeedHealth {
  const FeedHealth({
    required this.state,
    required this.updatedAt,
    this.reason = '',
  });

  final FeedState state;
  final DateTime? updatedAt;
  final String reason;

  bool get canFill => state == FeedState.live;
}

class SessionCandleBuilder {
  SessionCandleBuilder({required this.symbol, required this.intervalMinutes})
    : assert(intervalMinutes > 0);

  final String symbol;
  final int intervalMinutes;
  Candle? _active;
  int? _activeBucket;
  String? _activeSession;
  double? _previousSessionVolume;
  bool gapDetected = false;

  Candle? add(LiveQuote quote) {
    gapDetected = false;
    final sessionInfo = UsEquityCalendar.sessionAt(quote.time);
    if (sessionInfo == null) return null;
    final eastern = UsEquityCalendar.toEastern(quote.time);
    final minuteOfDay = eastern.hour * 60 + eastern.minute;
    final session =
        '${sessionInfo.date.year}-${sessionInfo.date.month}-${sessionInfo.date.day}';
    final bucket =
        ((minuteOfDay - UsEquityCalendar.openMinute) ~/ intervalMinutes);
    final openMinute = UsEquityCalendar.openMinute + bucket * intervalMinutes;
    final bucketEnd = math.min(
      openMinute + intervalMinutes,
      sessionInfo.closeMinute,
    );
    final closeTime = UsEquityCalendar.easternToUtc(
      DateTime(
        eastern.year,
        eastern.month,
        eastern.day,
        bucketEnd ~/ 60,
        bucketEnd % 60,
      ),
    );
    final volume = _volumeDelta(quote.volume, session);
    final oldCandle = _active;
    final oldBucket = _activeBucket;
    final oldSession = _activeSession;
    if (oldCandle != null && (session != oldSession || bucket != oldBucket)) {
      _active = null;
      _activeBucket = null;
      _activeSession = null;
      if (session == oldSession && bucket == oldBucket! + 1) {
        _start(quote, volume, bucket, session, closeTime);
        return oldCandle;
      }
      gapDetected = true;
      _start(quote, volume, bucket, session, closeTime);
      return null;
    }
    if (oldCandle == null) {
      _start(quote, volume, bucket, session, closeTime);
      return null;
    }

    _active = Candle(
      symbol: symbol,
      time: oldCandle.time,
      open: oldCandle.open,
      high: math.max(oldCandle.high, quote.last),
      low: math.min(oldCandle.low, quote.last),
      close: quote.last,
      volume: oldCandle.volume + volume,
    );
    return null;
  }

  void reset() {
    _active = null;
    _activeBucket = null;
    _activeSession = null;
    _previousSessionVolume = null;
  }

  void _start(
    LiveQuote quote,
    double volume,
    int bucket,
    String session,
    DateTime closeTime,
  ) {
    _active = Candle(
      symbol: symbol,
      time: closeTime,
      open: quote.last,
      high: quote.last,
      low: quote.last,
      close: quote.last,
      volume: volume,
    );
    _activeBucket = bucket;
    _activeSession = session;
  }

  double _volumeDelta(double current, String session) {
    final eastern = _activeSession;
    final previous = _previousSessionVolume;
    _previousSessionVolume = current;
    if (eastern != session || previous == null || current < previous) {
      return 0;
    }
    return math.max(0, current - previous);
  }
}

/// Coordinates independent per-interval engines and blocks every fill unless
/// the authenticated stream is connected and its quote timestamps are fresh.
class LiveSimulationRuntime {
  LiveSimulationRuntime({
    required this.watchlist,
    required this.strategies,
    required this.startingCash,
    this.positionSizeFraction = .2,
    this.maxExposureFraction = .9,
    this.dailyLossLimitFraction = .05,
    this.riskFraction = .02,
    this.defaultRiskPerShareFraction = .03,
    this.defaultTargetFraction = 0,
    this.spreadBps = 2,
    this.slippageBps = 3,
    this.feePerShare = .005,
    this.allowOvernight = true,
    bool closeAtSessionEnd = false,
    bool? sessionClosePolicyEnabled,
    this.enableShortSelling = false,
    this.quoteFreshness = const Duration(seconds: 10),
    this.strategyOverrides = const {},
    BenchmarkSettings benchmarks = const BenchmarkSettings(),
    DateTime Function()? clock,
  }) : closeAtSessionEnd = sessionClosePolicyEnabled ?? closeAtSessionEnd,
       _clock = clock ?? DateTime.now {
    final intervals =
        strategies
            .where((strategy) => strategy.enabled)
            .map((strategy) => strategy.intervalMinutes)
            .toSet()
            .toList()
          ..sort();
    if (intervals.isEmpty) intervals.add(1);
    for (var index = 0; index < intervals.length; index++) {
      final interval = intervals[index];
      final settings = strategies
          .where(
            (strategy) =>
                strategy.enabled && strategy.intervalMinutes == interval,
          )
          .toList();
      engines[interval] = SimulatorEngine(
        watchlist: watchlist,
        strategies: settings,
        startingCash: startingCash,
        positionSizeFraction: positionSizeFraction,
        maxExposureFraction: maxExposureFraction,
        dailyLossLimitFraction: dailyLossLimitFraction,
        riskFraction: riskFraction,
        defaultRiskPerShareFraction: defaultRiskPerShareFraction,
        defaultTargetFraction: defaultTargetFraction,
        spreadBps: spreadBps,
        slippageBps: slippageBps,
        feePerShare: feePerShare,
        allowOvernight: allowOvernight,
        closeAtSessionEnd: this.closeAtSessionEnd,
        enableShortSelling: enableShortSelling,
        quoteDrivenExecution: true,
        includeBenchmarks: index == 0,
        benchmarks: benchmarks,
        strategyOverrides: strategyOverrides,
      );
      for (final symbol in watchlist) {
        builders['$symbol:$interval'] = SessionCandleBuilder(
          symbol: symbol,
          intervalMinutes: interval,
        );
      }
    }
  }

  final List<String> watchlist;
  final List<StrategySettings> strategies;
  final double startingCash;
  final double positionSizeFraction;
  final double maxExposureFraction;
  final double dailyLossLimitFraction;
  final double riskFraction;
  final double defaultRiskPerShareFraction;
  final double defaultTargetFraction;
  final double spreadBps;
  final double slippageBps;
  final double feePerShare;
  final bool allowOvernight;
  final bool closeAtSessionEnd;
  bool get sessionClosePolicyEnabled => closeAtSessionEnd;
  final bool enableShortSelling;
  final Duration quoteFreshness;

  /// Test hook: replaces registry strategies by ID.
  final Map<String, TradingStrategy> strategyOverrides;
  final DateTime Function() _clock;
  final Map<int, SimulatorEngine> engines = {};
  final Map<String, SessionCandleBuilder> builders = {};
  final Map<String, FeedHealth> symbolHealth = {};
  final Map<String, LiveQuote> latestQuotes = {};

  bool streamConnected = false;
  bool running = false;
  String runStatus = 'Ready';

  FeedHealth healthFor(String symbol) =>
      symbolHealth[symbol] ??
      const FeedHealth(
        state: FeedState.disconnected,
        updatedAt: null,
        reason: 'Waiting for an authenticated live subscription.',
      );

  void begin() {
    if (!streamConnected) {
      throw StateError('Connect to Schwab before starting a live run.');
    }
    running = true;
    runStatus = 'Waiting for fresh live quotes';
  }

  void setConnected(bool connected, {String? reason}) {
    streamConnected = connected;
    if (!connected) {
      for (final symbol in watchlist) {
        symbolHealth[symbol] = FeedHealth(
          state: FeedState.disconnected,
          updatedAt: symbolHealth[symbol]?.updatedAt,
          reason: reason ?? 'Schwab stream disconnected; fills are paused.',
        );
      }
      runStatus = running ? 'Reconnecting; fills paused' : 'Disconnected';
    }
  }

  void requireReauthorization(String reason) {
    streamConnected = false;
    for (final symbol in watchlist) {
      symbolHealth[symbol] = FeedHealth(
        state: FeedState.reauthorizationRequired,
        updatedAt: symbolHealth[symbol]?.updatedAt,
        reason: reason,
      );
    }
    runStatus = 'Schwab reauthorization required';
  }

  bool onQuote(LiveQuote quote) {
    final completed = _prepareQuote(quote);
    if (completed == null) return false;
    for (final entry in completed.entries) {
      engines[entry.key]!.process(entry.value);
    }
    runStatus = 'Live simulation';
    return true;
  }

  /// Replay can await a model on the completed candle before evaluation.
  /// Live delivery uses [onQuote] and never waits on model inference.
  Future<bool> onQuoteAwaitingDecisions(
    LiveQuote quote, {
    required Future<void> Function(
      int interval,
      SimulatorEngine engine,
      Candle bar,
    )
    beforeDecision,
  }) async {
    final completed = _prepareQuote(quote);
    if (completed == null) return false;
    for (final entry in completed.entries) {
      final engine = engines[entry.key]!;
      await beforeDecision(entry.key, engine, entry.value);
      if (!running) return false;
      engine.process(entry.value);
    }
    runStatus = 'Live simulation';
    return true;
  }

  Map<int, Candle>? _prepareQuote(LiveQuote quote) {
    if (!running || !streamConnected || !watchlist.contains(quote.symbol)) {
      return null;
    }
    final age = _clock().difference(quote.time);
    if (!quote.isExecutable ||
        UsEquityCalendar.sessionAt(quote.time) == null ||
        age > quoteFreshness ||
        age < const Duration(seconds: -5)) {
      symbolHealth[quote.symbol] = FeedHealth(
        state: FeedState.stale,
        updatedAt: quote.time,
        reason: !quote.realTime
            ? 'Quote is not verified as real-time; fills are paused.'
            : 'Quote is missing a valid bid/ask or is outside the freshness limit.',
      );
      return null;
    }
    final previous = latestQuotes[quote.symbol];
    if (previous != null && !quote.time.isAfter(previous.time)) return null;
    symbolHealth[quote.symbol] = FeedHealth(
      state: FeedState.live,
      updatedAt: quote.time,
    );
    latestQuotes[quote.symbol] = quote;
    final completed = <int, Candle>{};
    for (final entry in builders.entries) {
      if (!entry.key.startsWith('${quote.symbol}:')) continue;
      final bar = entry.value.add(quote);
      if (entry.value.gapDetected) {
        final interval = int.parse(entry.key.split(':').last);
        engines[interval]!.resetSymbolWarmup(quote.symbol);
      }
      if (bar != null) {
        final interval = int.parse(entry.key.split(':').last);
        completed[interval] = bar;
      }
    }
    for (final engine in engines.values) {
      engine.processQuote(quote);
    }
    return completed;
  }

  /// Ages authenticated quotes even when the stream goes quiet without closing.
  void checkFreshness() {
    if (!running || !streamConnected) return;
    for (final symbol in watchlist) {
      final quote = latestQuotes[symbol];
      if (quote == null) {
        symbolHealth[symbol] = FeedHealth(
          state: FeedState.stale,
          updatedAt: null,
          reason:
              'No live quote has arrived for this symbol; fills are paused.',
        );
        continue;
      }
      final age = _clock().difference(quote.time);
      if (!quote.isExecutable ||
          age > quoteFreshness ||
          age < const Duration(seconds: -5)) {
        symbolHealth[symbol] = FeedHealth(
          state: FeedState.stale,
          updatedAt: quote.time,
          reason: 'Live quote exceeded the freshness limit; fills are paused.',
        );
      }
    }
  }
}
