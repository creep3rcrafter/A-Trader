/// Deterministic market data, strategy definitions, and simulated accounting.
///
/// Candle timestamps represent bar close times. Signals are evaluated only
/// after a close and orders are filled at the next eligible bar's open.
library;

import 'dart:collection';
import 'dart:math' as math;

import 'exchange_calendar.dart';

import 'strategy_api.dart';
import 'algorithms/registry.dart';
import 'algorithms/helpers.dart' show sessionDate;
import 'algorithms/benchmarks.dart';

export 'strategy_api.dart';
export 'algorithms/registry.dart';

class StrategySettings {
  StrategySettings({
    required this.strategyId,
    required this.label,
    Map<String, double>? parameters,
    this.enabled = true,
    this.intervalMinutes = 1,
    this.startingCash,
  }) : parameters = parameters ?? {};

  final String strategyId;
  final String label;
  final Map<String, double> parameters;
  final bool enabled;
  final int intervalMinutes;
  final double? startingCash;
}

class SimulatedOrder {
  SimulatedOrder({
    required this.symbol,
    required this.action,
    required this.quantity,
    required this.signalTime,
    required this.stop,
    required this.target,
    required this.reason,
    this.sourceStrategyId,
    this.sourceStrategyParameters = const {},
    this.side = PositionSide.long,
    PositionEffect? positionEffect,
  }) : positionEffect =
           positionEffect ??
           (action == TradeAction.buy
               ? PositionEffect.open
               : PositionEffect.close);

  final String symbol;
  final TradeAction action;
  final PositionSide side;
  PositionSide get positionSide => side;
  final PositionEffect positionEffect;
  final int quantity;
  final DateTime signalTime;
  final double? stop;
  final double? target;
  final String reason;
  final String? sourceStrategyId;
  final Map<String, double> sourceStrategyParameters;
}

class SimulatedPosition {
  SimulatedPosition({
    required this.symbol,
    required this.quantity,
    required this.entryPrice,
    required this.entryTime,
    required this.stop,
    required this.target,
    this.entryFees = 0,
    this.sourceStrategyId,
    this.sourceStrategyParameters = const {},
    this.side = PositionSide.long,
  });

  final String symbol;
  final PositionSide side;
  PositionSide get positionSide => side;
  double get collateral => quantity * entryPrice;
  double valueAt(double price) => side == PositionSide.long
      ? quantity * price
      : collateral + quantity * (entryPrice - price);
  TradeAction get exitAction =>
      side == PositionSide.long ? TradeAction.sell : TradeAction.buy;
  int quantity;
  double entryPrice;
  DateTime entryTime;
  double? stop;
  double? target;
  final double entryFees;
  final String? sourceStrategyId;
  final Map<String, double> sourceStrategyParameters;
}

class DecisionEvent {
  const DecisionEvent({
    required this.strategy,
    required this.symbol,
    required this.time,
    required this.action,
    required this.kind,
    required this.reason,
    this.price,
    this.measurements = const {},
    this.side,
    this.entryPrice,
    this.stop,
    this.target,
    this.positionEffect,
  });

  final String strategy;
  final String symbol;
  final DateTime time;
  final TradeAction action;
  final String kind;
  final String reason;
  final double? price;
  final Map<String, double> measurements;
  final PositionSide? side;
  PositionSide? get positionSide => side;
  final double? entryPrice;
  final double? stop;
  final double? target;
  final String? positionEffect;
}

/// A live, timestamped quote. A caller must validate connection and freshness
/// before passing a quote to the execution engine.
class LiveQuote {
  const LiveQuote({
    required this.symbol,
    required this.time,
    required this.bid,
    required this.ask,
    required this.last,
    required this.volume,
    required this.realTime,
  });

  final String symbol;
  final DateTime time;
  final double bid;
  final double ask;
  final double last;
  final double volume;
  final bool realTime;

  bool get isExecutable =>
      realTime &&
      bid.isFinite &&
      ask.isFinite &&
      last.isFinite &&
      volume.isFinite &&
      bid > 0 &&
      ask >= bid &&
      last > 0 &&
      volume >= 0;
}

class EquityPoint {
  const EquityPoint(this.time, this.value);
  final DateTime time;
  final double value;
}

class StrategyAccount {
  StrategyAccount({required this.label, required this.startingCash})
    : cash = startingCash;

  final String label;
  final double startingCash;
  double cash;
  final Map<String, SimulatedPosition> positions = {};

  /// Derived display values only; never executable or evidence of freshness.
  final Map<String, double> positionValuations = {};
  final List<SimulatedOrder> pending = [];
  final List<DecisionEvent> events = [];
  final List<EquityPoint> history = [];
  final List<double> closedPnl = [];
  int get openLongCount =>
      positions.values.where((p) => p.side == PositionSide.long).length;
  int get openShortCount =>
      positions.values.where((p) => p.side == PositionSide.short).length;
  int get closedTradeCount => closedPnl.length;

  double get equity =>
      cash +
      positions.values.fold<double>(
        0,
        (total, position) => total + position.quantity * position.entryPrice,
      );
}

/// Receives risk-approved order intents after strategy evaluation.
abstract interface class ExecutionAdapter {
  void submit(StrategyAccount portfolio, SimulatedOrder order);
}

/// This release routes every accepted order into a local simulated portfolio.
class SimulatorExecutionAdapter implements ExecutionAdapter {
  const SimulatorExecutionAdapter();

  @override
  void submit(StrategyAccount portfolio, SimulatedOrder order) {
    portfolio.pending.add(order);
  }
}

class BenchmarkSettings {
  const BenchmarkSettings({this.buyAndHold = true, this.equalWeight = true});

  factory BenchmarkSettings.fromJson(Map<String, dynamic>? json) =>
      BenchmarkSettings(
        buyAndHold: json?['buyAndHold'] as bool? ?? true,
        equalWeight: json?['equalWeight'] as bool? ?? true,
      );

  final bool buyAndHold;
  final bool equalWeight;

  Map<String, bool> toJson() => {
    'buyAndHold': buyAndHold,
    'equalWeight': equalWeight,
  };
}

