/// Single-file algorithm: metadata, evolvable parameters, and decisions.
library;

import '../strategy_api.dart';
import 'helpers.dart';

class RelativeStrengthStrategy extends BuiltinStrategy {
  RelativeStrengthStrategy()
    : super(
        id: 'relative_strength',
        name: 'Relative-strength rotation',
        description:
            'At scheduled rebalances, rank watchlist symbols by recent return '
            'and buy eligible leaders. Sell positions that leave the selected '
            'group; unused allocation stays in cash.',
        warmupBars: 21,
        parameters: [
          strategyParameter('lookback', 'bars', 20, 2, 100),
          strategyParameter('minimumReturnPercent', '%', 0, -50, 100),
          strategyParameter('leaders', 'symbols', 2, 1, 10),
          strategyParameter('rebalanceMinutes', 'minutes', 30, 1, 390),
        ],
        rule: (c) {
          final elapsed = c.sessionElapsedMinutes;
          final interval = c.parameter('rebalanceMinutes', 30).round();
          if (elapsed == null || elapsed <= 0 || elapsed % interval != 0) {
            return const StrategySignal(
              TradeAction.wait,
              'Waiting for the next scheduled in-session rebalance.',
            );
          }
          final ranking =
              c.watchlist.entries
                  .where(
                    (entry) => entry.value.length > c.parameter('lookback', 20),
                  )
                  .map(
                    (entry) => MapEntry(
                      entry.key,
                      priceReturn(
                        entry.value,
                        c.parameter('lookback', 20).round(),
                      ),
                    ),
                  )
                  .toList()
                ..sort((a, b) => b.value.compareTo(a.value));
          final leaderCount = c.parameter('leaders', 2).round();
          final selected = ranking
              .take(leaderCount)
              .where(
                (entry) =>
                    entry.value >= c.parameter('minimumReturnPercent', 0) / 100,
              )
              .map((e) => e.key)
              .toSet();
          if (selected.contains(c.current.symbol) && !c.hasPosition) {
            return StrategySignal(
              TradeAction.buy,
              'Selected as a trailing-return leader at the rebalance decision.',
              measurements: {
                'trailingReturnPercent':
                    priceReturn(
                      c.candles,
                      c.parameter('lookback', 20).round(),
                    ) *
                    100,
              },
            );
          }
          if (!selected.contains(c.current.symbol) && c.hasPosition) {
            return const StrategySignal(
              TradeAction.sell,
              'No longer among eligible rotation leaders.',
            );
          }
          return StrategySignal(
            TradeAction.wait,
            selected.contains(c.current.symbol)
                ? 'Maintaining eligible relative-strength leader.'
                : 'Not selected; unused allocation remains in cash.',
          );
        },
      );
}
