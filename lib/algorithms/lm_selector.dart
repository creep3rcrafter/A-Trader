/// Single-file algorithm: metadata, evolvable parameters, and decisions.
library;

import '../strategy_api.dart';
import 'registry.dart';

class LmSelectorDefinition extends BuiltinStrategy {
  LmSelectorDefinition()
    : super(
        id: 'lm_selector',
        name: 'LM Studio strategy selector',
        description:
            'Ask the configured local LM Studio model to choose an eligible '
            'registered strategy or WAIT. The chosen strategy evaluator and all '
            'risk checks remain in Dart; model failures record WAIT.',
        warmupBars: 22,
        parameters: const [],
        rule: (_) => const StrategySignal(
          TradeAction.wait,
          'Waiting for an LM Studio strategy selection.',
        ),
      );
}

class LmStudioSelection {
  const LmStudioSelection({
    required this.toolName,
    required this.reason,
    this.strategyId,
    this.parameters = const {},
  });

  final String? strategyId;
  final Map<String, double> parameters;
  final String toolName;
  final String reason;
}

/// Synchronous simulator adapter using only a previously returned model choice.
/// The async network request is performed by LocalBackend, never the quote loop.
class LmStudioSelectorStrategy implements TradingStrategy {
  final Map<(String, String), LmStudioSelection> _selections = {};

  @override
  String get id => 'lm_selector';
  @override
  String get name => 'LM Studio strategy selector';
  @override
  String get description =>
      'Use a configured local model to choose a registered strategy or WAIT.';
  @override
  int get warmupBars => StrategyRegistry.byId(id).warmupBars;
  @override
  List<StrategyParameter> get parameters => const [];

  void setSelection(
    String portfolioLabel,
    String symbol,
    LmStudioSelection selection,
  ) {
    _selections[(portfolioLabel, symbol)] = selection;
  }

  void clearSelection(String portfolioLabel, String symbol) {
    _selections.remove((portfolioLabel, symbol));
  }

  bool hasSelection(String portfolioLabel, String symbol) =>
      _selections.containsKey((portfolioLabel, symbol));

  @override
  StrategySignal evaluate(StrategyContext context) {
    final selection =
        _selections[(context.portfolioLabel, context.current.symbol)];
    final strategyId = selection?.strategyId;
    if (selection == null || strategyId == null) {
      return StrategySignal(
        TradeAction.wait,
        selection?.reason ?? 'Waiting for an LM Studio strategy selection.',
      );
    }
    final selectedStrategy = StrategyRegistry.byId(strategyId);
    final signal = selectedStrategy.evaluate(
      StrategyContext(
        candles: context.candles,
        watchlist: context.watchlist,
        hasPosition: context.hasPosition,
        entryPrice: context.entryPrice,
        positionStop: context.positionStop,
        positionSide: context.positionSide,
        parameters: selection.parameters,
        intervalMinutes: context.intervalMinutes,
        sessionElapsedMinutes: context.sessionElapsedMinutes,
        sessionLengthMinutes: context.sessionLengthMinutes,
        barsHeld: context.barsHeld,
        portfolioLabel: context.portfolioLabel,
        executionId: context.executionId,
      ),
    );
    final explicitShortEntry =
        signal.side == PositionSide.short &&
        signal.positionEffect == PositionEffect.open;
    if (!context.hasPosition &&
        signal.action == TradeAction.sell &&
        !explicitShortEntry) {
      return StrategySignal(
        TradeAction.wait,
        'LM Studio selected ${selectedStrategy.name}, which requested an exit '
        'without an open position; no order was created.',
        measurements: signal.measurements,
      );
    }
    final opening =
        !context.hasPosition &&
        signal.action != TradeAction.wait &&
        (signal.positionEffect == PositionEffect.open ||
            signal.action == TradeAction.buy);
    return StrategySignal(
      signal.action,
      'LM Studio selected ${selectedStrategy.name}: ${signal.reason}',
      stop: signal.stop,
      target: signal.target,
      measurements: signal.measurements,
      side: signal.side,
      positionEffect: signal.positionEffect,
      sourceStrategyId: opening ? strategyId : null,
      sourceStrategyParameters: opening ? selection.parameters : const {},
    );
  }
}