/// In-memory simulator core. Each strategy owns isolated cash, orders, fills,
/// positions, and events while consuming the same completed market bars.
class SimulatorEngine {
  static int _nextAlgorithmExecutionId = 0;
  final String _algorithmExecutionId = '${++_nextAlgorithmExecutionId}';
  SimulatorEngine({
    required this.watchlist,
    required this.strategies,
    required this.startingCash,
    this.spreadBps = 2,
    this.slippageBps = 3,
    this.feePerShare = .005,
    this.positionLimit = 5,
    this.riskFraction = .02,
    this.positionSizeFraction = .2,
    this.maxExposureFraction = .9,
    this.dailyLossLimitFraction = .05,
    this.defaultRiskPerShareFraction = .03,
    this.defaultTargetFraction = 0,
    this.allowOvernight = true,
    bool closeAtSessionEnd = false,
    bool? sessionClosePolicyEnabled,
    this.enableShortSelling = false,
    this.quoteDrivenExecution = false,
    this.strategyOverrides = const {},
    this.includeBenchmarks = true,
    this.benchmarks = const BenchmarkSettings(),
  }) : closeAtSessionEnd = sessionClosePolicyEnabled ?? closeAtSessionEnd {
    for (final strategy in strategies.where((item) => item.enabled)) {
      accounts[strategy.label] = StrategyAccount(
        label: strategy.label,
        startingCash: strategy.startingCash ?? startingCash,
      );
    }
    if (includeBenchmarks && benchmarks.buyAndHold) {
      accounts['Buy & Hold'] = StrategyAccount(
        label: 'Buy & Hold',
        startingCash: startingCash,
      );
    }
    if (includeBenchmarks && benchmarks.equalWeight) {
      accounts['Equal Weight'] = StrategyAccount(
        label: 'Equal Weight',
        startingCash: startingCash,
      );
    }
  }

  final List<String> watchlist;
  final List<StrategySettings> strategies;
  final double startingCash;
  final double spreadBps;
  final double slippageBps;
  final double feePerShare;
  final int positionLimit;
  final double riskFraction;
  final double positionSizeFraction;
  final double maxExposureFraction;
  final double dailyLossLimitFraction;
  final double defaultRiskPerShareFraction;
  final double defaultTargetFraction;
  final bool allowOvernight;

  /// Stops strategy entries ten minutes before the exchange close. The first
  /// synchronized fresh marks in that window lock the portfolio's positive
  /// net-liquidation decision for the session. Winners flatten then; others
  /// flatten one minute before close, only on fresh regular-session quotes.
  final bool closeAtSessionEnd;
  bool get sessionClosePolicyEnabled => closeAtSessionEnd;
  final bool enableShortSelling;
  final bool quoteDrivenExecution;
  final Map<String, TradingStrategy> strategyOverrides;
  final bool includeBenchmarks;
  final BenchmarkSettings benchmarks;
  final Map<String, StrategyAccount> accounts = {};
  final Map<String, List<Candle>> candles = {};
  final Set<String> _processedBars = {};
  final Map<String, LiveQuote> _latestQuotes = {};
  final Map<String, DateTime> _lastQuoteTimes = {};
  final Map<String, double> _dailyStartingEquity = {};
  final ExecutionAdapter _executionAdapter = const SimulatorExecutionAdapter();
  final Map<String, String> _dailySessions = {};
  final Map<String, String> _closingSessions = {};
  final Map<String, String> _closeEvaluationSessions = {};
  bool isRunning = false;
  String status = 'Ready';

  List<DecisionEvent> get events =>
      accounts.values.expand((account) => account.events).toList()
        ..sort((a, b) => b.time.compareTo(a.time));

  /// Idempotently processes one completed candle. Duplicate or older bars are
  /// ignored so a reconnect cannot duplicate signal or fill events.
  void process(Candle bar) {
    if (!watchlist.contains(bar.symbol) || _processedBars.contains(bar.key)) {
      return;
    }
    final symbolBars = candles.putIfAbsent(bar.symbol, () => []);
    if (symbolBars.isNotEmpty && !bar.time.isAfter(symbolBars.last.time)) {
      return;
    }
    _processedBars.add(bar.key);
    symbolBars.add(bar);
    // Built-in evaluators consume these views synchronously. Overrides can
    // retain their contexts, so give those engines detached snapshots.
    final copyHistory = strategyOverrides.isNotEmpty;
    final snapshot = {
      for (final entry in candles.entries)
        entry.key: copyHistory
            ? List<Candle>.of(entry.value)
            : UnmodifiableListView(entry.value),
    };
    final symbolView = copyHistory
        ? List<Candle>.unmodifiable(symbolBars)
        : snapshot[bar.symbol]!;
    final session = UsEquityCalendar.forDate(bar.time);
    for (final account in accounts.values) {
      account.positionValuations.remove(bar.symbol);
      final overnightPosition = account.positions[bar.symbol];
      if (!allowOvernight &&
          overnightPosition != null &&
          sessionDate(overnightPosition.entryTime) != sessionDate(bar.time) &&
          !account.pending.any(
            (order) =>
                order.symbol == bar.symbol &&
                order.positionEffect == PositionEffect.close,
          )) {
        _queueOrder(
          account,
          SimulatedOrder(
            symbol: bar.symbol,
            action: overnightPosition.exitAction,
            side: overnightPosition.side,
            positionEffect: PositionEffect.close,
            quantity: overnightPosition.quantity,
            signalTime: bar.time,
            stop: null,
            target: null,
            reason: 'Overnight holding is disabled; exit this session.',
          ),
        );
      }
      if (!quoteDrivenExecution) {
        _fillPending(account, bar);
        _checkProtectiveExits(account, bar);
      }
      if (account.label == 'Buy & Hold' || account.label == 'Equal Weight') {
        _benchmark(account, bar);
      } else {
        final position = account.positions[bar.symbol];
        final settings = strategies.firstWhere(
          (item) => item.label == account.label,
        );
        final pendingEntry = account.pending
            .where(
              (order) =>
                  order.symbol == bar.symbol &&
                  order.positionEffect == PositionEffect.open,
            )
            .firstOrNull;
        final strategyId =
            position?.sourceStrategyId ??
            pendingEntry?.sourceStrategyId ??
            settings.strategyId;
        final strategy =
            strategyOverrides[strategyId] ?? StrategyRegistry.byId(strategyId);
        final parameters =
            position?.sourceStrategyParameters ??
            pendingEntry?.sourceStrategyParameters ??
            settings.parameters;
        if (symbolBars.length >= strategy.warmupBars) {
          final signal = strategy.evaluate(
            StrategyContext(
              candles: symbolView,
              watchlist: snapshot,
              hasPosition: position != null,
              entryPrice: position?.entryPrice,
              positionStop: position?.stop,
              positionSide: position?.side ?? PositionSide.long,
              parameters: parameters,
              intervalMinutes: settings.intervalMinutes,
              sessionElapsedMinutes: session?.elapsedMinutes,
              sessionLengthMinutes: session?.durationMinutes,
              barsHeld: position == null
                  ? 0
                  : _barsAfter(symbolBars, position.entryTime),
              portfolioLabel: account.label,
              executionId: _algorithmExecutionId,
            ),
          );
          account.events.add(
            DecisionEvent(
              strategy: account.label,
              symbol: bar.symbol,
              time: bar.time,
              action: signal.action,
              kind: 'signal',
              reason: signal.reason,
              price: bar.close,
              measurements: signal.measurements,
              side:
                  position?.side ??
                  (signal.action != TradeAction.wait ? signal.side : null),
              stop: signal.stop ?? position?.stop,
              target: signal.target ?? position?.target,
              entryPrice: position?.entryPrice,
              positionEffect: signal.positionEffect?.name,
            ),
          );
          if (signal.action != TradeAction.wait) {
            _checkAndQueue(account, bar, signal);
          }
        } else {
          account.events.add(
            DecisionEvent(
              strategy: account.label,
              symbol: bar.symbol,
              time: bar.time,
              action: TradeAction.wait,
              kind: 'signal',
              reason:
                  'Warm-up: ${symbolBars.length}/${strategy.warmupBars} bars.',
              price: bar.close,
            ),
          );
        }
      }
      _recordEquity(
        account,
        EquityPoint(bar.time, _markToMarket(account, snapshot)),
      );
    }
  }

