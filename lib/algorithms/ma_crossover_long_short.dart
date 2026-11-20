/// Single-file algorithm: metadata, evolvable parameters, and decisions.
library;

import '../strategy_api.dart';
import 'helpers.dart';

class MaCrossoverLongShortStrategy extends BuiltinStrategy {
  MaCrossoverLongShortStrategy()
    : super(
        id: 'ma_crossover_long_short',
        name: 'Moving-average crossover (long/short)',
        description:
            'Go LONG after the fast average crosses above the slow one and '
            'SHORT after it crosses below. The opposite cross closes the trade, '
            'and a fresh entry may follow within the entry window. Shorts '
            'require short selling enabled in Risk.',
        warmupBars: 24,
        parameters: [
          strategyParameter('fastPeriod', 'bars', 5, 2, 30),
          strategyParameter('slowPeriod', 'bars', 20, 4, 100),
          strategyParameter('entryWindowBars', 'bars', 2, 1, 10),
        ],
        rule: _maCrossoverLongShort,
      );
}

StrategySignal _maCrossoverLongShort(StrategyContext c) {
  final bars = c.candles;
  final fast = c.parameter('fastPeriod', 5).round();
  final slow = c.parameter('slowPeriod', 20).round();
  final window = c.parameter('entryWindowBars', 2).round();
  final currentFast = averageClose(bars, fast);
  final currentSlow = averageClose(bars, slow);
  final previousFast = averageClose(bars, fast, 1);
  final previousSlow = averageClose(bars, slow, 1);
  final crossedUp = previousFast <= previousSlow && currentFast > currentSlow;
  final crossedDown = previousFast >= previousSlow && currentFast < currentSlow;
  final measurements = {'fastAverage': currentFast, 'slowAverage': currentSlow};
  if (c.hasPosition) {
    final short = c.positionSide == PositionSide.short;
    if (!short && crossedDown) {
      return closePosition(c, 'Fast average crossed below slow; exit long.');
    }
    if (short && crossedUp) {
      return closePosition(c, 'Fast average crossed above slow; cover short.');
    }
    return StrategySignal(
      TradeAction.wait,
      'Holding ${short ? 'short' : 'long'} until the opposite cross.',
      measurements: measurements,
    );
  }
  // A cross that just closed the prior trade may still open the new side.
  int? age;
  for (var offset = 0; offset < window; offset++) {
    if (bars.length - offset - 1 < slow) break;
    final f = averageClose(bars, fast, offset);
    final s = averageClose(bars, slow, offset);
    final pf = averageClose(bars, fast, offset + 1);
    final ps = averageClose(bars, slow, offset + 1);
    if ((pf <= ps && f > s) || (pf >= ps && f < s)) {
      age = offset;
      break;
    }
  }
  if (age != null && currentFast > currentSlow) {
    return longEntry(
      'Fast average crossed above slow average${age == 0 ? '' : ' $age bar(s) ago'}.',
      measurements: measurements,
    );
  }
  if (age != null && currentFast < currentSlow) {
    return shortEntry(
      'Fast average crossed below slow average${age == 0 ? '' : ' $age bar(s) ago'}.',
      stop: bars.last.close * 1.03,
      measurements: measurements,
    );
  }
  return StrategySignal(
    TradeAction.wait,
    'No recent moving-average crossover.',
    measurements: measurements,
  );
}
