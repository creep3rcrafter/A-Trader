import 'dart:convert';
import 'dart:io';

import 'package:atrader/data_export_io.dart';
import 'package:atrader/run_data_export.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'writes a single JSON containing every run and portfolio performance',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'atrader-json-export-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final primary = File('${directory.path}/state.json');
      final backup = File('${primary.path}.bak');
      final old = _fixtureState(savedAt: '2026-11-16T20:00:00Z');
      final latest = {
        'savedAt': '2026-11-16T20:00:05Z',
        'runs': [
          {...old, 'id': 'one', 'name': 'First'},
          {...old, 'id': 'two', 'name': 'Second'},
        ],
      };
      await primary.writeAsString(jsonEncode(old));
      await backup.writeAsString(jsonEncode(latest));
      final path = await exportRunData(
        stateDirectoryPath: directory.path,
        exportDirectoryPath: '${directory.path}/output',
      );
      final files = await Directory('${directory.path}/output').list().toList();
      expect(files, hasLength(1));
      expect(path, endsWith('.json'));
      final json = jsonDecode(await File(path).readAsString()) as Map;
      expect(json['savedState'], latest);
      final performance = (json['performance'] as List).cast<Map>();
      expect(performance.map((run) => run['runId']), ['one', 'two']);
      final trend = (performance.first['portfolios'] as List).first as Map;
      expect(trend['endingEquity'], 10100);
      expect(trend['netProfit'], 100);
      expect(trend['winRatePercent'], 100);
      final empty = (performance.first['portfolios'] as List).last as Map;
      expect(empty['winRatePercent'], isNull);
      expect(await primary.readAsString(), jsonEncode(old));
      expect(await backup.readAsString(), jsonEncode(latest));
    },
  );

  test('profit metrics include losses, breakeven trades, and drawdown', () {
    final metrics = portfolioPerformance({
      'startingCash': 1000,
      'equity': 1100,
      'history': [
        {'value': 1200},
        {'value': 900},
        {'value': 1100},
      ],
      'closedPnl': [200, -50, 0, -25],
    }, defaultStartingCash: 1);
    expect(metrics['closedTrades'], 4);
    expect(metrics['winRatePercent'], 25);
    expect(metrics['realizedNetPnl'], 125);
    expect(metrics['unrealizedNetPnl'], -25);
    expect(metrics['maxDrawdownPercent'], 25);
    expect(metrics['profitFactor'], closeTo(200 / 75, 1e-9));
  });

  test(
    'exports backend data including research without needing a checkpoint',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'atrader-live-export-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final payload = {
        'performance': [
          {'winRatePercent': 50},
        ],
        'generations': [
          {'generation': 1, 'tuningResults': []},
        ],
        'savedState': {'runs': []},
      };
      final file = await exportRunData(
        stateDirectoryPath: '${directory.path}/missing',
        exportDirectoryPath: directory.path,
        data: payload,
      );
      expect(jsonDecode(await File(file).readAsString()), payload);
      expect(await directory.list().length, 1);
    },
  );
}

Map<String, dynamic> _fixtureState({required String savedAt}) => {
  'settings': {
    'watchlist': ['SOXL'],
    'startingCash': 10000,
    'strategies': [
      {'strategyId': 'trend_pullback', 'label': 'Trend'},
    ],
  },
  'savedAt': savedAt,
  'runtime': {
    'running': true,
    'engines': {
      '1': {
        'accounts': {
          'Trend': {
            'events': [
              {
                'time': savedAt,
                'strategy': 'Trend',
                'symbol': 'SOXL',
                'action': 'buy',
                'kind': 'fill',
                'price': 100,
                'reason': 'Fixture fill',
                'measurements': {'shares': 2},
              },
            ],
            'history': [
              {'time': savedAt, 'value': 10100},
            ],
            'positions': [
              {
                'symbol': 'SOXL',
                'quantity': 2,
                'entryPrice': 100,
                'entryTime': savedAt,
                'stop': 95,
                'target': 110,
                'entryFees': 1,
              },
            ],
            'pending': [],
            'closedPnl': [5],
          },
          'Mean Reversion': {
            'events': [],
            'history': [],
            'positions': [],
            'pending': [
              {
                'symbol': 'SOXL',
                'action': 'buy',
                'quantity': 3,
                'signalTime': savedAt,
                'reason': 'Pending fixture',
              },
            ],
            'closedPnl': [],
          },
        },
        'bars': {
          'SOXL': [
            {
              'symbol': 'SOXL',
              'time': savedAt,
              'open': 100,
              'high': 102,
              'low': 99,
              'close': 101,
              'volume': 500,
            },
          ],
        },
      },
    },
  },
};