  /// Applies fills and protective exits only at a subsequent valid live quote.
  /// Buys use the ask and sells use the bid; the event timestamp must be later
  /// than the signal timestamp to prevent same-event fills.
  void processQuote(LiveQuote quote) {
    if (!quoteDrivenExecution ||
        !quote.isExecutable ||
        UsEquityCalendar.sessionAt(quote.time) == null ||
        !watchlist.contains(quote.symbol)) {
      return;
    }
    final previous = _latestQuotes[quote.symbol];
    final lastProcessed = _lastQuoteTimes[quote.symbol];
    if (lastProcessed != null && !quote.time.isAfter(lastProcessed)) return;
    if (previous != null && !quote.time.isAfter(previous.time)) return;
    _lastQuoteTimes[quote.symbol] = quote.time;
    _latestQuotes[quote.symbol] = quote;
    for (final account in accounts.values) {
      _applySessionClose(account, quote);
      final order = account.pending
          .where(
            (item) =>
                item.symbol == quote.symbol &&
                quote.time.isAfter(item.signalTime),
          )
          .firstOrNull;
      if (order != null) {
        account.pending.remove(order);
        final friction = (spreadBps / 2 + slippageBps) / 10000;
        final reference = order.action == TradeAction.buy
            ? quote.ask
            : quote.bid;
        final fill = order.action == TradeAction.buy
            ? reference * (1 + friction)
            : reference * (1 - friction);
        _executeOrder(account, order, quote.time, fill);
      }
      final position = account.positions[quote.symbol];
      if (position == null) continue;
      final short = position.side == PositionSide.short;
      final exitPrice = short ? quote.ask : quote.bid;
      final stopTouched =
          position.stop != null &&
          (short ? exitPrice >= position.stop! : exitPrice <= position.stop!);
      final targetTouched =
          position.target != null &&
          (short
              ? exitPrice <= position.target!
              : exitPrice >= position.target!);
      if (!stopTouched && !targetTouched) continue;
      final stopExit = stopTouched;
      final trigger = stopExit ? position.stop! : position.target!;
      final friction = (spreadBps / 2 + slippageBps) / 10000;
      final fill = exitPrice * (1 + (short ? friction : -friction));
      account.pending.removeWhere((pending) => pending.symbol == quote.symbol);
      _executeOrder(
        account,
        _exitOrder(
          position,
          quote.time,
          '${stopExit ? 'Stop' : 'Target'} filled at the next eligible ${short ? 'ask' : 'bid'}; trigger $trigger.',
        ),
        quote.time,
        fill,
      );
    }
  }

  /// Drops only the affected symbol's candle history so indicators and
  /// strategies cannot trade using a discontinuous input series.
  void resetSymbolWarmup(String symbol) {
    candles.remove(symbol);
    _latestQuotes.remove(symbol);
    for (final account in accounts.values) {
      account.pending.removeWhere(
        (order) =>
            order.symbol == symbol &&
            order.positionEffect == PositionEffect.open,
      );
    }
  }

  SimulatedOrder _exitOrder(
    SimulatedPosition position,
    DateTime time,
    String reason,
  ) => SimulatedOrder(
    symbol: position.symbol,
    action: position.exitAction,
    side: position.side,
    positionEffect: PositionEffect.close,
    quantity: position.quantity,
    signalTime: time,
    stop: position.stop,
    target: position.target,
    reason: reason,
  );

  bool _isBenchmark(StrategyAccount account) =>
      account.label == 'Buy & Hold' || account.label == 'Equal Weight';

  String _exchangeDate(DateTime time) =>
      sessionDate(UsEquityCalendar.toEastern(time));

  bool _entryGateClosed(StrategyAccount account, DateTime time) {
    if (_isBenchmark(account)) return false;
    if (_closingSessions[account.label] == _exchangeDate(time)) return true;
    final session = UsEquityCalendar.forDate(time);
    return closeAtSessionEnd &&
        session != null &&
        session.elapsedMinutes >= session.durationMinutes - 10;
  }

