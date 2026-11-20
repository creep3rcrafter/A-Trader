import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:atrader/exchange_calendar.dart';
import 'package:atrader/live_runtime.dart';
import 'package:atrader/lm_studio.dart';
import 'package:atrader/schwab_api.dart';
import 'package:atrader/secure_storage.dart';
import 'package:atrader/simulator.dart';
import 'package:flutter_test/flutter_test.dart';

class _AlwaysBuy implements TradingStrategy {
  _AlwaysBuy(this.id);

  @override
  final String id;
  @override
  String get name => id;
  @override
  String get description => 'Test-only always-buy fixture.';
  @override
  int get warmupBars => 1;
  @override
  List<StrategyParameter> get parameters => const [];

  @override
  StrategySignal evaluate(StrategyContext context) => context.hasPosition
      ? const StrategySignal(TradeAction.wait, 'Position is already open.')
      : const StrategySignal(
          TradeAction.buy,
          'Test entry.',
          stop: 95,
          target: 110,
        );
}

class _BuyThenSell extends _AlwaysBuy {
  _BuyThenSell() : super('buy-then-sell');

  @override
  StrategySignal evaluate(StrategyContext context) => context.hasPosition
      ? const StrategySignal(TradeAction.sell, 'Fixture exit.')
      : const StrategySignal(TradeAction.buy, 'Fixture entry.');
}

class _ShortThenCover extends _AlwaysBuy {
  _ShortThenCover({this.cover = false}) : super('short-fixture');
  final bool cover;

  @override
  StrategySignal evaluate(StrategyContext context) => context.hasPosition
      ? StrategySignal(
          cover ? TradeAction.buy : TradeAction.wait,
          'Fixture cover.',
          positionEffect: PositionEffect.close,
        )
      : const StrategySignal(
          TradeAction.sell,
          'Fixture short.',
          side: PositionSide.short,
          positionEffect: PositionEffect.open,
          stop: 110,
          target: 80,
        );
}

Candle _bar(DateTime time, {double close = 100}) => Candle(
  symbol: 'SOXL',
  time: time,
  open: close,
  high: close + 1,
  low: close - 1,
  close: close,
  volume: 100,
);

LiveQuote _quote(DateTime time, {double bid = 100, double ask = 101}) =>
    LiveQuote(
      symbol: 'SOXL',
      time: time,
      bid: bid,
      ask: ask,
      last: (bid + ask) / 2,
      volume: 1000,
      realTime: true,
    );

