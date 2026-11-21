import 'package:atrader/backend_api.dart';
import 'package:atrader/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _PopulationApi extends BackendApi {
  int generation = 2;
  final gets = <String>[];
  final posts = <(String, Map<String, Object?>)>[];
  final configuration = <String, dynamic>{
    'mode': 'historical',
    'watchlist': ['SOXL'],
    'startingCash': 10000,
    'benchmarks': {'buyAndHold': false, 'equalWeight': false},
    'strategies': [
      {
        'strategyId': 'ma_crossover',
        'label': 'MA',
        'enabled': true,
        'intervalMinutes': 1,
        'parameters': {'fastPeriod': 2, 'slowPeriod': 4},
      },
    ],
  };
  Map<String, Object?> member(int g) => {
    'id': 'I000001',
    'rank': 1,
    'parents': <String>[],
    'birthGeneration': 1,
    'elite': true,
    'champion': true,
    'mutationAmount': 0,
    'solidification': .5,
    'fitness': 1.5,
    'parameters': {'fastPeriod': 2.0, 'slowPeriod': 4.0},
    'performance': {
      'netProfit': 10.0 * g,
      'returnPercent': .1 * g,
      'winRatePercent': 75.0,
      'closedTrades': 4,
      'maxDrawdownPercent': 1.0,
    },
  };
  @override
  Future<Map<String, dynamic>> get(String path) async {
    gets.add(path);
    final uri = Uri.parse(path);
    if (uri.path == '/api/evolution/population') {
      final g =
          int.tryParse(uri.queryParameters['generation'] ?? '') ?? generation;
      return {
        'sessionId': 'session',
        'generation': g,
        'latestGeneration': generation,
        'strategies': ['MA'],
        'strategy': 'MA',
        'championId': 'I000001',
        'individuals': [member(g)],
        if (uri.queryParameters['individual'] != null)
          'individual': {
            ...member(g),
            'account': {
              'startingCash': 10000,
              'equity': 10000 + 10.0 * g,
              'closedPnl': [10.0 * g],
              'history': [
                {'time': '2026-05-04T14:00:00Z', 'value': 10000.0},
                {'time': '2026-05-04T15:00:00Z', 'value': 10000 + 10.0 * g},
              ],
            },
          },
      };
    }
    return switch (uri.path) {
      '/api/status' => {
        'workspaceMode': true,
        'workspaceId': 'source',
        'runId': 'research-preview',
        'researchPreview': true,
        'configurationLocked': true,
        'running': false,
        'schwabAuthorized': true,
        'configuration': configuration,
        'research': {
          'cycles': generation,
          'running': false,
          'sessionId': 'session',
        },
        'trainingSession': {
          'cycles': generation,
          'evolutionLimit': 10,
          'source': configuration,
        },
        'historicalTimeZones': ['America/Denver'],
        'runs': [
          {'id': 'source', 'name': 'Old profile'},
        ],
      },
      '/api/snapshot' => {'accounts': <Object?>[]},
      '/api/log' => {'events': <Object?>[]},
      _ => throw StateError('Unexpected $path'),
    };
  }

  @override
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, Object?> body,
  ) async {
    posts.add((path, body));
    return {};
  }
}

void main() {
  testWidgets(
    'individual performance opens metrics and charts and follows chosen generations',
    (tester) async {
      final api = _PopulationApi();
      final controller = DashboardController(api: api);
      await controller.refresh();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AnimatedBuilder(
              animation: controller,
              builder: (_, _) => PopulationPerformance(controller: controller),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Population performance'));
      await tester.pumpAndSettle();
      expect(find.text('I000001 ★ champion'), findsOneWidget);
      expect(find.text('20.00'), findsOneWidget);
      await tester.tap(find.text('I000001 ★ champion'));
      await tester.pumpAndSettle();
      expect(find.text('Variables'), findsOneWidget);
      expect(find.text('fastPeriod: 2.0'), findsOneWidget);
      expect(find.byType(EquityChart), findsNWidgets(2));
      expect(find.text('Copy individual JSON'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Previous population'));
      await tester.pumpAndSettle();
      expect(find.text('10.00'), findsOneWidget);
      api.generation = 3;
      await controller.refresh();
      await tester.pumpAndSettle();
      expect(find.text('10.00'), findsOneWidget);
      await tester.tap(find.text('Follow latest'));
      await tester.pumpAndSettle();
      expect(find.text('30.00'), findsOneWidget);
      expect(api.gets.any((p) => p.contains('individual=I000001')), true);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets(
    'one workspace keeps setup accessible from the preview without profile controls',
    (tester) async {
      final api = _PopulationApi();
      final controller = DashboardController(api: api);
      await controller.refresh();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AnimatedBuilder(
              animation: controller,
              builder: (_, _) => DashboardView(controller: controller),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Simulation controls'));
      await tester.pumpAndSettle();
      expect(find.byType(RunSetupView), findsOneWidget);
      expect(find.text('Simulation run'), findsNothing);
      expect(find.text('New simulation'), findsNothing);
      expect(find.text('Rename simulation'), findsNothing);
      expect(find.text('Delete simulation'), findsNothing);
      final population = find.byKey(const ValueKey('population-size'));
      await tester.ensureVisible(population);
      await tester.pumpAndSettle();
      await tester.enterText(population, '30');
      api.generation = 3;
      await controller.refresh();
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(population).controller!.text, '30');
      await controller.setAutoResearch(true, generations: 20, resume: true);
      expect(api.posts.single.$2['runId'], 'source');
      expect(api.posts.single.$2['resume'], true);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );
}