  void _applySessionClose(StrategyAccount account, LiveQuote quote) {
    if (!closeAtSessionEnd || _isBenchmark(account)) return;
    final session = UsEquityCalendar.sessionAt(quote.time)!;
    final remaining = session.durationMinutes - session.elapsedMinutes;
    if (remaining > 10) return;
    account.pending.removeWhere(
      (order) => order.positionEffect == PositionEffect.open,
    );
    final allFresh = account.positions.values.every((position) {
      final mark = _latestQuotes[position.symbol];
      return mark != null &&
          !mark.time.isAfter(quote.time) &&
          quote.time.difference(mark.time) <= const Duration(seconds: 10) &&
          _exchangeDate(mark.time) == _exchangeDate(quote.time);
    });
    final sessionDate = _exchangeDate(quote.time);
    if (_closeEvaluationSessions[account.label] != sessionDate && allFresh) {
      _closeEvaluationSessions[account.label] = sessionDate;
      if (openPositionNetPnl(account) > 0) {
        _closingSessions[account.label] = sessionDate;
      }
    }
    if (remaining <= 1) {
      _closingSessions[account.label] = sessionDate;
    }
    if (_closingSessions[account.label] != sessionDate) return;
    final position = account.positions[quote.symbol];
    if (position == null) return;
    account.pending.removeWhere((order) => order.symbol == quote.symbol);
    final friction = (spreadBps / 2 + slippageBps) / 10000;
    final short = position.side == PositionSide.short;
    final price =
        (short ? quote.ask : quote.bid) * (1 + (short ? friction : -friction));
    _executeOrder(
      account,
      _exitOrder(
        position,
        quote.time,
        remaining <= 1
            ? 'Mandatory session close: closing remaining positions 1 minute '
                  'before the close.'
            : 'Open positions were profitable 10 minutes before close; '
                  'closing to lock in the gain.',
      ),
      quote.time,
      price,
    );
  }

  /// Estimated P&L from closing every open position now at the bid (longs)
  /// or ask (shorts), after spread, slippage, and entry and exit fees.
  double openPositionNetPnl(StrategyAccount account) {
    final friction = (spreadBps / 2 + slippageBps) / 10000;
    return account.positions.values.fold<double>(0, (total, position) {
      final quote = _latestQuotes[position.symbol];
      final short = position.side == PositionSide.short;
      final mark = quote == null
          ? position.entryPrice
          : (short ? quote.ask : quote.bid);
      return total +
          position.valueAt(mark * (1 + (short ? friction : -friction))) -
          position.collateral -
          position.quantity * feePerShare -
          position.entryFees;
    });
  }

  double netLiquidationValue(StrategyAccount account) {
    final friction = (spreadBps / 2 + slippageBps) / 10000;
    return account.cash +
        account.positions.values.fold<double>(0, (total, position) {
          final quote = _latestQuotes[position.symbol];
          final short = position.side == PositionSide.short;
          final mark = quote == null
              ? position.entryPrice
              : (short ? quote.ask : quote.bid);
          return total +
              position.valueAt(mark * (1 + (short ? friction : -friction))) -
              position.quantity * feePerShare;
        });
  }

  void _executeOrder(
    StrategyAccount account,
    SimulatedOrder order,
    DateTime time,
    double price,
  ) {
    if (UsEquityCalendar.sessionAt(time) == null) return;
    final fees = order.quantity * feePerShare;
    SimulatedPosition? position = account.positions[order.symbol];
    if (order.positionEffect == PositionEffect.open) {
      if (position != null || _entryGateClosed(account, time)) return;
      if (order.action !=
          (order.side == PositionSide.long
              ? TradeAction.buy
              : TradeAction.sell)) {
        return;
      }
      if (closeAtSessionEnd &&
          _exchangeDate(order.signalTime) != _exchangeDate(time)) {
        return;
      }
      if (order.side == PositionSide.short && !enableShortSelling) return;
      final cost = price * order.quantity + fees;
      if (cost > account.cash) {
        account.events.add(
          DecisionEvent(
            strategy: account.label,
            symbol: order.symbol,
            time: time,
            action: order.action,
            kind: 'unfilled',
            reason:
                'Unfilled: next eligible price plus costs exceeded available cash.',
            price: price,
            side: order.side,
            positionEffect: 'open',
          ),
        );
        return;
      }
      account.cash -= cost;
      account.positionValuations.remove(order.symbol);
      // Short proceeds stay segregated: only the trader's own entry notional
      // is removed from spendable cash and later released with side-aware P&L.
      position = SimulatedPosition(
        symbol: order.symbol,
        side: order.side,
        quantity: order.quantity,
        entryPrice: price,
        entryTime: time,
        stop: order.stop,
        target: order.target,
        entryFees: fees,
        sourceStrategyId: order.sourceStrategyId,
        sourceStrategyParameters: order.sourceStrategyParameters,
      );
      account.positions[order.symbol] = position;
    } else {
      if (position == null || position.side != order.side) return;
      if (order.action != position.exitAction ||
          order.quantity != position.quantity) {
        return;
      }
      account.cash += position.valueAt(price) - fees;
      account.closedPnl.add(
        (price - position.entryPrice) *
                (position.side == PositionSide.long ? 1 : -1) *
                position.quantity -
            fees -
            position.entryFees,
      );
      account.positions.remove(order.symbol);
      account.positionValuations.remove(order.symbol);
    }
    account.events.add(
      DecisionEvent(
        strategy: account.label,
        symbol: order.symbol,
        time: time,
        action: order.action,
        kind: 'fill',
        reason:
            '${order.reason} ${order.action.name.toUpperCase()} filled at the next eligible price, including costs.',
        price: price,
        side: position.side,
        entryPrice: position.entryPrice,
        stop: position.stop,
        target: position.target,
        positionEffect: order.positionEffect.name,
        measurements: {'shares': order.quantity.toDouble(), 'fees': fees},
      ),
    );
  }

