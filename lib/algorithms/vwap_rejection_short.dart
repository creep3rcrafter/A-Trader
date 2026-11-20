/// Single-file algorithm: metadata, evolvable parameters, and decisions.
library;

import 'dart:math' as math;

import '../strategy_api.dart';
import 'helpers.dart';

class VwapRejectionShortStrategy extends BuiltinStrategy {
  VwapRejectionShortStrategy()
    : super(
        id: 'vwap_rejection_short',
        name: 'VWAP rejection (short)',
        description:
            'SHORT when price loses the estimated session VWAP for the '
            'configured confirming bars. Cover when a close reclaims VWAP. '
            'Short entries require short selling enabled in Risk.',
        warmupBars: 5,
        parameters: [
          strategyParameter('confirmationBars', 'bars', 1, 1, 5),
          strategyParameter('stopPercent', '%', 1, .1, 10),
          strategyParameter('targetPercent', '%', 2, 0, 20),
        ],
        rule: _vwapRejectionShort,
      );
}

StrategySignal _vwapRejectionShort(StrategyContext c) {
  final bars = c.candles;
  final sessionStart = sessionStartIndex(bars);
  final vwap = sessionVwap(bars, sessionStart);
  final confirmationBars = c.parameter('confirmationBars', 1).round();
  final confirmationStart = bars.length - confirmationBars;
  final priorIndex = confirmationStart - 1;
  final measurements = <String, double>{
    'estimatedVwap': vwap,
    'sessionBars': (bars.length - sessionStart).toDouble(),
  };
  if (c.hasPosition) {
    if (c.positionSide == PositionSide.short && bars.last.close > vwap) {
      return closePosition(
        c,
        'Price reclaimed estimated session VWAP; cover the short.',
      );
    }
    return StrategySignal(
      TradeAction.wait,
      'Holding the VWAP rejection short.',
      measurements: measurements,
    );
  }
  final rejected =
      priorIndex >= sessionStart &&
      bars[priorIndex].close >= vwap &&
      bars
          .skip(confirmationStart)
          .take(confirmationBars)
          .every((bar) => bar.close < vwap);
  if (rejected) {
    final close = bars.last.close;
    final targetPercent = c.parameter('targetPercent', 2);
    return shortEntry(
      'Price lost bar-derived estimated session VWAP for $confirmationBars confirming bar(s).',
      stop: math.max(vwap, close) * (1 + c.parameter('stopPercent', 1) / 100),
      target: targetPercent > 0 ? close * (1 - targetPercent / 100) : null,
      measurements: measurements,
    );
  }
  return StrategySignal(
    TradeAction.wait,
    'Waiting for price to lose session VWAP.',
    measurements: measurements,
  );
}
