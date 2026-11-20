/// Single-file algorithm: metadata, evolvable parameters, and decisions.
library;

import '../strategy_api.dart';
import 'helpers.dart';

class VwapReclaimStrategy extends BuiltinStrategy {
  VwapReclaimStrategy()
    : super(
        id: 'vwap_reclaim',
        name: 'VWAP reclaim',
        description:
            'Buy when price reclaims the estimated session VWAP with the '
            'configured number of confirming bars. VWAP uses candle prices and '
            'volume, so it is an estimate and may cover only part of the session.',
        warmupBars: 5,
        parameters: [strategyParameter('confirmationBars', 'bars', 1, 1, 5)],
        rule: (c) {
          final sessionStart = sessionStartIndex(c.candles);
          final session = c.candles.skip(sessionStart);
          var pv = 0.0;
          var volume = 0.0;
          for (final bar in session) {
            pv += (bar.high + bar.low + bar.close) / 3 * bar.volume;
            volume += bar.volume;
          }
          final vwap = volume == 0 ? c.current.close : pv / volume;
          final confirmationBars = c.parameter('confirmationBars', 1).round();
          final confirmationStart = c.candles.length - confirmationBars;
          final priorIndex = confirmationStart - 1;
          final confirmedReclaim =
              priorIndex >= sessionStart &&
              c.candles[priorIndex].close <= vwap &&
              c.candles
                  .skip(confirmationStart)
                  .take(confirmationBars)
                  .every((bar) => bar.close > vwap);
          final coverage = c.sessionElapsedMinutes;
          final sessionLength = c.sessionLengthMinutes;
          final measurements = <String, double>{
            'estimatedVwap': vwap,
            'sessionBars': (c.candles.length - sessionStart).toDouble(),
            if (coverage != null) 'sessionCoverageMinutes': coverage.toDouble(),
            if (sessionLength != null)
              'sessionLengthMinutes': sessionLength.toDouble(),
          };
          if (!c.hasPosition && confirmedReclaim) {
            return StrategySignal(
              TradeAction.buy,
              'Price reclaimed bar-derived estimated session VWAP after $confirmationBars confirming bar(s).',
              stop: vwap * .98,
              measurements: measurements,
            );
          }
          if (c.hasPosition && c.current.close < vwap * .98) {
            return const StrategySignal(
              TradeAction.sell,
              'Price lost estimated session VWAP.',
            );
          }
          return StrategySignal(
            TradeAction.wait,
            coverage != null &&
                    sessionLength != null &&
                    coverage < sessionLength
                ? 'Waiting for VWAP reclaim; the bar-derived estimate covers only $coverage of $sessionLength regular-session minutes so far.'
                : 'Waiting for a session VWAP reclaim.',
            measurements: measurements,
          );
        },
      );
}