  void _checkAndQueue(
    StrategyAccount account,
    Candle bar,
    StrategySignal signal,
  ) {
    final hasPending = account.pending.any(
      (order) => order.symbol == bar.symbol,
    );
    if (hasPending) return;
    final position = account.positions[bar.symbol];
    final effect =
        signal.positionEffect ??
        (signal.action == TradeAction.buy
            ? PositionEffect.open
            : PositionEffect.close);
    if (effect == PositionEffect.open) {
      if (_entryGateClosed(account, bar.time)) return;
      final short = signal.side == PositionSide.short;
      if (short && !enableShortSelling) {
        account.events.add(
          DecisionEvent(
            strategy: account.label,
            symbol: bar.symbol,
            time: bar.time,
            action: signal.action,
            kind: 'risk',
            reason: 'Blocked: simulated short selling is disabled.',
            side: signal.side,
            positionEffect: 'open',
            price: bar.close,
            stop: signal.stop,
            target: signal.target,
            measurements: const {'approvedShares': 0},
          ),
        );
        return;
      }
      if (signal.action != (short ? TradeAction.sell : TradeAction.buy)) return;
      final riskPrice =
          signal.stop ??
          bar.close * (1 + (short ? 1 : -1) * defaultRiskPerShareFraction);
      final perShareRisk = (bar.close - riskPrice) * (short ? -1 : 1);
      final equity = _markToMarket(account, candles);
      final exposure = account.positions.values.fold<double>(0, (total, held) {
        final bars = candles[held.symbol];
        final quote = _latestQuotes[held.symbol];
        final mark =
            quote?.last ??
            (bars == null || bars.isEmpty ? held.entryPrice : bars.last.close);
        return total + held.quantity * mark;
      });
      final session = '${bar.time.year}-${bar.time.month}-${bar.time.day}';
      if (_dailySessions[account.label] != session) {
        _dailySessions[account.label] = session;
        _dailyStartingEquity[account.label] = equity;
      }
      final sessionEquity = _dailyStartingEquity[account.label] ?? equity;
      final dailyLossExceeded =
          sessionEquity > 0 &&
          (equity - sessionEquity) / sessionEquity <= -dailyLossLimitFraction;
      final quantityByRisk = perShareRisk > 0
          ? (equity * riskFraction / perShareRisk).floor()
          : 0;
      final quantityByCash =
          (account.cash / (bar.close * (1 + (spreadBps + slippageBps) / 10000)))
              .floor();
      final remainingExposure = math.max(
        0,
        equity * maxExposureFraction - exposure,
      );
      final maxValue = math.min(
        math.min(account.cash * positionSizeFraction, remainingExposure),
        account.cash,
      );
      final quantityByAllocation = (maxValue / bar.close).floor();
      final quantity = math.min(
        math.min(quantityByRisk, quantityByCash),
        quantityByAllocation,
      );
      final blocked =
          position != null ||
          account.positions.length >= positionLimit ||
          quantity <= 0 ||
          dailyLossExceeded ||
          (signal.target != null &&
              (signal.target! - bar.close) * (short ? -1 : 1) <= 0);
      account.events.add(
        DecisionEvent(
          strategy: account.label,
          symbol: bar.symbol,
          time: bar.time,
          action: signal.action,
          kind: 'risk',
          side: signal.side,
          stop: riskPrice,
          target: signal.target,
          positionEffect: 'open',
          reason: blocked
              ? dailyLossExceeded
                    ? 'Blocked: daily loss limit reached; new entries are paused.'
                    : 'Blocked: position limit, existing position, exposure, cash, or invalid stop.'
              : 'Risk approved: $quantity whole shares; fill is deferred to the next bar.',
          price: bar.close,
          measurements: {
            'approvedShares': blocked ? 0.0 : quantity.toDouble(),
            ...signal.measurements,
          },
        ),
      );
      if (!blocked) {
        _queueOrder(
          account,
          SimulatedOrder(
            symbol: bar.symbol,
            action: signal.action,
            side: signal.side,
            positionEffect: PositionEffect.open,
            quantity: quantity,
            signalTime: bar.time,
            stop: riskPrice,
            target:
                signal.target ??
                (defaultTargetFraction > 0
                    ? bar.close * (1 + (short ? -1 : 1) * defaultTargetFraction)
                    : null),
            reason: signal.reason,
            sourceStrategyId: signal.sourceStrategyId,
            sourceStrategyParameters: signal.sourceStrategyParameters,
          ),
        );
      }
    } else if (position != null) {
      account.events.add(
        DecisionEvent(
          strategy: account.label,
          symbol: bar.symbol,
          time: bar.time,
          action: position.exitAction,
          kind: 'risk',
          side: position.side,
          entryPrice: position.entryPrice,
          stop: position.stop,
          target: position.target,
          positionEffect: 'close',
          reason: 'Exit approved; fill is deferred to the next eligible bar.',
          price: bar.close,
        ),
      );
      _queueOrder(
        account,
        SimulatedOrder(
          symbol: bar.symbol,
          action: position.exitAction,
          side: position.side,
          positionEffect: PositionEffect.close,
          quantity: position.quantity,
          signalTime: bar.time,
          stop: null,
          target: null,
          reason: signal.reason,
        ),
      );
    }
  }

  void _queueOrder(StrategyAccount account, SimulatedOrder order) {
    _executionAdapter.submit(account, order);
    account.events.add(
      DecisionEvent(
        strategy: account.label,
        symbol: order.symbol,
        time: order.signalTime,
        action: order.action,
        kind: 'order',
        side: order.side,
        stop: order.stop,
        target: order.target,
        positionEffect: order.positionEffect.name,
        reason:
            '${order.action.name.toUpperCase()} ${order.quantity} shares queued for the next eligible quote.',
        measurements: {
          'shares': order.quantity.toDouble(),
          if (order.stop != null) 'stop': order.stop!,
          if (order.target != null) 'target': order.target!,
        },
      ),
    );
  }

