import 'dart:math' as math;

import 'mountain_time.dart';

/// Produces a JSON-safe export without modifying the supplied checkpoint.
Map<String, Object?> buildRunDataExport(
  Map<String, dynamic> state, {
  required DateTime exportedAt,
  required String source,
  Map<String, Object?>? research,
  List<Map<String, Object?>> generations = const [],
}) => {
  'exportVersion': 1,
  'exportedAt': exportedAt.toUtc().toIso8601String(),
  'exportedAtMountain': MountainTime.format(exportedAt),
  'source': source,
  'metricDefinitions': {
    'netProfit':
        'Ending marked equity minus starting cash, including trading costs.',
    'winRatePercent':
        'Profitable closed trades divided by all closed trades times 100.',
    'profitFactor':
        'Gross winning P&L divided by absolute losing P&L. Null when there are no losses.',
    'maxDrawdownPercent':
        'Largest percentage decline from a prior equity peak.',
    'noClosedTrades':
        'Win rate and average trade metrics are null until a trade closes.',
  },
  'savedState': state,
  'performance': performanceByRun(state),
  'research': ?research,
  'generations': generations,
};

List<Map<String, Object?>> performanceByRun(Map<String, dynamic> state) {
  final runs = state['runs'] is List
      ? (state['runs'] as List).cast<Map>()
      : [
          {...state, 'id': 'run-1', 'name': 'Simulation 1'},
        ];
  return [
    for (final run in runs)
      {
        'runId': run['id'],
        'runName': run['name'],
        'portfolios': [
          for (final engine
              in ((run['runtime'] as Map?)?['engines'] as Map? ?? const {})
                  .entries)
            for (final account
                in ((engine.value as Map)['accounts'] as Map? ?? const {})
                    .entries)
              {
                'label': account.key,
                'intervalMinutes': int.tryParse('${engine.key}'),
                ...portfolioPerformance(
                  Map<String, dynamic>.from(account.value as Map),
                  defaultStartingCash:
                      ((run['settings'] as Map?)?['startingCash'] as num?)
                          ?.toDouble() ??
                      10000,
                ),
              },
        ],
      },
  ];
}

Map<String, Object?> portfolioPerformance(
  Map<String, dynamic> account, {
  required double defaultStartingCash,
}) {
  final start =
      (account['startingCash'] as num?)?.toDouble() ?? defaultStartingCash;
  final history = (account['history'] as List? ?? const []).cast<Map>();
  final equity =
      (account['equity'] as num?)?.toDouble() ??
      (history.isEmpty ? start : (history.last['value'] as num).toDouble());
  final trades = (account['closedPnl'] as List? ?? const []).cast<num>();
  final wins = trades.where((pnl) => pnl > 0).toList();
  final losses = trades.where((pnl) => pnl < 0).toList();
  final grossProfit = wins.fold(0.0, (sum, pnl) => sum + pnl);
  final grossLoss = -losses.fold(0.0, (sum, pnl) => sum + pnl);
  final realized = trades.fold(0.0, (sum, pnl) => sum + pnl);
  var peak = start;
  var drawdown = 0.0;
  for (final value in [
    for (final point in history) (point['value'] as num).toDouble(),
    equity,
  ]) {
    peak = math.max(peak, value);
    if (peak > 0) drawdown = math.max(drawdown, (peak - value) / peak * 100);
  }
  return {
    'startingCash': start,
    'endingEquity': equity,
    'netProfit': equity - start,
    'returnPercent': start == 0 ? null : (equity / start - 1) * 100,
    'realizedNetPnl': realized,
    'unrealizedNetPnl': equity - start - realized,
    'closedTrades': trades.length,
    'winningTrades': wins.length,
    'losingTrades': losses.length,
    'breakevenTrades': trades.length - wins.length - losses.length,
    'winRatePercent': trades.isEmpty ? null : wins.length / trades.length * 100,
    'grossProfit': grossProfit,
    'grossLoss': grossLoss,
    'profitFactor': grossLoss == 0 ? null : grossProfit / grossLoss,
    'averageTradePnl': trades.isEmpty ? null : realized / trades.length,
    'averageWin': wins.isEmpty ? null : grossProfit / wins.length,
    'averageLoss': losses.isEmpty ? null : -grossLoss / losses.length,
    'bestTradePnl': trades.isEmpty
        ? null
        : trades.reduce((a, b) => a > b ? a : b),
    'worstTradePnl': trades.isEmpty
        ? null
        : trades.reduce((a, b) => a < b ? a : b),
    'maxDrawdownPercent': drawdown,
    'openPositions': (account['positions'] as List? ?? const []).length,
    'pendingOrders': (account['pending'] as List? ?? const []).length,
    'recordedEvents': (account['events'] as List? ?? const []).length,
  };
}
