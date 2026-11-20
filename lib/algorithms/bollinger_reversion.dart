/// Single-file algorithm: metadata, evolvable parameters, and decisions.
library;

import '../strategy_api.dart';
import 'helpers.dart';

class BollingerReversionStrategy extends BuiltinStrategy {
  BollingerReversionStrategy()
    : super(
        id: 'bollinger_reversion',
        name: 'Bollinger Band mean reversion',
        description:
            'In a weak trend, buy after price moves below the lower Bollinger '
            'Band and closes back inside. Exit at the middle band or after the '
            'configured time limit.',
        warmupBars: 22,
        parameters: [
          strategyParameter('period', 'bars', 20, 5, 100),
          strategyParameter('deviations', 'standard deviations', 2, 1, 4),
          strategyParameter('maximumHoldBars', 'bars', 30, 1, 500),
        ],
        rule: (c) {
          final bars = c.candles;
          final period = c.parameter('period', 20).round();
          final closes = bars
              .skip(bars.length - period)
              .map((b) => b.close)
              .toList();
          final mid = mean(closes);
          final lower =
              mid - c.parameter('deviations', 2) * standardDeviation(closes);
          final prior = bars[bars.length - 2].close;
          if (!c.hasPosition &&
              prior < lower &&
              bars.last.close >= lower &&
              priceReturn(bars, period) < .08) {
            return StrategySignal(
              TradeAction.buy,
              'Close re-entered the lower band in a weak-trend regime.',
              target: mid,
              measurements: {'lowerBand': lower, 'middleBand': mid},
            );
          }
          if (c.hasPosition &&
              (bars.last.close >= mid ||
                  c.barsHeld >= c.parameter('maximumHoldBars', 30).round())) {
            return const StrategySignal(
              TradeAction.sell,
              'Mean-reversion target reached or holding time limit elapsed.',
            );
          }
          return StrategySignal(
            TradeAction.wait,
            'Waiting for lower-band re-entry in a weak trend.',
            measurements: {'lowerBand': lower, 'middleBand': mid},
          );
        },
      );
}