  static int _barsAfter(List<Candle> bars, DateTime time) {
    var start = 0;
    var end = bars.length;
    while (start < end) {
      final mid = start + (end - start) ~/ 2;
      if (bars[mid].time.isAfter(time)) {
        end = mid;
      } else {
        start = mid + 1;
      }
    }
    return bars.length - start;
  }

  void _recordEquity(StrategyAccount account, EquityPoint point) {
    final history = account.history;
    if (history.isEmpty || history.last.time.isBefore(point.time)) {
      history.add(point);
      return;
    }
    if (history.last.time.isAtSameMomentAs(point.time)) {
      history[history.length - 1] = point;
      return;
    }
    final existingIndex = history.lastIndexWhere(
      (item) => item.time.isAtSameMomentAs(point.time),
    );
    if (existingIndex >= 0) {
      history[existingIndex] = point;
      return;
    }
    final insertionIndex = history.indexWhere(
      (item) => item.time.isAfter(point.time),
    );
    history.insert(insertionIndex < 0 ? history.length : insertionIndex, point);
  }

  void _fillPending(StrategyAccount account, Candle bar) {
    final order = account.pending
        .where(
          (item) =>
              item.symbol == bar.symbol && bar.time.isAfter(item.signalTime),
        )
        .firstOrNull;
    if (order == null) return;
    account.pending.remove(order);
    final friction = (spreadBps / 2 + slippageBps) / 10000;
    final fill = order.action == TradeAction.buy
        ? bar.open * (1 + friction)
        : bar.open * (1 - friction);
    _executeOrder(account, order, bar.time, fill);
  }

  void _checkProtectiveExits(StrategyAccount account, Candle bar) {
    final position = account.positions[bar.symbol];
    if (position == null) return;
    final short = position.side == PositionSide.short;
    final stopTouched =
        position.stop != null &&
        (short ? bar.high >= position.stop! : bar.low <= position.stop!);
    final targetTouched =
        position.target != null &&
        (short ? bar.low <= position.target! : bar.high >= position.target!);
    if (!stopTouched && !targetTouched) return;
    // Conservative ambiguity policy: when both are touched in one bar, stop wins.
    final stopExit = stopTouched;
    final trigger = stopExit ? position.stop! : position.target!;
    final gapThrough = short ? bar.open > trigger : bar.open < trigger;
    final price = stopExit && gapThrough ? bar.open : trigger;
    final friction = (spreadBps / 2 + slippageBps) / 10000;
    final fill = price * (1 + (short ? friction : -friction));
    account.pending.removeWhere((order) => order.symbol == bar.symbol);
    _executeOrder(
      account,
      _exitOrder(
        position,
        bar.time,
        stopExit
            ? 'Stop filled${gapThrough ? ' at gap-through open' : ''}; stop takes priority if stop and target touch together.'
            : 'Target filled at available bar resolution.',
      ),
      bar.time,
      fill,
    );
  }

  void _benchmark(StrategyAccount account, Candle bar) {
    if (UsEquityCalendar.sessionAt(bar.time) == null) return;
    if (account.positions.containsKey(bar.symbol)) return;
    final algorithm = BenchmarkAlgorithms.byLabel(account.label);
    final allocation = algorithm.allocation(
      cash: account.cash,
      watchlistLength: watchlist.length,
      positionCount: account.positions.length,
      hasPendingOrders: account.pending.isNotEmpty,
      quoteDrivenExecution: quoteDrivenExecution,
    );
    if (quoteDrivenExecution) {
      if (account.pending.any((order) => order.symbol == bar.symbol)) return;
      final estimatedCost =
          bar.close * (1 + (spreadBps / 2 + slippageBps) / 10000) + feePerShare;
      final quantity = (allocation / estimatedCost).floor();
      if (quantity <= 0) return;
      _queueOrder(
        account,
        SimulatedOrder(
          symbol: bar.symbol,
          action: TradeAction.buy,
          quantity: quantity,
          signalTime: bar.time,
          stop: null,
          target: null,
          reason: '${account.label} live benchmark allocation.',
        ),
      );
      account.events.add(
        DecisionEvent(
          strategy: account.label,
          symbol: bar.symbol,
          time: bar.time,
          action: TradeAction.buy,
          kind: 'risk',
          reason:
              'Benchmark allocation approved; fill waits for the next eligible ask.',
          price: bar.close,
          measurements: {'approvedShares': quantity.toDouble()},
        ),
      );
      return;
    }
    final quantity = (allocation / bar.open).floor();
    if (quantity <= 0) return;
    final friction = (spreadBps / 2 + slippageBps) / 10000;
    final price = bar.open * (1 + friction);
    final cost = quantity * price + quantity * feePerShare;
    if (cost > account.cash) return;
    account.cash -= cost;
    account.positions[bar.symbol] = SimulatedPosition(
      symbol: bar.symbol,
      quantity: quantity,
      entryPrice: price,
      entryTime: bar.time,
      stop: null,
      target: null,
      entryFees: quantity * feePerShare,
    );
    final initializationReason = algorithm.initializationReason;
    if (initializationReason != null) {
      account.events.add(
        DecisionEvent(
          strategy: account.label,
          symbol: bar.symbol,
          time: bar.time,
          action: TradeAction.buy,
          kind: 'fill',
          reason: initializationReason,
          price: price,
        ),
      );
    }
  }

  double _markToMarket(
    StrategyAccount account,
    Map<String, List<Candle>> market,
  ) {
    return account.cash +
        account.positions.values.fold<double>(0, (sum, position) {
          return sum + _positionMarketValue(account, position, market);
        });
  }

  double _positionMarketValue(
    StrategyAccount account,
    SimulatedPosition position,
    Map<String, List<Candle>> market,
  ) {
    final quote = _latestQuotes[position.symbol];
    if (quote != null) return position.valueAt(quote.last);
    final savedValue = account.positionValuations[position.symbol];
    if (savedValue != null) return savedValue;
    final bars = market[position.symbol];
    return position.valueAt(
      bars == null || bars.isEmpty ? position.entryPrice : bars.last.close,
    );
  }

  double markToMarket(StrategyAccount account) =>
      _markToMarket(account, candles);