void main() {
  test(
    'benchmark switches act independently and survive checkpoint recovery',
    () {
      for (final (buyAndHold, equalWeight) in [
        (true, false),
        (false, true),
        (false, false),
      ]) {
        final engine = SimulatorEngine(
          watchlist: const ['SOXL'],
          strategies: const [],
          startingCash: 1000,
          benchmarks: BenchmarkSettings(
            buyAndHold: buyAndHold,
            equalWeight: equalWeight,
          ),
        );
        final expected = [
          if (buyAndHold) 'Buy & Hold',
          if (equalWeight) 'Equal Weight',
        ];
        expect(engine.accounts.keys, expected);
        final restored = SimulatorEngine.restore(
          watchlist: engine.watchlist,
          strategies: engine.strategies,
          startingCash: engine.startingCash,
          checkpoint: engine.checkpoint(),
        );
        expect(restored.accounts.keys, expected);
      }
    },
  );

  test('runtime passes the market-close rule to every interval engine', () {
    final runtime = LiveSimulationRuntime(
      watchlist: const ['SOXL'],
      strategies: [
        for (final interval in [1, 5])
          StrategySettings(
            strategyId: 'ma_crossover',
            label: 'MA $interval',
            intervalMinutes: interval,
          ),
      ],
      startingCash: 1000,
      sessionClosePolicyEnabled: true,
    );
    expect(runtime.engines.values.map((e) => e.closeAtSessionEnd), [
      true,
      true,
    ]);
  });

  test('strategies wait instead of failing when parameters need more bars', () {
    final squeeze = StrategyRegistry.all.firstWhere(
      (strategy) => strategy.id == 'volatility_squeeze',
    );
    final start = DateTime.utc(2026, 5, 4, 14);
    for (final count in [squeeze.warmupBars, 5, 30]) {
      final candles = [
        for (var index = 0; index < count; index++)
          Candle(
            symbol: 'SOXL',
            time: start.add(Duration(minutes: index)),
            open: 10,
            high: 11,
            low: 9,
            close: 10,
            volume: 100,
          ),
      ];
      final signal = squeeze.evaluate(
        StrategyContext(
          candles: candles,
          watchlist: {'SOXL': candles},
          parameters: const {'contractionBars': 20},
          hasPosition: false,
          entryPrice: null,
        ),
      );
      expect(signal.action, TradeAction.wait);
    }
  });

  group('side-aware simulated execution', () {
    final time = DateTime.utc(2026, 5, 4, 14);
    SimulatorEngine engineFor(
      TradingStrategy strategy, {
      bool closeAtSessionEnd = false,
      List<String> symbols = const ['SOXL'],
      double fee = .1,
    }) => SimulatorEngine(
      watchlist: symbols,
      strategies: [StrategySettings(strategyId: strategy.id, label: 'Fixture')],
      startingCash: 10000,
      quoteDrivenExecution: true,
      spreadBps: 0,
      slippageBps: 0,
      feePerShare: fee,
      closeAtSessionEnd: closeAtSessionEnd,
      enableShortSelling: true,
      includeBenchmarks: false,
      strategyOverrides: {strategy.id: strategy},
    );

    test(
      'short reserves own cash, marks equity by side, and buys cover at ask with both fees',
      () {
        final engine = engineFor(_ShortThenCover(cover: true));
        engine.process(_bar(time));
        engine.processQuote(
          _quote(time.add(const Duration(seconds: 1)), bid: 100, ask: 101),
        );
        final account = engine.accounts['Fixture']!;
        final position = account.positions['SOXL']!;
        final quantity = position.quantity;
        expect(position.side, PositionSide.short);
        expect(position.entryPrice, 100);
        expect(account.cash, closeTo(10000 - quantity * 100.1, .0001));
        expect(account.openShortCount, 1);
        expect(account.openLongCount, 0);
        expect(
          engine.markToMarket(account),
          closeTo(10000 - quantity * .6, .0001),
        );
        engine.process(_bar(time.add(const Duration(minutes: 1)), close: 90));
        expect(account.pending.single.positionEffect, PositionEffect.close);
        expect(account.pending.single.action, TradeAction.buy);
        engine.processQuote(
          _quote(
            time.add(const Duration(minutes: 1, seconds: 1)),
            bid: 89,
            ask: 90,
          ),
        );
        expect(account.positions, isEmpty);
        expect(account.closedPnl.single, closeTo(quantity * 9.8, .0001));
        expect(account.cash, closeTo(10000 + quantity * 9.8, .0001));
        expect(account.events.last.positionEffect, 'close');
        expect(account.events.last.side, PositionSide.short);
      },
    );

    test(
      'short proceeds cannot finance another position or another account',
      () {
        final engine = engineFor(_ShortThenCover(), symbols: ['SOXL', 'TQQQ']);
        final account = engine.accounts['Fixture']!;
        account.pending.add(
          SimulatedOrder(
            symbol: 'SOXL',
            action: TradeAction.sell,
            side: PositionSide.short,
            positionEffect: PositionEffect.open,
            quantity: 90,
            signalTime: time,
            stop: 120,
            target: 80,
            reason: 'Collateral fixture.',
          ),
        );
        engine.processQuote(_quote(time.add(const Duration(seconds: 1))));
        expect(account.cash, closeTo(991, .001));
        account.pending.add(
          SimulatedOrder(
            symbol: 'TQQQ',
            action: TradeAction.buy,
            quantity: 20,
            signalTime: time,
            stop: null,
            target: null,
            reason: 'No free proceeds.',
          ),
        );
        engine.processQuote(
          LiveQuote(
            symbol: 'TQQQ',
            time: time.add(const Duration(seconds: 2)),
            bid: 100,
            ask: 100,
            last: 100,
            volume: 0,
            realTime: true,
          ),
        );
        expect(account.positions.length, 1);
        expect(account.cash, closeTo(991, .001));
      },
    );

    test(
      'short stop gaps buy at actual ask and duplicate quotes cannot refill',
      () {
        final engine = engineFor(_ShortThenCover());
        engine.process(_bar(time));
        engine.processQuote(_quote(time.add(const Duration(seconds: 1))));
        final account = engine.accounts['Fixture']!;
        final quantity = account.positions['SOXL']!.quantity;
        final gap = _quote(
          time.add(const Duration(seconds: 2)),
          bid: 119,
          ask: 120,
        );
        engine.processQuote(gap);
        engine.processQuote(gap);
        expect(account.positions, isEmpty);
        expect(account.closedPnl, hasLength(1));
        expect(account.closedPnl.single, closeTo(-20.2 * quantity, .0001));
        expect(account.events.last.price, 120);
      },
    );

    test('legacy SELL without a position never opens a short', () {
      final engine = engineFor(_BuyThenSell());
      final account = engine.accounts['Fixture']!;
      account.pending.add(
        SimulatedOrder(
          symbol: 'SOXL',
          action: TradeAction.sell,
          quantity: 1,
          signalTime: time,
          stop: null,
          target: null,
          reason: 'Legacy exit.',
        ),
      );
      engine.processQuote(_quote(time.add(const Duration(seconds: 1))));
      expect(account.positions, isEmpty);
      expect(account.cash, 10000);
    });

    test(
      'checkpoint preserves shorts and migrates absent side/effect fields to legacy long',
      () {
        final strategy = _ShortThenCover();
        final engine = engineFor(strategy, closeAtSessionEnd: true);
        engine.process(_bar(time));
        engine.processQuote(_quote(time.add(const Duration(seconds: 1))));
        Map<String, dynamic> saved() =>
            jsonDecode(jsonEncode(engine.checkpoint())) as Map<String, dynamic>;
        SimulatorEngine restore(Map<String, dynamic> checkpoint) =>
            SimulatorEngine.restore(
              watchlist: engine.watchlist,
              strategies: engine.strategies,
              startingCash: 10000,
              checkpoint: checkpoint,
              strategyOverrides: {strategy.id: strategy},
            );
        final restored = restore(saved());
        expect(saved().containsKey('latestQuotes'), isFalse);
        final savedAccount = (saved()['accounts'] as Map)['Fixture'] as Map;
        expect(savedAccount['positionValuations'], isA<Map>());
        expect(restored.closeAtSessionEnd, isTrue);
        expect(
          restored.accounts['Fixture']!.positions['SOXL']!.side,
          PositionSide.short,
        );
        expect(
          restored.markToMarket(restored.accounts['Fixture']!),
          engine.markToMarket(engine.accounts['Fixture']!),
        );
        final shortQuantity =
            restored.accounts['Fixture']!.positions['SOXL']!.quantity;
        restored.processQuote(
          _quote(time.add(const Duration(seconds: 2)), bid: 119, ask: 120),
        );
        expect(
          restored.accounts['Fixture']!.closedPnl.single,
          closeTo(-20.2 * shortQuantity, .0001),
        );
        final old = saved();
        (old['execution'] as Map).remove('closeAtSessionEnd');
        (old['execution'] as Map).remove('sessionClosePolicyEnabled');
        (old['execution'] as Map).remove('enableShortSelling');
        final state = (old['accounts'] as Map)['Fixture'] as Map;
        for (final item in state['positions'] as List) {
          (item as Map).remove('side');
        }
        state['pending'] = [
          {
            'symbol': 'SOXL',
            'action': 'sell',
            'quantity': shortQuantity,
            'signalTime': time.toIso8601String(),
            'stop': null,
            'target': null,
            'reason': 'Legacy close without typed fields.',
          },
        ];
        final legacy = restore(old);
        expect(legacy.closeAtSessionEnd, isFalse);
        expect(
          legacy.accounts['Fixture']!.positions['SOXL']!.side,
          PositionSide.long,
        );
        expect(
          legacy.accounts['Fixture']!.pending.single.side,
          PositionSide.long,
        );
        expect(
          legacy.accounts['Fixture']!.pending.single.positionEffect,
          PositionEffect.close,
        );
      },
    );

    test(
      'flat WAIT has no invented side; held WAIT retains short stop and target',
      () {
        final wait = BuiltinStrategy(
          id: 'wait-fixture',
          name: 'Wait',
          description: 'Wait fixture.',
          warmupBars: 1,
          parameters: const [],
          rule: (_) => const StrategySignal(TradeAction.wait, 'No position.'),
        );
        final flat = engineFor(wait);
        flat.process(_bar(time));
        final flatEvent = flat.accounts['Fixture']!.events.singleWhere(
          (event) => event.kind == 'signal',
        );
        expect(flatEvent.side, isNull);
        expect(flatEvent.stop, isNull);
        expect(flatEvent.target, isNull);

        final engine = engineFor(_ShortThenCover());
        engine.process(_bar(time));
        engine.processQuote(_quote(time.add(const Duration(seconds: 1))));
        engine.process(_bar(time.add(const Duration(minutes: 1))));
        final event = engine.accounts['Fixture']!.events.lastWhere(
          (event) => event.kind == 'signal',
        );
        expect(event.action, TradeAction.wait);
        expect(event.positionSide, PositionSide.short);
        expect(event.entryPrice, 100);
        expect(event.stop, 110);
        expect(event.target, 80);
      },
    );

    test('short permission defaults off and is independent of long exits', () {
      final strategy = _ShortThenCover();
      final engine = SimulatorEngine(
        watchlist: ['SOXL'],
        strategies: [
          StrategySettings(strategyId: strategy.id, label: 'Fixture'),
        ],
        startingCash: 10000,
        quoteDrivenExecution: true,
        strategyOverrides: {strategy.id: strategy},
      );
      engine.process(_bar(time));
      expect(engine.accounts['Fixture']!.pending, isEmpty);
      expect(
        engine.accounts['Fixture']!.events.last.reason,
        contains('disabled'),
      );
    });

    test(
      'portfolio gate uses all positions, waits for fresh marks, and persists the closing latch',
      () {
        final strategy = _ShortThenCover();
        final engine = engineFor(
          strategy,
          closeAtSessionEnd: true,
          symbols: ['SOXL', 'TQQQ'],
          fee: 0,
        );
        final account = engine.accounts['Fixture']!;
        final entry = DateTime.utc(2026, 5, 4, 19, 40);
        account.cash = 8000;
        for (final symbol in ['SOXL', 'TQQQ']) {
          account.positions[symbol] = SimulatedPosition(
            symbol: symbol,
            side: PositionSide.short,
            quantity: 10,
            entryPrice: 100,
            entryTime: entry,
            stop: null,
            target: null,
          );
        }
        final gate = DateTime.utc(2026, 5, 4, 19, 50);
        engine.processQuote(_quote(gate, bid: 89, ask: 90));
        expect(account.positions.length, 2); // Other symbol has no fresh ask.
        engine.processQuote(
          LiveQuote(
            symbol: 'TQQQ',
            time: gate,
            bid: 104,
            ask: 105,
            last: 104.5,
            volume: 0,
            realTime: true,
          ),
        );
        expect(account.positions.keys, [
          'SOXL',
        ]); // Net +50, despite one losing symbol.
        final saved =
            jsonDecode(jsonEncode(engine.checkpoint())) as Map<String, dynamic>;
        final restored = SimulatorEngine.restore(
          watchlist: engine.watchlist,
          strategies: engine.strategies,
          startingCash: 10000,
          checkpoint: saved,
          strategyOverrides: {strategy.id: strategy},
        );
        // Positive-net gate was latched: close remaining leg even after adverse movement.
        restored.processQuote(
          _quote(gate.add(const Duration(seconds: 1)), bid: 119, ask: 120),
        );
        expect(restored.accounts['Fixture']!.positions, isEmpty);
        expect(restored.accounts['Fixture']!.closedTradeCount, 2);
        restored.process(_bar(gate.add(const Duration(minutes: 1))));
        expect(restored.accounts['Fixture']!.pending, isEmpty);
      },
    );

    test(
      'pending entries are canceled at gate and cannot carry into next session',
      () {
        final engine = engineFor(_ShortThenCover(), closeAtSessionEnd: true);
        final signalTime = DateTime.utc(2026, 5, 4, 19, 49);
        engine.process(_bar(signalTime));
        final account = engine.accounts['Fixture']!;
        expect(account.pending, isNotEmpty);
        engine.processQuote(_quote(DateTime.utc(2026, 5, 4, 19, 50)));
        expect(account.pending, isEmpty);
        expect(account.positions, isEmpty);
        engine.process(_bar(DateTime.utc(2026, 5, 5, 14)));
        engine.processQuote(_quote(DateTime.utc(2026, 5, 5, 14, 0, 1)));
        expect(account.openShortCount, 1);
      },
    );

    test('restored valuations are not executable quote freshness', () {
      final strategy = _ShortThenCover();
      final engine = engineFor(
        strategy,
        closeAtSessionEnd: true,
        symbols: ['SOXL', 'TQQQ'],
        fee: 0,
      );
      final account = engine.accounts['Fixture']!;
      final beforeGate = DateTime.utc(2026, 5, 4, 19, 49, 59);
      account.cash = 8000;
      for (final symbol in ['SOXL', 'TQQQ']) {
        account.positions[symbol] = SimulatedPosition(
          symbol: symbol,
          side: PositionSide.short,
          quantity: 10,
          entryPrice: 100,
          entryTime: time,
          stop: null,
          target: null,
        );
        engine.processQuote(
          LiveQuote(
            symbol: symbol,
            time: beforeGate,
            bid: 89,
            ask: 90,
            last: 89.5,
            volume: 0,
            realTime: true,
          ),
        );
      }
      final saved =
          jsonDecode(jsonEncode(engine.checkpoint())) as Map<String, dynamic>;
      final restored = SimulatorEngine.restore(
        watchlist: engine.watchlist,
        strategies: engine.strategies,
        startingCash: 10000,
        checkpoint: saved,
        strategyOverrides: {strategy.id: strategy},
      );
      expect(
        restored.markToMarket(restored.accounts['Fixture']!),
        engine.markToMarket(account),
      );
      restored.processQuote(
        _quote(beforeGate.add(const Duration(seconds: 1)), bid: 89, ask: 90),
      );
      expect(restored.accounts['Fixture']!.positions.length, 2);
      restored.processQuote(
        LiveQuote(
          symbol: 'TQQQ',
          time: beforeGate.add(const Duration(seconds: 1)),
          bid: 89,
          ask: 90,
          last: 89.5,
          volume: 0,
          realTime: true,
        ),
      );
      expect(restored.accounts['Fixture']!.positions.keys, ['SOXL']);
    });

    for (final early in [false, true]) {
      test(
        '${early ? 'early' : 'regular'} close flattens positive portfolios at ten minutes and losers at one, never reenters',
        () {
          final close = early
              ? DateTime.utc(2026, 11, 27, 18)
              : DateTime.utc(2026, 5, 4, 20);
          final start = close.subtract(const Duration(minutes: 20));
          for (final winner in [false, true]) {
            final engine = engineFor(
              _ShortThenCover(),
              closeAtSessionEnd: true,
            );
            engine.process(_bar(start));
            engine.processQuote(_quote(start.add(const Duration(seconds: 1))));
            final account = engine.accounts['Fixture']!;
            final bid = winner ? 94.0 : 104.0;
            final gate = close.subtract(const Duration(minutes: 10));
            engine.processQuote(_quote(gate, bid: bid, ask: bid + 1));
            expect(account.positions.isEmpty, winner);
            engine.process(_bar(gate, close: bid));
            expect(account.pending, isEmpty);
            engine.processQuote(
              _quote(
                close.subtract(const Duration(minutes: 1)),
                bid: bid,
                ask: bid + 1,
              ),
            );
            expect(account.positions, isEmpty);
            expect(account.closedTradeCount, 1);
            engine.process(
              _bar(close.subtract(const Duration(seconds: 30)), close: bid),
            );
            engine.processQuote(
              _quote(
                close.subtract(const Duration(seconds: 29)),
                bid: bid,
                ask: bid + 1,
              ),
            );
            expect(account.positions, isEmpty);
            expect(account.pending, isEmpty);
          }
        },
      );
    }

    for (final initialAsk in [100.0, 105.0]) {
      test(
        'flat or losing ten-minute decision ($initialAsk) stays locked after later profits and checkpoint restore',
        () {
          final strategy = _ShortThenCover();
          final engine = engineFor(strategy, closeAtSessionEnd: true, fee: 0);
          engine.process(_bar(time));
          engine.processQuote(
            _quote(time.add(const Duration(seconds: 1)), bid: 100, ask: 100),
          );
          final gate = DateTime.utc(2026, 5, 4, 19, 50);
          engine.processQuote(
            _quote(gate, bid: initialAsk - 1, ask: initialAsk),
          );
          final saved =
              jsonDecode(jsonEncode(engine.checkpoint()))
                  as Map<String, dynamic>;
          final restored = SimulatorEngine.restore(
            watchlist: engine.watchlist,
            strategies: engine.strategies,
            startingCash: 10000,
            checkpoint: saved,
            strategyOverrides: {strategy.id: strategy},
          );
          for (final instance in [engine, restored]) {
            final account = instance.accounts['Fixture']!;
            instance.processQuote(
              _quote(DateTime.utc(2026, 5, 4, 19, 55), bid: 94, ask: 95),
            );
            expect(
              instance.netLiquidationValue(account),
              greaterThan(account.startingCash),
            );
            expect(account.positions, isNotEmpty);
            expect(account.closedPnl, isEmpty);
            instance.processQuote(
              _quote(DateTime.utc(2026, 5, 4, 19, 59), bid: 94, ask: 95),
            );
            expect(account.positions, isEmpty);
            expect(account.closedTradeCount, 1);
            expect(
              account.events.last.reason,
              contains('Mandatory session close'),
            );
          }
        },
      );
    }

    test(
      'queued exits in the close window fill once and cannot cause reentry',
      () {
        for (final winner in [false, true]) {
          final engine = engineFor(_BuyThenSell(), closeAtSessionEnd: true);
          engine.process(_bar(time));
          engine.processQuote(
            _quote(time.add(const Duration(seconds: 1)), bid: 100, ask: 101),
          );
          final account = engine.accounts['Fixture']!;
          engine.process(_bar(DateTime.utc(2026, 5, 4, 19, 49)));
          expect(account.pending.single.positionEffect, PositionEffect.close);
          final bid = winner ? 105.0 : 100.0;
          engine.processQuote(
            _quote(DateTime.utc(2026, 5, 4, 19, 50), bid: bid, ask: bid + 1),
          );
          expect(account.pending, isEmpty);
          expect(account.positions, isEmpty);
          expect(account.closedTradeCount, 1);
          engine.process(_bar(DateTime.utc(2026, 5, 4, 19, 55)));
          engine.processQuote(
            _quote(DateTime.utc(2026, 5, 4, 19, 55, 1), bid: bid, ask: bid + 1),
          );
          engine.processQuote(
            _quote(DateTime.utc(2026, 5, 4, 19, 59), bid: bid, ask: bid + 1),
          );
          expect(account.pending, isEmpty);
          expect(account.positions, isEmpty);
          expect(account.closedTradeCount, 1);
        }
      },
    );

    test(
      'ten-minute profitability includes executable spread and exit fees, not last-price gain',
      () {
        final engine = engineFor(_ShortThenCover(), closeAtSessionEnd: true);
        engine.process(_bar(time));
        engine.processQuote(
          _quote(time.add(const Duration(seconds: 1)), bid: 100, ask: 100),
        );
        final account = engine.accounts['Fixture']!;
        engine.processQuote(
          _quote(DateTime.utc(2026, 5, 4, 19, 50), bid: 98, ask: 100),
        );
        expect(account.positions, isNotEmpty);
        engine.processQuote(
          _quote(DateTime.utc(2026, 5, 4, 19, 59), bid: 98, ask: 100),
        );
        expect(account.closedPnl.single, lessThan(0));
      },
    );

    test(
      'no quote means no fabricated close and after-close quotes never fill',
      () {
        final engine = engineFor(_ShortThenCover(), closeAtSessionEnd: true);
        engine.process(_bar(time));
        engine.processQuote(_quote(time.add(const Duration(seconds: 1))));
        final account = engine.accounts['Fixture']!;
        engine.processQuote(
          _quote(DateTime.utc(2026, 5, 4, 20), bid: 90, ask: 91),
        );
        expect(account.positions, isNotEmpty);
        expect(account.closedPnl, isEmpty);
      },
    );

    test(
      'runtime rejects stale and out-of-order quotes before candles or fills',
      () {
        var now = time;
        final runtime =
            LiveSimulationRuntime(
                watchlist: ['SOXL'],
                strategies: [
                  StrategySettings(
                    strategyId: 'short-fixture',
                    label: 'Fixture',
                  ),
                ],
                startingCash: 10000,
                closeAtSessionEnd: true,
                strategyOverrides: {'short-fixture': _ShortThenCover()},
                clock: () => now,
              )
              ..setConnected(true)
              ..begin();
        expect(runtime.onQuote(_quote(now)), isTrue);
        expect(
          runtime.onQuote(_quote(now.subtract(const Duration(seconds: 1)))),
          isFalse,
        );
        now = DateTime.utc(2026, 5, 4, 19, 59);
        expect(
          runtime.onQuote(_quote(now.subtract(const Duration(seconds: 11)))),
          isFalse,
        );
        expect(runtime.latestQuotes['SOXL']!.time, time);
      },
    );
  });

  test(
    'inverse gaps require formation, later inversion and later rejection in both directions',
    () {
      final strategy = StrategyRegistry.byId('inverse_fair_value_gap');
      final time = DateTime.utc(2026, 5, 4, 14);
      final bearishRows = <List<double>>[
        [99, 100, 98, 99],
        [101, 103, 100, 102],
        [103, 104, 102, 103],
        [101, 102, 98, 99],
        [100.5, 101, 98.5, 99],
      ];
      for (final short in [true, false]) {
        final bars = bearishRows.indexed.map((entry) {
          final row = entry.$2;
          final values = short
              ? row
              : [200 - row[0], 200 - row[2], 200 - row[1], 200 - row[3]];
          return Candle(
            symbol: 'SOXL',
            time: time.add(Duration(minutes: entry.$1)),
            open: values[0],
            high: values[1],
            low: values[2],
            close: values[3],
            volume: 100,
          );
        }).toList();
        StrategySignal evaluate(
          int count, {
          Map<String, double> parameters = const {},
        }) => strategy.evaluate(
          StrategyContext(
            candles: bars.take(count).toList(),
            watchlist: const {},
            hasPosition: false,
            entryPrice: null,
            parameters: parameters,
          ),
        );
        expect(evaluate(3).action, TradeAction.wait);
        expect(evaluate(4).action, TradeAction.wait);
        final signal = evaluate(5);
        expect(signal.action, short ? TradeAction.sell : TradeAction.buy);
        expect(signal.side, short ? PositionSide.short : PositionSide.long);
        expect(signal.positionEffect, PositionEffect.open);
        expect(
          short
              ? signal.stop! > bars.last.close
              : signal.stop! < bars.last.close,
          isTrue,
        );
        expect(
          short
              ? signal.target! < bars.last.close
              : signal.target! > bars.last.close,
          isTrue,
        );
        expect(
          evaluate(5, parameters: {'minimumGapPercent': 5}).action,
          TradeAction.wait,
        );
        final previous = bars.last;
        bars.add(
          Candle(
            symbol: previous.symbol,
            time: previous.time.add(const Duration(minutes: 1)),
            open: previous.open,
            high: previous.high,
            low: previous.low,
            close: previous.close,
            volume: previous.volume,
          ),
        );
        expect(
          evaluate(6).action,
          TradeAction.wait,
        ); // First rejection consumes zone.
      }
    },
  );

  test(
    'inverse gap expiry counts closed candles from original confirmation',
    () {
      final time = DateTime.utc(2026, 5, 4, 14);
      final rows = <List<double>>[
        [99, 100, 98, 99],
        [101, 103, 100, 102],
        [103, 104, 102, 103],
        [103, 104, 100, 103],
        [103, 104, 100, 103],
        [101, 102, 98, 99],
        [100.5, 101, 98.5, 99],
      ];
      final bars = rows.indexed
          .map(
            (entry) => Candle(
              symbol: 'SOXL',
              time: time.add(Duration(minutes: entry.$1)),
              open: entry.$2[0],
              high: entry.$2[1],
              low: entry.$2[2],
              close: entry.$2[3],
              volume: 100,
            ),
          )
          .toList();
      final strategy = StrategyRegistry.byId('inverse_fair_value_gap');
      StrategySignal evaluate(double expiry) => strategy.evaluate(
        StrategyContext(
          candles: bars,
          watchlist: const {},
          hasPosition: false,
          entryPrice: null,
          parameters: {'expiryBars': expiry},
        ),
      );
      expect(evaluate(30).positionEffect, PositionEffect.open);
      expect(evaluate(3).action, TradeAction.wait);
    },
  );

  test('Level One merger combines partial Schwab updates per symbol', () {
    final merger = LevelOneQuoteMerger();
    final quoteMs = DateTime.utc(2026, 11, 16, 18, 40).millisecondsSinceEpoch;
    String message(List<Map<String, Object?>> rows) => jsonEncode({
      'data': [
        {
          'service': 'LEVELONE_EQUITIES',
          'timestamp': quoteMs + 5000,
          'command': 'SUBS',
          'content': rows,
        },
      ],
    });
    // First update lacks a last price, so no complete quote yet. Fields 10/11
    // are high/low prices and must never be read as timestamps.
    expect(
      merger.apply(
        message([
          {
            'key': 'SOXL',
            'delayed': false,
            '1': 30.1,
            '2': 30.12,
            '8': 1e6,
            '10': 31.5,
            '34': quoteMs,
          },
        ]),
      ),
      isEmpty,
    );
    final quotes = merger.apply(
      message([
        {'key': 'SOXL', '3': 30.11, '35': quoteMs + 1000},
      ]),
    );
    expect(quotes, hasLength(1));
    expect(quotes.single.bid, 30.1);
    expect(quotes.single.ask, 30.12);
    expect(quotes.single.last, 30.11);
    expect(quotes.single.volume, 1e6);
    expect(
      quotes.single.time,
      DateTime.fromMillisecondsSinceEpoch(quoteMs + 1000, isUtc: true),
    );
    expect(quotes.single.realTime, isTrue);

    // A bid-only change reuses earlier fields; without 34/35 it falls back to
    // the message timestamp.
    final bidOnly = merger.apply(
      message([
        {'key': 'SOXL', '1': 30.11},
      ]),
    );
    expect(bidOnly.single.bid, 30.11);
    expect(
      bidOnly.single.time,
      DateTime.fromMillisecondsSinceEpoch(quoteMs + 5000, isUtc: true),
    );

    final delayed = merger.apply(
      message([
        {'key': 'SOXL', 'delayed': true, '34': quoteMs + 6000},
      ]),
    );
    expect(delayed.single.realTime, isFalse);

    merger.reset();
    expect(
      merger.apply(
        message([
          {'key': 'SOXL', '1': 30.2, '34': quoteMs},
        ]),
      ),
      isEmpty,
    );
  });

  test('Schwab app-product rejection is reported as setup, not reauth', () {
    expect(
      SchwabApi.traderApiAccessProblem(
        '{"errors":[{"status":401,"title":"Unauthorized",'
        '"detail":"Client not authorized"}]}',
      ),
      contains('Accounts and Trading Production'),
    );
    expect(
      SchwabApi.traderApiAccessProblem('{"error":"invalid_token"}'),
      isNull,
    );
  });

  test(
    'LM selector keeps the selected exit evaluator through a fill and restore',
    () {
      final selector = LmStudioSelectorStrategy()
        ..setSelection(
          'Persisted selector',
          'SOXL',
          const LmStudioSelection(
            strategyId: 'rule_selector',
            parameters: {'trendThresholdPercent': .1},
            toolName: 'inspect_rule_selector',
            reason: 'Strong upward trend.',
          ),
        );
      final strategies = [
        StrategySettings(
          strategyId: 'lm_selector',
          label: 'Persisted selector',
        ),
      ];
      final engine = SimulatorEngine(
        watchlist: const ['SOXL'],
        strategies: strategies,
        startingCash: 10000,
        includeBenchmarks: false,
        strategyOverrides: {'lm_selector': selector},
      );
      final start = DateTime.utc(2026, 5, 4, 14);
      for (var index = 0; index < 23; index++) {
        final close = 101.0 + index;
        engine.process(
          Candle(
            symbol: 'SOXL',
            time: start.add(Duration(minutes: index)),
            open: close - .5,
            high: close + 1,
            low: close - 1,
            close: close,
            volume: 1000,
          ),
        );
      }

      final account = engine.accounts['Persisted selector']!;
      expect(account.positions['SOXL']?.sourceStrategyId, 'rule_selector');
      final restored = SimulatorEngine.restore(
        watchlist: const ['SOXL'],
        strategies: strategies,
        startingCash: 10000,
        checkpoint: engine.checkpoint(),
        strategyOverrides: {'lm_selector': selector},
      );
      expect(
        restored
            .accounts['Persisted selector']
            ?.positions['SOXL']
            ?.sourceStrategyParameters['trendThresholdPercent'],
        .1,
      );
    },
  );

  test(
    'Windows secret storage round-trips and removes a dummy secret',
    () async {
      if (!Platform.isWindows) return;
      final directory = await Directory.systemTemp.createTemp('atrader-test-');
      addTearDown(() => directory.delete(recursive: true));
      final storage = SecureStorage(directory: directory);
      const dummy = {
        'appKey': 'dummy-test-key',
        'appSecret': 'dummy-test-secret',
      };

      await storage.save(dummy);
      expect(await storage.load(), dummy);
      await storage.remove();
      expect(await storage.load(), isEmpty);
    },
  );
  test(
    'Windows secret storage reads the legacy PowerShell DPAPI format',
    () async {
      if (!Platform.isWindows) return;
      final directory = await Directory.systemTemp.createTemp('atrader-test-');
      addTearDown(() => directory.delete(recursive: true));
      const dummy = {'appKey': 'legacy-dummy-key'};
      final legacy = await Process.run('powershell.exe', [
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        "ConvertFrom-SecureString -SecureString (ConvertTo-SecureString "
            "-String '${jsonEncode(dummy)}' -AsPlainText -Force)",
      ]);
      expect(legacy.exitCode, 0);
      await File(
        '${directory.path}\\secrets.dpapi',
      ).writeAsString((legacy.stdout as String).trim());

      expect(await SecureStorage(directory: directory).load(), dummy);
    },
  );
  test('Windows secret storage reports unreadable data clearly', () async {
    if (!Platform.isWindows) return;
    final directory = await Directory.systemTemp.createTemp('atrader-test-');
    addTearDown(() => directory.delete(recursive: true));
    await File(
      '${directory.path}\\secrets.dpapi',
    ).writeAsString('not-protected-data');

    await expectLater(
      SecureStorage(directory: directory).load(),
      throwsA(isA<SecureStorageException>()),
    );
  });

  group('simulator execution and recovery', () {
    test('portfolios have separate cash, positions, and fills', () {
      final time = DateTime.utc(2026, 5, 4, 14);
      final first = _AlwaysBuy('fixture-a');
      final second = _AlwaysBuy('fixture-b');
      final engine = SimulatorEngine(
        watchlist: const ['SOXL'],
        strategies: [
          StrategySettings(
            strategyId: 'fixture-a',
            label: 'Portfolio A',
            startingCash: 1000,
          ),
          StrategySettings(
            strategyId: 'fixture-b',
            label: 'Portfolio B',
            startingCash: 2000,
          ),
        ],
        startingCash: 1000,
        quoteDrivenExecution: true,
        strategyOverrides: {first.id: first, second.id: second},
      );
      engine.process(_bar(time));
      engine.processQuote(_quote(time.add(const Duration(seconds: 1))));

      final a = engine.accounts['Portfolio A']!;
      final b = engine.accounts['Portfolio B']!;
      expect(a.positions['SOXL']!.quantity, 2);
      expect(b.positions['SOXL']!.quantity, 4);
      expect(a.cash, lessThan(1000));
      expect(b.cash, lessThan(2000));
      expect(a.events.where((event) => event.kind == 'fill'), hasLength(1));
      expect(b.events.where((event) => event.kind == 'fill'), hasLength(1));
    });

    test('a live order waits for a later quote and buys at the ask', () {
      final time = DateTime.utc(2026, 5, 4, 14);
      final strategy = _AlwaysBuy('fixture');
      final engine = SimulatorEngine(
        watchlist: const ['SOXL'],
        strategies: [StrategySettings(strategyId: 'fixture', label: 'Fixture')],
        startingCash: 10000,
        quoteDrivenExecution: true,
        strategyOverrides: {strategy.id: strategy},
      );
      engine.process(_bar(time));
      expect(engine.accounts['Fixture']!.pending, hasLength(1));
      expect(
        engine.accounts['Fixture']!.events.where(
          (event) => event.kind == 'fill',
        ),
        isEmpty,
      );

      engine.processQuote(_quote(time));
      expect(engine.accounts['Fixture']!.pending, hasLength(1));
      engine.processQuote(
        _quote(time.add(const Duration(seconds: 1)), bid: 100, ask: 101),
      );
      final account = engine.accounts['Fixture']!;
      expect(account.pending, isEmpty);
      expect(
        account.events.where((event) => event.kind == 'fill'),
        hasLength(1),
      );
      expect(account.positions['SOXL']!.entryPrice, closeTo(101.0404, .001));
      expect(strategy.id, 'fixture');
    });

    test('realized P&L includes both entry and exit fees', () {
      final time = DateTime.utc(2026, 5, 4, 14);
      final strategy = _BuyThenSell();
      final engine = SimulatorEngine(
        watchlist: const ['SOXL'],
        strategies: [
          StrategySettings(strategyId: strategy.id, label: 'Fixture'),
        ],
        startingCash: 10000,
        quoteDrivenExecution: true,
        spreadBps: 0,
        slippageBps: 0,
        feePerShare: .1,
        strategyOverrides: {strategy.id: strategy},
      );
      engine.process(_bar(time, close: 100));
      engine.processQuote(
        _quote(time.add(const Duration(seconds: 1)), bid: 100, ask: 101),
      );
      final quantity = engine.accounts['Fixture']!.positions['SOXL']!.quantity;
      engine.process(_bar(time.add(const Duration(minutes: 1)), close: 105));
      engine.processQuote(
        _quote(
          time.add(const Duration(minutes: 1, seconds: 1)),
          bid: 105,
          ask: 106,
        ),
      );
      expect(
        engine.accounts['Fixture']!.closedPnl.single,
        closeTo((105 - 101) * quantity - .2 * quantity, .0001),
      );
    });

    test('checkpoint restores pending orders and prevents duplicate fills', () {
      final time = DateTime.utc(2026, 5, 4, 14);
      final strategy = _AlwaysBuy('fixture');
      final settings = [
        StrategySettings(strategyId: 'fixture', label: 'Fixture'),
      ];
      final engine = SimulatorEngine(
        watchlist: const ['SOXL'],
        strategies: settings,
        startingCash: 10000,
        quoteDrivenExecution: true,
        strategyOverrides: {strategy.id: strategy},
      );
      engine.process(_bar(time));
      final saved =
          jsonDecode(jsonEncode(engine.checkpoint())) as Map<String, dynamic>;
      final restored = SimulatorEngine.restore(
        watchlist: const ['SOXL'],
        strategies: settings,
        startingCash: 10000,
        checkpoint: saved,
        strategyOverrides: {strategy.id: strategy},
      );
      restored.process(_bar(time));
      expect(restored.accounts['Fixture']!.pending, hasLength(1));
      final quote = _quote(time.add(const Duration(seconds: 1)));
      restored.processQuote(quote);
      final afterFill =
          jsonDecode(jsonEncode(restored.checkpoint())) as Map<String, dynamic>;
      final recoveredAgain = SimulatorEngine.restore(
        watchlist: const ['SOXL'],
        strategies: settings,
        startingCash: 10000,
        checkpoint: afterFill,
        strategyOverrides: {strategy.id: strategy},
      );
      recoveredAgain.processQuote(quote);
      expect(
        recoveredAgain.accounts['Fixture']!.events.where(
          (event) => event.kind == 'fill',
        ),
        hasLength(1),
      );
      expect(recoveredAgain.accounts['Fixture']!.positions['SOXL'], isNotNull);
    });
  });

  group('live data validation', () {
    test('stale quotes pause fills and valid data resumes after reconnect', () {
      var now = DateTime.utc(2026, 5, 4, 14);
      final runtime = LiveSimulationRuntime(
        watchlist: const ['SOXL'],
        strategies: const [],
        startingCash: 1000,
        clock: () => now,
      );
      runtime.setConnected(true);
      runtime.begin();
      expect(
        runtime.onQuote(_quote(now.subtract(const Duration(seconds: 30)))),
        isFalse,
      );
      expect(runtime.healthFor('SOXL').state, FeedState.stale);

      now = now.add(const Duration(seconds: 1));
      expect(runtime.onQuote(_quote(now)), isTrue);
      runtime.setConnected(false, reason: 'Connection lost.');
      now = now.add(const Duration(seconds: 1));
      expect(runtime.onQuote(_quote(now)), isFalse);
      runtime.setConnected(true);
      now = now.add(const Duration(seconds: 1));
      expect(runtime.onQuote(_quote(now)), isTrue);
      expect(runtime.healthFor('SOXL').state, FeedState.live);
    });

    test('a silent connected stream becomes stale', () {
      var now = DateTime.utc(2026, 5, 4, 14);
      final runtime = LiveSimulationRuntime(
        watchlist: const ['SOXL'],
        strategies: const [],
        startingCash: 1000,
        clock: () => now,
      );
      runtime.setConnected(true);
      runtime.begin();
      expect(runtime.onQuote(_quote(now)), isTrue);
      now = now.add(const Duration(seconds: 11));
      runtime.checkFreshness();
      expect(runtime.healthFor('SOXL').state, FeedState.stale);
    });

    test('calendar excludes holidays and shortens early-close sessions', () {
      expect(UsEquityCalendar.sessionAt(DateTime.utc(2026, 7, 3, 14)), isNull);
      final session = UsEquityCalendar.sessionAt(
        DateTime.utc(2026, 11, 27, 16, 30),
      );
      expect(session, isNotNull);
      expect(session!.durationMinutes, 210);
      expect(session.elapsedMinutes, 120);
    });

    test('session candle builder drops gaps without inventing bars', () {
      final builder = SessionCandleBuilder(symbol: 'SOXL', intervalMinutes: 1);
      LiveQuote quoteAt(int minute) {
        final time = DateTime.utc(2026, 5, 4, 13, 30 + minute);
        return _quote(time);
      }

      expect(builder.add(quoteAt(0)), isNull);
      final completed = builder.add(quoteAt(1));
      expect(completed, isNotNull);
      expect(completed!.time, DateTime.utc(2026, 5, 4, 13, 31));
      expect(builder.add(quoteAt(4)), isNull);
      expect(builder.gapDetected, isTrue);
    });

    test(
      'session change drops old final candles rather than trading stale signals',
      () {
        final builder = SessionCandleBuilder(
          symbol: 'SOXL',
          intervalMinutes: 1,
        );
        final unfinished = _quote(DateTime.utc(2026, 5, 4, 13, 30));
        builder.add(unfinished);
        expect(builder.add(_quote(DateTime.utc(2026, 5, 5, 13, 30))), isNull);
        expect(builder.gapDetected, isTrue);

        final finalBarBuilder = SessionCandleBuilder(
          symbol: 'SOXL',
          intervalMinutes: 1,
        );
        finalBarBuilder.add(_quote(DateTime.utc(2026, 5, 4, 19, 59)));
        final completed = finalBarBuilder.add(
          _quote(DateTime.utc(2026, 5, 5, 13, 30)),
        );
        expect(completed, isNull);
        expect(finalBarBuilder.gapDetected, isTrue);
      },
    );
  });

  test('Fibonacci waits for pivot confirmation before buying the pullback', () {
    final time = DateTime.utc(2026, 5, 4, 14);
    final values = <List<double>>[
      [10, 11, 9, 10],
      [10, 11, 8, 9],
      [9, 10, 5, 7],
      [7, 9, 6, 8],
      [8, 12, 8, 11],
      [11, 15, 10, 14],
      [14, 14.5, 12, 13],
      [12, 13, 11, 10.9],
      [11, 12, 10.8, 11.1],
    ];
    final bars = values.indexed.map((entry) {
      final (index, row) = entry;
      return Candle(
        symbol: 'SOXL',
        time: time.add(Duration(minutes: index)),
        open: row[0],
        high: row[1],
        low: row[2],
        close: row[3],
        volume: 100,
      );
    }).toList();
    final strategy = StrategyRegistry.byId('fibonacci');
    StrategySignal evaluate(List<Candle> input) => strategy.evaluate(
      StrategyContext(
        candles: input,
        watchlist: {'SOXL': input},
        hasPosition: false,
        entryPrice: null,
        parameters: const {
          'pivotWindow': 1,
          'retracementLevel': .5,
          'extension': 1.618,
        },
      ),
    );

    expect(evaluate(bars.take(6).toList()).action, TradeAction.wait);
    expect(evaluate(bars.take(8).toList()).action, TradeAction.wait);
    final confirmed = evaluate(bars);
    expect(confirmed.action, TradeAction.buy);
    expect(
      confirmed.measurements.keys,
      containsAll(['swingLow', 'swingHigh', 'zoneLow', 'zoneHigh']),
    );
  });

  test('LM Studio failure does not stop deterministic strategies', () async {
    final client = LmStudioClient(
      baseUrl: 'http://127.0.0.1:1',
      model: 'offline-model',
      timeout: const Duration(milliseconds: 100),
    );
    expect(client.testToolCalling, throwsA(anything));
    client.close();

    final candles = List<Candle>.generate(
      24,
      (index) => Candle(
        symbol: 'SOXL',
        time: DateTime.utc(2026, 5, 4, 14).add(Duration(minutes: index)),
        open: 100 + index.toDouble(),
        high: 102 + index.toDouble(),
        low: 99 + index.toDouble(),
        close: 101 + index.toDouble(),
        volume: 1000,
      ),
    );
    final signal = StrategyRegistry.byId('rule_selector').evaluate(
      StrategyContext(
        candles: candles,
        watchlist: {'SOXL': candles},
        hasPosition: false,
        entryPrice: null,
        parameters: const {},
      ),
    );
    expect(signal.action, isNot(TradeAction.sell));
  });

  test('warm-up event reports the collected bar count', () {
    final engine = SimulatorEngine(
      watchlist: const ['SOXL'],
      strategies: [
        StrategySettings(strategyId: 'support_bounce', label: 'Support'),
      ],
      startingCash: 10000,
      includeBenchmarks: false,
    );
    engine.process(_bar(DateTime.utc(2026, 5, 4, 14)));

    expect(
      engine.accounts['Support']!.events.single.reason,
      'Warm-up: 1/12 bars.',
    );
  });

  test('volatility squeeze signals exits on failure and max hold time', () {
    final strategy = StrategyRegistry.byId('volatility_squeeze');
    final bars = List<Candle>.generate(
      strategy.warmupBars,
      (index) => Candle(
        symbol: 'SOXL',
        time: DateTime.utc(2026, 5, 4, 14).add(Duration(minutes: index)),
        open: 99,
        high: 101,
        low: 98,
        close: 99,
        volume: 100,
      ),
    );
    StrategySignal evaluate({required double? stop, required int held}) =>
        strategy.evaluate(
          StrategyContext(
            candles: bars,
            watchlist: {'SOXL': bars},
            hasPosition: true,
            entryPrice: 100,
            positionStop: stop,
            parameters: const {'maxHoldBars': 20},
            barsHeld: held,
          ),
        );

    expect(evaluate(stop: 100, held: 2).action, TradeAction.sell);
    expect(evaluate(stop: null, held: 20).action, TradeAction.sell);
  });

  test('same-time symbol candles replace the portfolio equity mark', () {
    final strategy = _AlwaysBuy('test_always_buy');
    final engine = SimulatorEngine(
      watchlist: const ['SOXL', 'OKLO'],
      strategies: [
        StrategySettings(
          strategyId: strategy.id,
          label: 'Independent test portfolio',
        ),
      ],
      startingCash: 10000,
      includeBenchmarks: false,
      strategyOverrides: {strategy.id: strategy},
    );
    final time = DateTime.utc(2026, 5, 4, 14);
    engine.process(_bar(time, close: 100));
    engine.process(
      Candle(
        symbol: 'OKLO',
        time: time,
        open: 50,
        high: 51,
        low: 49,
        close: 50,
        volume: 100,
      ),
    );

    final history = engine.accounts['Independent test portfolio']!.history;
    expect(history, hasLength(1));
    expect(history.single.time, time);
  });

  test('LM selector preserves explicit inverse-gap short entries', () {
    final selector = LmStudioSelectorStrategy()
      ..setSelection(
        'Selector',
        'SOXL',
        const LmStudioSelection(
          strategyId: 'inverse_fair_value_gap',
          toolName: 'inverse_fair_value_gap',
          reason: 'Fixture selection',
        ),
      );
    final rows = <List<double>>[
      [99, 100, 98, 99],
      [101, 103, 100, 102],
      [103, 104, 102, 103],
      [101, 102, 98, 99],
      [100.5, 101, 98.5, 99],
    ];
    final bars = rows.indexed
        .map(
          (entry) => Candle(
            symbol: 'SOXL',
            time: DateTime.utc(2026, 5, 4, 14, entry.$1),
            open: entry.$2[0],
            high: entry.$2[1],
            low: entry.$2[2],
            close: entry.$2[3],
            volume: 100,
          ),
        )
        .toList();
    final signal = selector.evaluate(
      StrategyContext(
        candles: bars,
        watchlist: const {},
        hasPosition: false,
        entryPrice: null,
        parameters: const {},
        portfolioLabel: 'Selector',
      ),
    );
    expect(signal.action, TradeAction.sell);
    expect(signal.side, PositionSide.short);
    expect(signal.positionEffect, PositionEffect.open);
    expect(signal.sourceStrategyId, 'inverse_fair_value_gap');
    final holding = selector.evaluate(
      StrategyContext(
        candles: bars,
        watchlist: const {},
        hasPosition: true,
        entryPrice: 99,
        positionStop: 105,
        positionSide: PositionSide.short,
        parameters: const {},
        portfolioLabel: 'Selector',
      ),
    );
    expect(holding.action, TradeAction.wait);
  });

  test(
    'LM selector evaluates the chosen registry rule and records its source',
    () {
      final selector = LmStudioSelectorStrategy()
        ..setSelection(
          'Local selector',
          'SOXL',
          const LmStudioSelection(
            strategyId: 'rule_selector',
            parameters: {'trendThresholdPercent': .1},
            toolName: 'inspect_rule_selector',
            reason: 'Strong upward trend.',
          ),
        );
      final bars = List<Candle>.generate(
        22,
        (index) => Candle(
          symbol: 'SOXL',
          time: DateTime.utc(2026, 5, 4, 14).add(Duration(minutes: index)),
          open: 100.0 + index,
          high: 102.0 + index,
          low: 99.0 + index,
          close: 101.0 + index,
          volume: 1000,
        ),
      );
      final signal = selector.evaluate(
        StrategyContext(
          candles: bars,
          watchlist: {'SOXL': bars},
          hasPosition: false,
          entryPrice: null,
          parameters: const {},
          portfolioLabel: 'Local selector',
        ),
      );

      expect(signal.action, TradeAction.buy);
      expect(signal.sourceStrategyId, 'rule_selector');
      expect(signal.reason, contains('Rule-based strategy selector'));
    },
  );

  test('live LM clients retain a configurable response timeout', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) {
      unawaited(request.drain<void>());
    });
    final client = LmStudioClient(
      baseUrl: 'http://127.0.0.1:${server.port}',
      model: 'fixture-model',
      timeout: const Duration(milliseconds: 50),
    );
    final defaultClient = LmStudioClient(
      baseUrl: 'http://127.0.0.1:${server.port}',
      model: 'fixture-model',
    );
    addTearDown(() async {
      client.close();
      defaultClient.close();
      await subscription.cancel();
      await server.close(force: true);
    });
    expect(defaultClient.timeout, const Duration(seconds: 15));
    await expectLater(
      client.selectStrategy(
        eligibleStrategyIds: const {'donchian'},
        snapshot: const {'currentSymbol': 'SOXL'},
      ),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('LM Studio tool choice is restricted to eligible strategies', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requestBody = Completer<Map<String, dynamic>>();
    final subscription = server.listen((request) async {
      final decoded = jsonDecode(await utf8.decoder.bind(request).join());
      if (decoded is Map<String, dynamic>) requestBody.complete(decoded);
      request.response
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'content': '',
                  'tool_calls': [
                    {
                      'id': 'fixture-call',
                      'type': 'function',
                      'function': {
                        'name': 'inspect_rule_selector',
                        'arguments': jsonEncode({
                          'symbol': 'SOXL',
                          'trendThresholdPercent': .1,
                          'reason': 'Trend is rising.',
                        }),
                      },
                    },
                  ],
                },
              },
            ],
          }),
        );
      await request.response.close();
    });
    addTearDown(() async {
      await subscription.cancel();
      await server.close(force: true);
    });
    final client = LmStudioClient(
      baseUrl: 'http://127.0.0.1:${server.port}',
      model: 'fixture-model',
    );
    addTearDown(client.close);

    final selection = await client.selectStrategy(
      eligibleStrategyIds: const {'rule_selector'},
      snapshot: const {'currentSymbol': 'SOXL'},
    );
    final request = await requestBody.future;

    expect(selection.strategyId, 'rule_selector');
    expect(selection.parameters['trendThresholdPercent'], .1);
    expect(selection.reason, 'Trend is rising.');
    final tools = request['tools'] as List<dynamic>;
    expect(tools, hasLength(2));
    expect(
      tools.map((tool) => (tool as Map<String, dynamic>)['function']['name']),
      containsAll(['inspect_rule_selector', 'wait']),
    );
  });
}