  /// Checkpoint form is deterministic JSON-compatible data used by the local
  /// backend; processed-bar keys make restore/replay idempotent.
  Map<String, Object?> checkpoint() => {
    'watchlist': watchlist,
    'processedBars': _processedBars.toList(),
    'closingSessions': _closingSessions,
    'closeEvaluationSessions': _closeEvaluationSessions,
    'dailySessions': _dailySessions,
    'dailyStartingEquity': _dailyStartingEquity,
    'lastQuoteTimes': _lastQuoteTimes.map(
      (symbol, time) => MapEntry(symbol, time.toIso8601String()),
    ),
    'execution': {
      'startingCash': startingCash,
      'spreadBps': spreadBps,
      'slippageBps': slippageBps,
      'feePerShare': feePerShare,
      'positionLimit': positionLimit,
      'riskFraction': riskFraction,
      'positionSizeFraction': positionSizeFraction,
      'maxExposureFraction': maxExposureFraction,
      'dailyLossLimitFraction': dailyLossLimitFraction,
      'defaultRiskPerShareFraction': defaultRiskPerShareFraction,
      'defaultTargetFraction': defaultTargetFraction,
      'allowOvernight': allowOvernight,
      'closeAtSessionEnd': closeAtSessionEnd,
      'sessionClosePolicyEnabled': closeAtSessionEnd,
      'enableShortSelling': enableShortSelling,
      'quoteDrivenExecution': quoteDrivenExecution,
      'includeBenchmarks': includeBenchmarks,
      'benchmarks': benchmarks.toJson(),
    },
    'accounts': accounts.map(
      (label, account) => MapEntry(label, {
        'cash': account.cash,
        'positionValuations': {
          for (final position in account.positions.values)
            position.symbol: _positionMarketValue(account, position, candles),
        },
        'startingCash': account.startingCash,
        'positions': account.positions.values
            .map(
              (position) => {
                'symbol': position.symbol,
                'side': position.side.name,
                'quantity': position.quantity,
                'entryPrice': position.entryPrice,
                'entryTime': position.entryTime.toIso8601String(),
                'entryFees': position.entryFees,
                'stop': position.stop,
                'target': position.target,
                'sourceStrategyId': position.sourceStrategyId,
                'sourceStrategyParameters': position.sourceStrategyParameters,
              },
            )
            .toList(),
        'pending': account.pending
            .map(
              (order) => {
                'symbol': order.symbol,
                'action': order.action.name,
                'side': order.side.name,
                'positionEffect': order.positionEffect.name,
                'quantity': order.quantity,
                'signalTime': order.signalTime.toIso8601String(),
                'stop': order.stop,
                'target': order.target,
                'reason': order.reason,
                'sourceStrategyId': order.sourceStrategyId,
                'sourceStrategyParameters': order.sourceStrategyParameters,
              },
            )
            .toList(),
        'events': account.events
            .map(
              (event) => {
                'strategy': event.strategy,
                'symbol': event.symbol,
                'time': event.time.toIso8601String(),
                'action': event.action.name,
                'kind': event.kind,
                'reason': event.reason,
                'price': event.price,
                'measurements': event.measurements,
                'side': event.side?.name,
                'entryPrice': event.entryPrice,
                'stop': event.stop,
                'target': event.target,
                'positionEffect': event.positionEffect,
              },
            )
            .toList(),
        'history': account.history
            .map(
              (point) => {
                'time': point.time.toIso8601String(),
                'value': point.value,
              },
            )
            .toList(),
        'closedPnl': account.closedPnl,
      }),
    ),
    'bars': candles.map(
      (key, value) => MapEntry(
        key,
        value
            .map(
              (bar) => {
                'symbol': bar.symbol,
                'time': bar.time.toIso8601String(),
                'open': bar.open,
                'high': bar.high,
                'low': bar.low,
                'close': bar.close,
                'volume': bar.volume,
              },
            )
            .toList(),
      ),
    ),
  };

  factory SimulatorEngine.restore({
    required List<String> watchlist,
    required List<StrategySettings> strategies,
    required double startingCash,
    required Map<String, dynamic> checkpoint,
    Map<String, TradingStrategy> strategyOverrides = const {},
  }) {
    final execution = checkpoint['execution'] as Map<String, dynamic>? ?? {};
    final engine = SimulatorEngine(
      watchlist: watchlist,
      strategies: strategies,
      startingCash:
          (execution['startingCash'] as num?)?.toDouble() ?? startingCash,
      spreadBps: (execution['spreadBps'] as num?)?.toDouble() ?? 2,
      slippageBps: (execution['slippageBps'] as num?)?.toDouble() ?? 3,
      feePerShare: (execution['feePerShare'] as num?)?.toDouble() ?? .005,
      positionLimit: (execution['positionLimit'] as num?)?.toInt() ?? 5,
      riskFraction: (execution['riskFraction'] as num?)?.toDouble() ?? .02,
      positionSizeFraction:
          (execution['positionSizeFraction'] as num?)?.toDouble() ?? .2,
      maxExposureFraction:
          (execution['maxExposureFraction'] as num?)?.toDouble() ?? .9,
      dailyLossLimitFraction:
          (execution['dailyLossLimitFraction'] as num?)?.toDouble() ?? .05,
      defaultRiskPerShareFraction:
          (execution['defaultRiskPerShareFraction'] as num?)?.toDouble() ?? .03,
      defaultTargetFraction:
          (execution['defaultTargetFraction'] as num?)?.toDouble() ?? 0,
      allowOvernight: execution['allowOvernight'] as bool? ?? true,
      sessionClosePolicyEnabled:
          execution['sessionClosePolicyEnabled'] as bool? ??
          execution['closeAtSessionEnd'] as bool? ??
          false,
      enableShortSelling: execution['enableShortSelling'] as bool? ?? false,
      quoteDrivenExecution: execution['quoteDrivenExecution'] as bool? ?? false,
      strategyOverrides: strategyOverrides,
      includeBenchmarks: execution['includeBenchmarks'] as bool? ?? true,
      benchmarks: BenchmarkSettings.fromJson(
        execution['benchmarks'] as Map<String, dynamic>?,
      ),
    );
    engine._closingSessions.addAll(
      (checkpoint['closingSessions'] as Map<String, dynamic>? ?? {}).map(
        (key, value) => MapEntry(key, value as String),
      ),
    );
    engine._closeEvaluationSessions.addAll(engine._closingSessions);
    engine._closeEvaluationSessions.addAll(
      (checkpoint['closeEvaluationSessions'] as Map<String, dynamic>? ?? {})
          .map((key, value) => MapEntry(key, value as String)),
    );
    engine._dailySessions.addAll(
      (checkpoint['dailySessions'] as Map<String, dynamic>? ?? {}).map(
        (key, value) => MapEntry(key, value as String),
      ),
    );
    engine._dailyStartingEquity.addAll(
      (checkpoint['dailyStartingEquity'] as Map<String, dynamic>? ?? {}).map(
        (key, value) => MapEntry(key, (value as num).toDouble()),
      ),
    );
    engine._processedBars.addAll(
      (checkpoint['processedBars'] as List<dynamic>? ?? []).map(
        (key) => key.toString(),
      ),
    );
    final quoteTimes =
        checkpoint['lastQuoteTimes'] as Map<String, dynamic>? ?? {};
    for (final entry in quoteTimes.entries) {
      engine._lastQuoteTimes[entry.key] = DateTime.parse(entry.value as String);
    }
    final rawBars = checkpoint['bars'] as Map<String, dynamic>? ?? {};
    for (final entry in rawBars.entries) {
      final bars = (entry.value as List<dynamic>).map((value) {
        final item = value as Map<String, dynamic>;
        return Candle(
          symbol: item['symbol'] as String,
          time: DateTime.parse(item['time'] as String),
          open: (item['open'] as num).toDouble(),
          high: (item['high'] as num).toDouble(),
          low: (item['low'] as num).toDouble(),
          close: (item['close'] as num).toDouble(),
          volume: (item['volume'] as num).toDouble(),
        );
      }).toList();
      engine.candles[entry.key] = bars;
    }
    final savedAccounts = checkpoint['accounts'] as Map<String, dynamic>? ?? {};
    for (final entry in savedAccounts.entries) {
      final state = entry.value as Map<String, dynamic>;
      final account = StrategyAccount(
        label: entry.key,
        startingCash: (state['startingCash'] as num).toDouble(),
      )..cash = (state['cash'] as num).toDouble();
      account.positionValuations.addAll(
        (state['positionValuations'] as Map<String, dynamic>? ?? {}).map(
          (key, value) => MapEntry(key, (value as num).toDouble()),
        ),
      );
      for (final value in state['positions'] as List<dynamic>? ?? []) {
        final item = value as Map<String, dynamic>;
        final position = SimulatedPosition(
          symbol: item['symbol'] as String,
          side: PositionSide.values.byName(item['side'] as String? ?? 'long'),
          quantity: (item['quantity'] as num).toInt(),
          entryPrice: (item['entryPrice'] as num).toDouble(),
          entryTime: DateTime.parse(item['entryTime'] as String),
          stop: (item['stop'] as num?)?.toDouble(),
          target: (item['target'] as num?)?.toDouble(),
          entryFees: (item['entryFees'] as num?)?.toDouble() ?? 0,
          sourceStrategyId: item['sourceStrategyId'] as String?,
          sourceStrategyParameters:
              (item['sourceStrategyParameters'] as Map<String, dynamic>? ?? {})
                  .map(
                    (key, value) => MapEntry(key, (value as num).toDouble()),
                  ),
        );
        account.positions[position.symbol] = position;
      }
      for (final value in state['pending'] as List<dynamic>? ?? []) {
        final item = value as Map<String, dynamic>;
        account.pending.add(
          SimulatedOrder(
            symbol: item['symbol'] as String,
            side: PositionSide.values.byName(item['side'] as String? ?? 'long'),
            positionEffect: item['positionEffect'] == null
                ? null
                : PositionEffect.values.byName(
                    item['positionEffect'] as String,
                  ),
            action: TradeAction.values.byName(item['action'] as String),
            quantity: (item['quantity'] as num).toInt(),
            signalTime: DateTime.parse(item['signalTime'] as String),
            stop: (item['stop'] as num?)?.toDouble(),
            target: (item['target'] as num?)?.toDouble(),
            reason: item['reason'] as String,
            sourceStrategyId: item['sourceStrategyId'] as String?,
            sourceStrategyParameters:
                (item['sourceStrategyParameters'] as Map<String, dynamic>? ??
                        {})
                    .map(
                      (key, value) => MapEntry(key, (value as num).toDouble()),
                    ),
          ),
        );
      }
      for (final value in state['events'] as List<dynamic>? ?? []) {
        final item = value as Map<String, dynamic>;
        final measurements =
            item['measurements'] as Map<String, dynamic>? ?? {};
        account.events.add(
          DecisionEvent(
            strategy: item['strategy'] as String,
            symbol: item['symbol'] as String,
            time: DateTime.parse(item['time'] as String),
            action: TradeAction.values.byName(item['action'] as String),
            kind: item['kind'] as String,
            reason: item['reason'] as String,
            price: (item['price'] as num?)?.toDouble(),
            measurements: measurements.map(
              (key, value) => MapEntry(key, (value as num).toDouble()),
            ),
            side: item['side'] == null
                ? null
                : PositionSide.values.byName(item['side'] as String),
            entryPrice: (item['entryPrice'] as num?)?.toDouble(),
            stop: (item['stop'] as num?)?.toDouble(),
            target: (item['target'] as num?)?.toDouble(),
            positionEffect: item['positionEffect'] as String?,
          ),
        );
      }
      for (final value in state['history'] as List<dynamic>? ?? []) {
        final item = value as Map<String, dynamic>;
        account.history.add(
          EquityPoint(
            DateTime.parse(item['time'] as String),
            (item['value'] as num).toDouble(),
          ),
        );
      }
      account.closedPnl.addAll(
        (state['closedPnl'] as List<dynamic>? ?? []).map(
          (value) => (value as num).toDouble(),
        ),
      );
      engine.accounts[entry.key] = account;
    }
    return engine;
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
