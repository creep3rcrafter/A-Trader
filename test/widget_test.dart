import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:atrader/backend_api.dart';
import 'package:atrader/algorithm_file.dart';
import 'package:atrader/mountain_time.dart';
import 'package:atrader/simulator.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:atrader/main.dart';

class _BackendApiFixture extends BackendApi {
  _BackendApiFixture({this.canLaunch = true});

  final bool canLaunch;
  final launch = Completer<void>();
  bool available = false;
  bool running = false;
  bool hasRunData = false;
  bool failReset = false;
  int launches = 0;
  int resets = 0;
  final Map<String, dynamic> statusFields = {};
  Map<String, dynamic>? snapshotFields;
  final Map<String, Map<String, dynamic>> snapshotsByRun = {};
  List<Map<String, dynamic>>? logEvents;
  final List<(String, Map<String, Object?>)> posts = [];
  final List<String> gets = [];
  final Map<int, Map<String, dynamic>> variableChangesByGeneration = {};
  final algorithmImport = Completer<void>();
  bool failAlgorithmImport = false;

  @override
  bool get supportsBackendLaunch => canLaunch;

  @override
  Future<void> startBackend() async {
    launches++;
    await launch.future;
    available = true;
  }

  @override
  Future<void> restartBackend() => startBackend();

  @override
  Future<Map<String, dynamic>> get(String path) async {
    if (!available) throw StateError('The backend is not running.');
    gets.add(path);
    final uri = Uri.parse(path);
    return switch (uri.path) {
      '/api/runs/variable-changes' =>
        variableChangesByGeneration[int.parse(
          uri.queryParameters['generation']!,
        )]!,
      '/api/status' => {
        'running': running,
        'feed': 'disconnected',
        ...statusFields,
      },
      '/api/snapshot' =>
        snapshotsByRun[uri.queryParameters['runId']] ??
            snapshotFields ??
            {
              'accounts': hasRunData
                  ? [
                      {'label': 'Test'},
                    ]
                  : <dynamic>[],
            },
      '/api/log' => {
        'events':
            logEvents ??
            (hasRunData
                ? [
                    {'kind': 'fill'},
                  ]
                : <dynamic>[]),
      },
      _ => throw StateError('Unexpected fixture request: $path'),
    };
  }

  @override
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, Object?> body,
  ) async {
    posts.add((path, body));
    if (path == '/api/algorithms/import') {
      await algorithmImport.future;
      if (failAlgorithmImport) throw StateError('Unknown variable "typo".');
      final metadata =
          jsonDecode(body['source'] as String) as Map<String, dynamic>;
      final imported = {
        'metadata': metadata,
        'filename': body['filename'],
        'kind': 'json',
      };
      statusFields['algorithms'] = [imported];
      return imported;
    }
    if (path == '/api/runs/select') {
      statusFields['runId'] = body['runId'];
      return {};
    }
    if (path == '/api/runs/create') {
      statusFields['runId'] = 'new';
      (statusFields['runs'] as List).add({
        'id': 'new',
        'name': body['name'] ?? 'New run',
        'running': false,
      });
      return {};
    }
    if (path == '/api/runs/rename') {
      final run = (statusFields['runs'] as List).cast<Map>().singleWhere(
        (run) => run['id'] == body['runId'],
      );
      run['name'] = body['name'];
      return {};
    }
    if (path == '/api/runs/delete') {
      final runs = statusFields['runs'] as List;
      runs.removeWhere((run) => run['id'] == body['runId']);
      statusFields['runId'] = runs.first['id'];
      return {};
    }
    if (path == '/api/research/start' || path == '/api/research/stop') {
      (statusFields['research'] as Map)['running'] =
          path == '/api/research/start';
      return {};
    }
    if (path == '/api/training/settings') {
      (statusFields['training'] as Map)['autoTraining'] = body['autoTrain'];
      return {};
    }
    if (path == '/api/training/train' ||
        path == '/api/settings/run' ||
        path == '/api/run/historical/start') {
      return {};
    }
    if (path != '/api/run/reset') {
      throw StateError('Unexpected fixture request: $path');
    }
    if (failReset) throw StateError('Reset failed.');
    resets++;
    hasRunData = false;
    return {'cleared': true};
  }
}

class _RecordingCanvas implements Canvas {
  final List<(ui.Paragraph, Offset)> paragraphs = [];
  final List<(Offset, Offset, Color, double)> segments = [];
  final List<Rect> rectangles = [];
  final List<(Offset, double)> circles = [];
  final List<Rect> clips = [];

  @override
  void drawRect(Rect rect, Paint paint) => rectangles.add(rect);
  @override
  void drawCircle(Offset center, double radius, Paint paint) =>
      circles.add((center, radius));
  @override
  void clipRect(
    Rect rect, {
    ui.ClipOp clipOp = ui.ClipOp.intersect,
    bool doAntiAlias = true,
  }) => clips.add(rect);

  @override
  void drawLine(Offset p1, Offset p2, Paint paint) {
    segments.add((p1, p2, paint.color, paint.strokeWidth));
  }

  @override
  void drawParagraph(ui.Paragraph paragraph, Offset offset) {
    paragraphs.add((paragraph, offset));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _SelectingBackendApiFixture extends _BackendApiFixture {
  final selectionStarted = Completer<void>();
  final finishSelection = Completer<void>();

  @override
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, Object?> body,
  ) async {
    if (path == '/api/runs/select') {
      selectionStarted.complete();
      await finishSelection.future;
    }
    return super.post(path, body);
  }
}

Future<DashboardController> _showOfflineApp(
  WidgetTester tester,
  _BackendApiFixture api,
) async {
  final controller = DashboardController(api: api);
  addTearDown(controller.dispose);
  await controller.refresh();
  await tester.pumpWidget(
    MaterialApp(
      home: AnimatedBuilder(
        animation: controller,
        builder: (_, _) => SimulatorHome(controller: controller),
      ),
    ),
  );
  return controller;
}

void main() {
  testWidgets(
    'file importer shows progress and adds the saved algorithm to setup',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(() => StrategyRegistry.replaceImported([]));
      final api = _BackendApiFixture()..available = true;
      api.statusFields.addAll({
        'algorithmImportsSupported': true,
        'algorithms': [],
      });
      final controller = DashboardController(
        api: api,
        algorithmPicker: () async => AlgorithmSourceFile(
          name: 'custom.json',
          source: jsonEncode({
            'id': 'widget_algorithm',
            'name': 'My imported strategy',
            'description': 'Imported test strategy.',
            'warmupBars': 5,
            'parameters': {
              'threshold': {'default': 1, 'min': 0, 'max': 5, 'unit': '%'},
            },
          }),
        ),
      );
      addTearDown(controller.dispose);
      await controller.refresh();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AnimatedBuilder(
              animation: controller,
              builder: (_, _) => RunSetupView(controller: controller),
            ),
          ),
        ),
      );
      await tester.ensureVisible(find.text('Add algorithm from file'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add algorithm from file'));
      await tester.pump();
      expect(find.text('Validating custom.json…'), findsOneWidget);
      expect(controller.importingAlgorithm, isTrue);
      api.algorithmImport.complete();
      await tester.pumpAndSettle();
      expect(controller.importingAlgorithm, isFalse);
      expect(
        StrategyRegistry.byId('widget_algorithm').parameters.single.name,
        'threshold',
      );
      expect(find.text('My imported strategy'), findsOneWidget);
      expect(find.textContaining('added it to this setup'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'invalid import displays its error and keeps the catalogue unchanged',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(() => StrategyRegistry.replaceImported([]));
      final api = _BackendApiFixture()
        ..available = true
        ..failAlgorithmImport = true;
      api.statusFields.addAll({
        'algorithmImportsSupported': true,
        'algorithms': [],
      });
      api.algorithmImport.complete();
      final controller = DashboardController(
        api: api,
        algorithmPicker: () async =>
            const AlgorithmSourceFile(name: 'broken.json', source: '{}'),
      );
      addTearDown(controller.dispose);
      await controller.refresh();
      final before = StrategyRegistry.all.length;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AnimatedBuilder(
              animation: controller,
              builder: (_, _) => RunSetupView(controller: controller),
            ),
          ),
        ),
      );
      await tester.ensureVisible(find.text('Add algorithm from file'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add algorithm from file'));
      await tester.pumpAndSettle();
      expect(find.text('Algorithm could not be imported'), findsOneWidget);
      expect(find.textContaining('Unknown variable "typo"'), findsOneWidget);
      expect(StrategyRegistry.all.length, before);
      expect(controller.importingAlgorithm, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('normal app entry renders the Live Simulation dashboard', (
    tester,
  ) async {
    await tester.pumpWidget(const MyApp(autoStartBackend: false));
    await tester.pump();

    expect(find.text('A-Trader'), findsOneWidget);
    expect(find.text('SIMULATION'), findsOneWidget);
    expect(find.text('Live dashboard'), findsOneWidget);
    expect(find.text('Starting cash'), findsOneWidget);
    expect(find.byTooltip('Export all run data'), findsOneWidget);
  });

  testWidgets('Windows autostart coalesces with the restart control', (
    tester,
  ) async {
    final api = _BackendApiFixture();
    await tester.pumpWidget(MyApp(backendApi: api));
    final controller = tester
        .widget<SimulatorHome>(find.byType(SimulatorHome))
        .controller;
    await tester.pump();
    expect(find.text('Connecting to local backend…'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (widget) =>
                  widget is IconButton && widget.tooltip == 'Restart backend',
            ),
          )
          .onPressed,
      isNull,
    );
    await controller.restartBackend();
    expect(api.launches, 1);

    api.launch.complete();
    await tester.pumpAndSettle();
    expect(controller.backendConnected, isTrue);
    expect(controller.backendError, isEmpty);
    expect(find.byTooltip('Restart backend'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('startup failure stays visible and allows another attempt', (
    tester,
  ) async {
    final api = _BackendApiFixture();
    final controller = await _showOfflineApp(tester, api);
    await tester.tap(find.byTooltip('Restart backend'));
    await tester.pump();
    api.launch.completeError(StateError('Bundled backend is missing.'));
    await tester.pumpAndSettle();

    expect(controller.backendConnected, isFalse);
    expect(controller.backendStarting, isFalse);
    expect(find.textContaining('Bundled backend is missing.'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (widget) =>
                  widget is IconButton && widget.tooltip == 'Restart backend',
            ),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('restart is available while connected and Settings reflects it', (
    tester,
  ) async {
    final api = _BackendApiFixture();
    api.available = true;
    final controller = await _showOfflineApp(tester, api);
    expect(controller.backendConnected, isTrue);
    await tester.tap(find.byTooltip('Restart backend'));
    await tester.pump();
    expect(api.launches, 1);
    api.launch.complete();
    await tester.pumpAndSettle();

    expect(controller.backendConnected, isTrue);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Connected to http://127.0.0.1:8787'), findsOneWidget);
    expect(
      find.textContaining('The app connects automatically.'),
      findsOneWidget,
    );
    expect(find.text('Client ID (App Key)'), findsOneWidget);
    expect(find.text('Client Secret (App Secret)'), findsOneWidget);
    expect(find.text(defaultSchwabRedirectUri), findsOneWidget);
  });

  testWidgets(
    'platforms that cannot spawn processes show manual instructions',
    (tester) async {
      await _showOfflineApp(tester, _BackendApiFixture(canLaunch: false));
      expect(find.byTooltip('Restart backend'), findsNothing);
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Restart backend'), findsNothing);
      expect(find.textContaining(r'dart run bin\server.dart'), findsOneWidget);
    },
  );

  test(
    'closing the app during startup does not notify a disposed controller',
    () async {
      final api = _BackendApiFixture();
      final controller = DashboardController(api: api);
      final startup = controller.restartBackend();
      controller.dispose();
      api.launch.complete();
      await startup;
      expect(api.launches, 1);
    },
  );

  testWidgets(
    'workspace shows performance beside its chart and keeps details collapsed',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 840);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = DashboardController()
        ..status = {
          'workspaceMode': true,
          'workspaceId': 'source',
          'runId': 'preview',
          'researchPreview': true,
          'research': {
            'running': true,
            'continuous': true,
            'phase': 'tuning',
            'cycles': 4,
            'progress': .42,
          },
        }
        ..snapshot = {
          'accounts': [
            {
              'label': 'Alpha',
              'startingCash': 10000,
              'equity': 10250,
              'closedPnl': [45, -5],
            },
            {
              'label': 'Beta',
              'startingCash': 10000,
              'equity': 11000,
              'closedPnl': <int>[],
            },
          ],
          'generationEquity': [
            {
              'label': 'Alpha',
              'startingCash': 10000,
              'history': [
                {'generation': 1, 'value': 10000},
                {'generation': 4, 'value': 10250},
              ],
            },
          ],
        };
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SelectionArea(child: DashboardView(controller: controller)),
          ),
        ),
      );
      expect(
        find.text('Continuous research · Tuning strategies'),
        findsOneWidget,
      );
      expect(find.text('50.0%'), findsOneWidget);
      expect(find.text('—'), findsOneWidget);
      expect(find.byType(CandleChart), findsNothing);
      expect(
        tester.getCenter(find.text('Portfolio equity')).dx,
        lessThan(tester.getCenter(find.text('Portfolio performance')).dx),
      );
      expect(
        tester.widget<EquityChart>(find.byType(EquityChart)).byGeneration,
        isTrue,
      );
      await tester.tap(find.text('Drawdown'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<EquityChart>(find.byType(EquityChart)).drawdown,
        isTrue,
      );
      await tester.tap(find.text('Win rate'));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('Alpha')).dy,
        lessThan(tester.getTopLeft(find.text('Beta')).dy),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('equity chart hover shows every portfolio value', (tester) async {
    Map<String, dynamic> account(String label, List<double> values) => {
      'label': label,
      'startingCash': 10000.0,
      'equity': values.last,
      'history': [
        for (var index = 0; index < values.length; index++)
          {
            'time': DateTime.utc(2025, 1, 2, 15, index).toIso8601String(),
            'value': values[index],
          },
      ],
    };
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 600,
            height: 300,
            child: EquityChart(
              accounts: [
                account('Alpha', [10000, 10100, 10250]),
                account('Beta', [10000, 9900, 9800]),
              ],
            ),
          ),
        ),
      ),
    );
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    await gesture.moveTo(tester.getCenter(find.byType(EquityChart)));
    await tester.pump();
    expect(tester.takeException(), isNull);
    final painter = tester
        .widgetList<CustomPaint>(
          find.descendant(
            of: find.byType(EquityChart),
            matching: find.byType(CustomPaint),
          ),
        )
        .map((paint) => paint.painter)
        .whereType<CustomPainter>()
        .first;
    expect((painter as dynamic).hover, isNotNull);
  });

  testWidgets('Mountain chart axis labels never overlap on narrow charts', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 220,
            width: 650,
            child: EquityChart(
              accounts: [
                {
                  'label': 'Portfolio',
                  'startingCash': 10000,
                  'history': [
                    {'time': '2026-11-16T15:00:00Z', 'value': 10000},
                    {'time': '2026-11-16T20:00:00Z', 'value': 10100},
                  ],
                },
              ],
            ),
          ),
        ),
      ),
    );
    final painter = tester
        .widgetList<CustomPaint>(
          find.descendant(
            of: find.byType(EquityChart),
            matching: find.byType(CustomPaint),
          ),
        )
        .map((paint) => paint.painter)
        .whereType<CustomPainter>()
        .first;

    List<(ui.Paragraph, Offset)> labelsAtWidth(double width) {
      final canvas = _RecordingCanvas();
      painter.paint(canvas, Size(width, 220));
      return canvas.paragraphs.where((item) => item.$2.dy == 204).toList();
    }

    expect(labelsAtWidth(250), hasLength(1));
    final wideLabels = labelsAtWidth(650);
    expect(wideLabels, hasLength(2));
    expect(
      wideLabels.last.$2.dx,
      greaterThan(wideLabels.first.$2.dx + wideLabels.first.$1.longestLine),
    );
  });

  testWidgets('clearing run data requires confirmation and refreshes results', (
    tester,
  ) async {
    final api = _BackendApiFixture()
      ..available = true
      ..hasRunData = true;
    final controller = DashboardController(api: api);
    addTearDown(controller.dispose);
    await controller.refresh();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AnimatedBuilder(
            animation: controller,
            builder: (_, _) => RunSetupView(controller: controller),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Clear run data'));
    await tester.pumpAndSettle();
    expect(find.text('Clear run data?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(api.resets, 0);
    expect(controller.snapshot['accounts'], isNotEmpty);

    await tester.tap(find.text('Clear run data'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear data'));
    await tester.pumpAndSettle();
    expect(api.resets, 1);
    expect(controller.snapshot['accounts'], isEmpty);
    expect(controller.events, isEmpty);
    expect(find.text('Run data cleared.'), findsOneWidget);

    api.running = true;
    await controller.refresh();
    await tester.pump();
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Clear run data'),
          )
          .onPressed,
      isNull,
    );
    expect(find.text('Stop the run before clearing its data.'), findsOneWidget);
  });

  testWidgets('reset errors are visible', (tester) async {
    final api = _BackendApiFixture()
      ..available = true
      ..failReset = true;
    final controller = DashboardController(api: api);
    addTearDown(controller.dispose);
    await controller.refresh();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: RunSetupView(controller: controller)),
      ),
    );
    await tester.tap(find.text('Clear run data'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear data'));
    await tester.pumpAndSettle();
    expect(find.text('Reset failed.'), findsWidgets);
    expect(api.resets, 0);
  });

  testWidgets('strategy descriptions work in setup and preserve expansion', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = DashboardController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: RunSetupView(controller: controller)),
      ),
    );
    final strategy = StrategyRegistry.byId('fibonacci');
    final title = find.text(strategy.name);
    await tester.ensureVisible(title);
    await tester.pumpAndSettle();
    expect(find.textContaining(strategy.description), findsOneWidget);

    await tester.tap(title);
    await tester.pumpAndSettle();
    expect(find.text('Chart label'), findsOneWidget);
    final infoButton = find.byTooltip('About ${strategy.name}');
    await tester.tap(infoButton);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining(strategy.description), findsWidgets);
    expect(
      find.text('Minimum warm-up: ${strategy.warmupBars} bars.'),
      findsOneWidget,
    );
  });

  testWidgets('dashboard legend and metrics describe custom strategy labels', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final strategy = StrategyRegistry.byId('ma_crossover');
    const label = 'Fast MA portfolio';
    final controller = DashboardController()
      ..status = {
        'running': false,
        'startingCash': 10000.0,
        'watchlist': ['SOXL'],
        'strategies': [
          {
            'strategyId': strategy.id,
            'label': label,
            'enabled': true,
            'intervalMinutes': 1,
            'warmupRequired': strategy.warmupBars,
            'warmupBySymbol': {'SOXL': 5},
          },
        ],
      }
      ..snapshot = {
        'accounts': [
          {
            'label': label,
            'startingCash': 10000.0,
            'equity': 10100.0,
            'history': [
              {
                'time': DateTime.utc(2026, 11, 16, 15).toIso8601String(),
                'value': 10100.0,
              },
            ],
            'events': <dynamic>[],
            'positions': <dynamic>[],
          },
        ],
      };
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DashboardView(controller: controller)),
      ),
    );

    final legendDescription =
        '${strategy.name}\n${strategy.description}\n'
        'Click to toggle this line in both charts.';
    final descriptionTooltip = find.byTooltip(legendDescription);
    expect(descriptionTooltip, findsOneWidget);
    final legend = find.descendant(
      of: descriptionTooltip.first,
      matching: find.text(label),
    );
    await tester.ensureVisible(legend);
    await tester.pumpAndSettle();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(legend));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text(legendDescription, findRichText: true), findsOneWidget);
    expect(find.byTooltip('About $label'), findsNothing);
    final chip = tester.widget<FilterChip>(find.byType(FilterChip));
    expect(chip.avatar, isNull);
    expect(chip.selectedColor, const Color(0xff3d80c6));
    expect(chip.side?.color, chip.selectedColor);
    expect(chip.padding, EdgeInsets.zero);
    expect(chip.materialTapTargetSize, MaterialTapTargetSize.shrinkWrap);
    expect(
      tester.getSize(find.byType(FilterChip)).height,
      lessThanOrEqualTo(32),
    );
    expect(
      tester.getBottomLeft(find.byType(FilterChip)).dy,
      lessThan(tester.getTopLeft(find.byType(EquityChart).first).dy),
    );
    await mouse.moveTo(Offset.zero);
    await tester.pumpAndSettle();

    final metricsLabel = find.descendant(
      of: find.byTooltip('${strategy.name}\n${strategy.description}').first,
      matching: find.text(label),
    );
    await tester.ensureVisible(metricsLabel);
    await tester.pumpAndSettle();
    await tester.tap(metricsLabel);
    await tester.pumpAndSettle();
    expect(find.text('Portfolio: $label'), findsOneWidget);
    expect(find.text(strategy.description), findsOneWidget);
    expect(
      find.text('Minimum warm-up: ${strategy.warmupBars} bars.'),
      findsOneWidget,
    );
  });

  testWidgets('readiness and signed metrics use green, red and yellow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = DashboardController()
      ..status = {
        'strategies': [
          {
            'strategyId': 'ma_crossover',
            'label': 'Warmed',
            'enabled': true,
            'intervalMinutes': 1,
            'warmupRequired': 22,
            'warmupBySymbol': {'SOXL': 22},
            'readyBySymbol': {'SOXL': true},
          },
          {
            'strategyId': 'neural_network',
            'label': 'Untrained',
            'enabled': true,
            'intervalMinutes': 1,
            'warmupRequired': 22,
            'warmupBySymbol': {'SOXL': 22},
            'readyBySymbol': {'SOXL': false},
            'readinessReason': 'No trained model was pinned to this run.',
          },
          {
            'strategyId': 'ma_crossover',
            'label': 'Warming',
            'enabled': true,
            'intervalMinutes': 1,
            'warmupRequired': 22,
            'warmupBySymbol': {'SOXL': 5},
          },
        ],
      }
      ..snapshot = {
        'accounts': [
          for (final (label, equity) in [
            ('Positive', 10100.0),
            ('Negative', 9900.0),
            ('Neutral', 10000.0),
          ])
            {
              'label': label,
              'startingCash': 10000.0,
              'equity': equity,
              'closedPnl': label == 'Positive' ? [20, -5] : <num>[],
              'history': [
                {'time': '2025-01-06T15:00:00Z', 'value': 10000.0},
                if (label == 'Positive')
                  {'time': '2025-01-06T15:01:00Z', 'value': 11000.0},
                {'time': '2025-01-06T15:02:00Z', 'value': equity},
              ],
              'events': <dynamic>[],
              'positions': <dynamic>[],
            },
        ],
      };
    addTearDown(controller.dispose);
    for (final dark in [false, true]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: dark ? ThemeData.dark() : ThemeData.light(),
          home: Scaffold(body: DashboardView(controller: controller)),
        ),
      );
      await tester.pumpAndSettle();
      final green = dark ? const Color(0xff4ade80) : const Color(0xff15803d);
      final red = dark ? const Color(0xfff87171) : const Color(0xffc2413b);
      final yellow = dark ? const Color(0xfffacc15) : const Color(0xffa66c00);
      final rows = tester
          .widgetList<DataTable>(find.byType(DataTable))
          .expand((table) => table.rows)
          .toList();
      Color? cellColor(int row, int cell) =>
          (rows[row].cells[cell].child as Text).style?.color;
      expect(cellColor(0, 1), green);
      expect(cellColor(0, 2), green);
      expect((rows[0].cells[3].child as Text).data, '-8.18%');
      expect(cellColor(0, 3), red);
      expect(cellColor(0, 4), yellow);
      expect(cellColor(0, 6), green);
      expect(cellColor(0, 7), red);
      expect(cellColor(2, 1), red);
      expect(cellColor(1, 1), yellow);
      expect((rows[1].cells[3].child as Text).data, '0.00%');
      expect(cellColor(1, 3), yellow);
      expect(find.text('— (0 closed)'), findsNWidgets(2));
      expect(find.text('50.0% (1/2)'), findsOneWidget);
      expect((rows[0].cells[4].child as Text).data, '2');
      await tester.scrollUntilVisible(
        find.text('Ready'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(find.text('Ready')).style?.color, green);
      expect(
        tester
            .widgetList<Text>(find.text('Not ready'))
            .map((text) => text.style?.color),
        everyElement(red),
      );
      expect(
        find.byTooltip('No trained model was pinned to this run.'),
        findsOneWidget,
      );
      expect(
        tester.widget<Text>(find.text('SOXL: 5 of 22 bars')).style?.color,
        red,
      );
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('decision log strategy names open the matching description', (
    tester,
  ) async {
    final strategy = StrategyRegistry.byId('vwap_reclaim');
    const label = 'My VWAP';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DecisionLogView(
            status: {
              'strategies': [
                {'label': label, 'strategyId': strategy.id},
              ],
            },
            events: [
              {
                'strategy': label,
                'symbol': 'SOXL',
                'action': 'wait',
                'kind': 'signal',
                'reason': 'Fixture',
                'time': DateTime.utc(2026, 11, 16).toIso8601String(),
              },
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
    expect(find.text('Portfolio: $label'), findsOneWidget);
    expect(find.text(strategy.description), findsOneWidget);
  });

  testWidgets(
    'compact decision rows are time first and never infer shorts from sells',
    (tester) async {
      tester.view.physicalSize = const Size(380, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DecisionLogView(
              status: const {},
              events: [
                {
                  'time': '2026-11-16T15:00:00Z',
                  'strategy': 'Alpha',
                  'symbol': 'SOXL',
                  'action': 'sell',
                  'reason': 'Close legacy position',
                },
                {
                  'time': '2026-11-16T15:01:00Z',
                  'strategy': 'Beta',
                  'symbol': 'SMR',
                  'action': 'sell',
                  'positionSide': 'short',
                  'positionEffect': 'open',
                  'entryPrice': 21.25,
                  'stop': 23.50,
                  'target': 18.00,
                  'reason': 'Short entry',
                },
              ],
            ),
          ),
        ),
      );
      expect(find.text('SHORT'), findsOneWidget);
      expect(find.text('LONG'), findsNothing);
      expect(find.text('Entry price'), findsOneWidget);
      expect(find.text('Stop'), findsOneWidget);
      expect(find.text('\$21.25'), findsOneWidget);
      expect(find.text('\$23.50'), findsOneWidget);
      expect(find.text('2026-11-16 8:00:00 AM MST'), findsOneWidget);
      expect(find.text('2026-11-16 8:01:00 AM MST'), findsOneWidget);
      expect(find.text('Price'), findsNothing);
      expect(find.text('—'), findsNothing);
      expect(
        tester.getTopLeft(find.text('Time').first).dx,
        lessThan(tester.getTopLeft(find.text('Action').first).dx),
      );
    },
  );

  testWidgets('historical time picker forces a Mountain 12-hour clock', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1100, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = DashboardController()
      ..backendConnected = true
      ..status = {
        'running': false,
        'runMode': 'historical',
        'schwabAuthorized': true,
        'historicalTimeZones': [MountainTime.zoneId],
      };
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(alwaysUse24HourFormat: true),
          child: Scaffold(body: RunSetupView(controller: controller)),
        ),
      ),
    );
    expect(find.textContaining('Times are Mountain Time'), findsOneWidget);
    expect(find.text('End 2:00 PM MT'), findsOneWidget);
    await tester.tap(find.text('Start 7:30 AM MT'));
    await tester.pumpAndSettle();
    expect(find.text('Replay start time (Mountain)'), findsOneWidget);
    expect(find.text('AM'), findsOneWidget);
    expect(find.text('PM'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('Start 7:30 AM MT'), findsOneWidget);
  });

  test(
    'historical replay sends Mountain dates and times to a capable backend',
    () async {
      final api = _BackendApiFixture()..available = true;
      api.statusFields['historicalTimeZones'] = [MountainTime.zoneId];
      final controller = DashboardController(api: api);
      addTearDown(controller.dispose);
      await controller.refresh();
      await controller.startHistoricalRun(
        {'startingCash': 10000},
        DateTimeRange(
          start: DateTime(2026, 11, 10),
          end: DateTime(2026, 11, 13),
        ),
        startTime: const TimeOfDay(hour: 8, minute: 30),
        endTime: const TimeOfDay(hour: 14, minute: 30),
      );
      expect(api.posts.map((post) => post.$1), [
        '/api/settings/run',
        '/api/run/historical/start',
      ]);
      expect(api.posts.last.$2, {
        'startDate': '2026-11-10',
        'endDate': '2026-11-13',
        'startTime': '08:30',
        'endTime': '14:30',
        'timeZone': MountainTime.zoneId,
      });
    },
  );

  test('old backends cannot misinterpret Mountain replay selections', () async {
    final api = _BackendApiFixture()..available = true;
    final controller = DashboardController(api: api);
    addTearDown(controller.dispose);
    await controller.refresh();
    await expectLater(
      controller.startHistoricalRun(
        {'startingCash': 10000},
        DateTimeRange(
          start: DateTime(2026, 11, 10),
          end: DateTime(2026, 11, 13),
        ),
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('backend must be updated'),
        ),
      ),
    );
    expect(api.posts, isEmpty);
  });

  test('old backends cannot silently skip historical LM selection', () async {
    final api = _BackendApiFixture()..available = true;
    api.statusFields['historicalTimeZones'] = [MountainTime.zoneId];
    final controller = DashboardController(api: api);
    addTearDown(controller.dispose);
    await controller.refresh();
    final configuration = {
      'startingCash': 10000,
      'strategies': [
        {'strategyId': 'lm_selector', 'enabled': true},
      ],
    };
    final range = DateTimeRange(
      start: DateTime(2026, 11, 10),
      end: DateTime(2026, 11, 13),
    );
    await expectLater(
      controller.startHistoricalRun(configuration, range),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('Update the backend before replaying with LM Studio'),
        ),
      ),
    );
    expect(api.posts, isEmpty);
    api.statusFields['historicalLmAwaited'] = true;
    await controller.refresh();
    await controller.startHistoricalRun(configuration, range);
    expect(api.posts.map((post) => post.$1), [
      '/api/settings/run',
      '/api/run/historical/start',
    ]);
  });

  testWidgets(
    'training timestamps, including nested metrics, use Mountain time',
    (tester) async {
      final controller = DashboardController()
        ..status = {
          'training': {
            'ready': true,
            'runStartedAt': '2026-11-16T15:00:00Z',
            'lastEvaluation': {
              'neural_network': {'holdoutStartAt': '2026-07-16T18:05:06Z'},
            },
          },
        };
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: DashboardView(controller: controller)),
        ),
      );
      await tester.scrollUntilVisible(
        find.textContaining('Run Started At:'),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.text('Run Started At: 2026-11-16 8:00:00 AM MST'),
        findsOneWidget,
      );
      expect(
        find.textContaining('holdoutStartAt: 2026-07-16 12:05:06 PM MDT'),
        findsOneWidget,
      );
    },
  );

  testWidgets('position tally uses sides and closed pnl, never fills', (
    tester,
  ) async {
    final controller = DashboardController()
      ..snapshot = {
        'accounts': [
          {
            'label': 'Alpha',
            'positions': [
              {'positionSide': 'short', 'quantity': 2},
              {'quantity': 3},
              {'positionSide': 'long', 'quantity': 1},
              {'quantity': 0},
            ],
            'closedPnl': [12, -3],
            'events': [
              {
                'kind': 'fill',
                'time': '2026-11-16T15:00:00Z',
                'symbol': 'SOXL',
                'action': 'buy',
              },
              {
                'kind': 'fill',
                'time': '2026-11-16T15:01:00Z',
                'symbol': 'SOXL',
                'action': 'sell',
              },
              {
                'kind': 'fill',
                'time': '2026-11-16T15:02:00Z',
                'symbol': 'SOXL',
                'action': 'buy',
              },
            ],
          },
          {
            'label': 'Beta',
            'closedPnl': [2],
            'positions': [
              {'positionSide': 'short', 'quantity': 5},
            ],
          },
          {
            'label': 'Buy & Hold',
            'positions': [
              {'quantity': 9},
            ],
            'closedPnl': [1, 2, 3],
          },
        ],
      };
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DashboardView(controller: controller)),
      ),
    );
    expect(find.text('Open longs: 2'), findsOneWidget);
    expect(find.text('Open shorts: 2'), findsOneWidget);
    expect(find.text('Closed positions: 3'), findsOneWidget);
  });

  testWidgets('legend toggles both charts and survives backend polling', (
    tester,
  ) async {
    final api = _BackendApiFixture()..available = true;
    api.snapshotFields = {
      'accounts': [
        {
          'label': 'Alpha',
          'startingCash': 10000,
          'equity': 10100,
          'history': [
            {'time': '2026-11-16T15:00:00Z', 'value': 10100},
          ],
        },
      ],
    };
    final controller = DashboardController(api: api);
    addTearDown(controller.dispose);
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
    await tester.scrollUntilVisible(
      find.byType(FilterChip),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FilterChip));
    await tester.pumpAndSettle();
    expect(controller.hiddenSeries, contains('Alpha'));
    expect(
      find.text(
        'All portfolio lines are hidden. Select a legend item to show a line.',
      ),
      findsNWidgets(2),
    );
    await controller.refresh();
    await tester.pump();
    expect(
      tester.widget<FilterChip>(find.byType(FilterChip)).selected,
      isFalse,
    );
    expect(
      tester
          .widgetList<EquityChart>(find.byType(EquityChart))
          .every((chart) => chart.hiddenLabels.contains('Alpha')),
      isTrue,
    );
    await tester.tap(find.byType(FilterChip));
    await tester.pumpAndSettle();
    expect(controller.hiddenSeries, isEmpty);
    expect(
      find.text(
        'All portfolio lines are hidden. Select a legend item to show a line.',
      ),
      findsNothing,
    );
  });

  testWidgets('run picker and new simulation never reset an active run', (
    tester,
  ) async {
    final api = _BackendApiFixture()..available = true;
    api.statusFields.addAll({
      'runId': 'one',
      'runs': [
        {'id': 'one', 'name': 'First', 'running': true},
        {'id': 'two', 'name': 'Second', 'running': false},
      ],
      'startingCash': 25000,
      'watchlist': ['SMR'],
    });
    final controller = DashboardController(api: api);
    addTearDown(controller.dispose);
    await controller.refresh();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AnimatedBuilder(
            animation: controller,
            builder: (_, _) => RunSetupView(controller: controller),
          ),
        ),
      ),
    );
    await tester.tap(find.text('First · Running'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Second · Stopped').last);
    await tester.pumpAndSettle();
    expect(controller.status['runId'], 'two');
    expect(api.posts.single.$1, '/api/runs/select');
    await tester.tap(find.text('New simulation'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Simulation name'),
      'Comparison',
    );
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(api.posts.last.$1, '/api/runs/create');
    expect(api.posts.last.$2['name'], 'Comparison');
    final configuration = api.posts.last.$2['configuration'] as Map;
    expect(configuration['startingCash'], 25000);
    expect(controller.status['runId'], 'new');
    expect(api.resets, 0);
    expect(api.posts.where((post) => post.$1 == '/api/run/start'), isEmpty);
    expect((api.statusFields['runs'] as List).first['running'], isTrue);
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Simulation name'),
      'Renamed comparison',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
    await tester.pumpAndSettle();
    expect(api.posts.last.$2, {'runId': 'new', 'name': 'Renamed comparison'});
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete Renamed comparison?'), findsOneWidget);
    await tester.tap(find.text('Delete simulation'));
    await tester.pumpAndSettle();
    expect(api.posts.last.$1, '/api/runs/delete');
    expect((api.statusFields['runs'] as List).first['running'], isTrue);
  });

  testWidgets(
    'research preview charts and metrics follow each completed cycle',
    (tester) async {
      tester.view.physicalSize = const Size(2000, 2200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final api = _BackendApiFixture()..available = true;
      const source = 'source';
      const preview = 'latest-research';
      const previewName = 'Latest research simulation';
      const runs = [
        {'id': source, 'name': 'Source', 'running': false},
        {'id': preview, 'name': previewName, 'running': false},
      ];
      final research = {'running': true, 'previewRunId': preview};
      api.statusFields.addAll({
        'runId': source,
        'runs': runs,
        'research': research,
        'watchlist': ['SOXL'],
      });

      Map<String, dynamic> cycleSnapshot(int cycle, double equity) => {
        'status': {
          ...api.statusFields,
          'runId': preview,
          'runName': previewName,
          'researchPreview': true,
          'research': {
            ...research,
            'cycles': cycle,
            'phase': 'tuning',
            'progress': .25,
          },
        },
        'previewEvents': [
          {'strategy': 'Alpha', 'kind': 'signal', 'reason': 'Cycle $cycle'},
        ],
        'generationEquity': [
          {
            'label': 'Alpha',
            'startingCash': 10000.0,
            'history': [
              {'generation': 1, 'value': 10100.0, 'trialValue': 9900.0},
              if (cycle > 1)
                {'generation': 2, 'value': equity, 'trialValue': 10200.0},
            ],
          },
        ],
        'candles': {
          'SOXL:1': [
            {
              'time': '2026-11-16T15:01:00Z',
              'open': 100.0,
              'close': 100.0 + cycle,
              'high': 103.0,
              'low': 99.0,
              'volume': 1000.0,
            },
          ],
        },
        'accounts': [
          {
            'label': 'Alpha',
            'startingCash': 10000.0,
            'equity': equity,
            'closedPnl': cycle == 1 ? [10, -5] : [10, 5],
            'history': [
              {'time': '2026-11-16T15:00:00Z', 'value': 10000.0},
              {'time': '2026-11-16T15:01:00Z', 'value': equity},
            ],
          },
        ],
      };

      api.snapshotsByRun[preview] = cycleSnapshot(1, 10100);
      final controller = DashboardController(api: api);
      await controller.refresh();
      controller.start();
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

      api.statusFields['runId'] = preview;
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(api.posts, isEmpty);
      expect(find.text('Simulation: $previewName'), findsOneWidget);
      expect(controller.events.single['reason'], 'Cycle 1');
      expect((controller.status['research'] as Map)['cycles'], 1);
      expect(api.gets, isNot(contains('/api/log?runId=$preview')));
      expect(find.text('1.00%'), findsWidgets);

      final winRate = find.text('Win rate');
      await tester.ensureVisible(winRate);
      await tester.pumpAndSettle();
      await tester.tap(winRate);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<DataTable>(
              find.ancestor(of: winRate, matching: find.byType(DataTable)),
            )
            .sortColumnIndex,
        5,
      );
      await tester.tap(find.text('50.0% (1/2)'));
      await tester.pumpAndSettle();
      expect(find.text('Performance: Alpha'), findsNothing);
      expect(
        find.text('Showing generation 1 · Tuning generation 2 (25%)'),
        findsOneWidget,
      );
      expect(api.posts, isEmpty);

      api.snapshotsByRun[preview] = cycleSnapshot(2, 9800);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.text('100.0% (2/2)'), findsOneWidget);
      expect(
        find.text('Showing generation 2 · Tuning generation 3 (25%)'),
        findsOneWidget,
      );
      final charts = tester.widgetList<EquityChart>(find.byType(EquityChart));
      expect(charts.length, greaterThanOrEqualTo(2));
      for (final chart in charts.where((chart) => !chart.byGeneration)) {
        expect(chart.accounts.single['equity'], 9800);
      }
      expect(
        find.text('Equity by portfolio across generations'),
        findsOneWidget,
      );
      final generations = charts.singleWhere((chart) => chart.byGeneration);
      expect(generations.showTrialEquity, isFalse);
      expect(generations.accounts.single['history'], [
        {'generation': 1, 'value': 10100.0, 'trialValue': 9900.0},
        {'generation': 2, 'value': 9800.0, 'trialValue': 10200.0},
      ]);
      await tester.tap(find.text('Accepted'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<EquityChart>(find.byType(EquityChart))
            .singleWhere((chart) => chart.byGeneration)
            .showTrialEquity,
        isFalse,
      );
      expect(
        tester
            .widget<CandleChart>(find.byType(CandleChart))
            .rows
            .single['close'],
        102,
      );
      expect(find.text('-2.00%'), findsWidgets);
      expect((controller.status['research'] as Map)['cycles'], 2);
      expect(controller.events.single['reason'], 'Cycle 2');
      expect(controller.status['runId'], preview);
      await tester.scrollUntilVisible(
        find.text('Simulation controls'),
        -300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Simulation controls'));
      await tester.pumpAndSettle();
      expect(find.text('Simulation run'), findsOneWidget);
      expect(find.byType(RunSetupView), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets('dashboard shows active research progress and the next cycle', (
    tester,
  ) async {
    final api = _BackendApiFixture()..available = true;
    api.statusFields['research'] = {
      'running': true,
      'phase': 'downloading',
      'progress': .5,
      'detail': 'SOXL · 2 of 2 symbols',
    };
    final controller = DashboardController(api: api);
    addTearDown(controller.dispose);
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
    expect(find.text('Simulation activity'), findsOneWidget);
    expect(find.textContaining('Downloading market history'), findsOneWidget);
    expect(find.textContaining('SOXL · 2 of 2 symbols'), findsOneWidget);
    final indicator = find.byWidgetPredicate(
      (widget) =>
          widget is LinearProgressIndicator &&
          widget.semanticsLabel == 'Automatic research progress',
    );
    expect(tester.widget<LinearProgressIndicator>(indicator).value, .5);
    api.statusFields['research'] = {
      'running': true,
      'phase': 'tuning',
      'progress': .25,
      'remainingSeconds': 30,
    };
    await controller.refresh();
    await tester.pump();
    expect(tester.widget<LinearProgressIndicator>(indicator).value, .25);
    expect(find.textContaining('About 30s remaining'), findsOneWidget);
    api.statusFields['research'] = {
      'running': true,
      'phase': 'waiting',
      'nextCycleAt': '2026-11-17T14:30:00Z',
    };
    await controller.refresh();
    await tester.pump();
    expect(find.textContaining('Waiting for next cycle'), findsOneWidget);
    expect(
      find.textContaining('Next cycle 2026-11-17 7:30 AM MST'),
      findsOneWidget,
    );
    expect(indicator, findsNothing);
  });

  testWidgets(
    'saved best settings create a simulation with the recorded parameters',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = _BackendApiFixture()..available = true;
      api.statusFields.addAll({
        'runId': 'source',
        'runs': [
          {'id': 'source', 'name': 'Source', 'running': false},
        ],
        'configuration': {
          'watchlist': ['SOXL'],
          'startingCash': 10000,
          'strategies': [
            {
              'strategyId': 'ma_crossover',
              'label': 'MA',
              'parameters': {'fastPeriod': 5.0, 'slowPeriod': 20.0},
            },
          ],
        },
        'strategyBests': {
          'MA': {
            'profit': {
              'generation': 3,
              'parameters': {'fastPeriod': 2.0, 'slowPeriod': 4.0},
              'performance': {
                'netProfit': 200,
                'winRatePercent': 50,
                'closedTrades': 4,
              },
              'startUtc': '2026-05-04T13:30:00Z',
              'endUtc': '2026-05-04T20:00:00Z',
            },
          },
        },
      });
      final controller = DashboardController(api: api);
      addTearDown(controller.dispose);
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
      await tester.tap(find.text('Best saved strategy settings'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Generation 3'), findsOneWidget);
      await tester.tap(find.text('New simulation from these settings'));
      await tester.pumpAndSettle();
      final request = api.posts.single;
      expect(request.$1, '/api/runs/create');
      expect(
        request.$2['configuration'] as Map,
        containsPair('startingCash', 10000),
      );
      expect(
        (request.$2['configuration'] as Map)['strategies'][0]['parameters'],
        {'fastPeriod': 2.0, 'slowPeriod': 4.0},
      );
      expect(request.$2['historicalRange'], {
        'startDate': '2026-05-04',
        'endDate': '2026-05-04',
        'startTime': '07:30',
        'endTime': '14:00',
        'timeZone': MountainTime.zoneId,
      });
    },
  );

  testWidgets(
    'strategy variable history shows mutations and follows completed generations',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = _BackendApiFixture()..available = true;
      api.statusFields['runId'] = 'source';
      Map<String, dynamic> changes(int generation, double fast) => {
        'generation': generation,
        'latestGeneration': generation,
        'strategies': [
          {
            'label': 'MA',
            'message': 'Current settings retained.',
            'currentParameters': {'fastPeriod': 5.0, 'slowPeriod': 20.0},
            'candidateParameters': {'fastPeriod': fast, 'slowPeriod': 18.0},
            'tunedParameters': {'fastPeriod': 5.0, 'slowPeriod': 20.0},
          },
        ],
      };
      api.snapshotFields = {'accounts': [], 'variableChanges': changes(2, 8)};
      api.variableChangesByGeneration[1] = changes(1, 6);
      final controller = DashboardController(api: api);
      addTearDown(controller.dispose);
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
      final title = find.text('Strategy variable changes');
      await tester.scrollUntilVisible(
        title,
        400,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(title);
      await tester.tap(title);
      await tester.pumpAndSettle();
      expect(find.text('Fast Period: 5.0 → 8.0'), findsOneWidget);
      expect(
        tester.widget<Text>(find.text('+3')).style!.color,
        const Color(0xff15803d),
      );
      expect(
        tester.widget<Text>(find.text('−2')).style!.color,
        const Color(0xffc2413b),
      );
      final previous = find.byTooltip('Previous generation');
      await tester.ensureVisible(previous);
      await tester.tap(previous);
      await tester.pumpAndSettle();
      expect(find.text('Fast Period: 5.0 → 6.0'), findsOneWidget);
      api.snapshotFields = {'accounts': [], 'variableChanges': changes(3, 9)};
      await controller.refresh();
      await tester.pumpAndSettle();
      expect(find.text('Fast Period: 5.0 → 6.0'), findsOneWidget);
      await tester.tap(find.text('Follow latest'));
      await tester.pumpAndSettle();
      expect(find.text('Fast Period: 5.0 → 9.0'), findsOneWidget);
      await tester.tap(find.text('Accepted values'));
      await tester.pumpAndSettle();
      expect(find.text('Values unchanged'), findsOneWidget);
      await tester.tap(find.text('Show unchanged variables'));
      await tester.pumpAndSettle();
      expect(find.text('Fast Period: 5.0 → 5.0'), findsOneWidget);
    },
  );

  testWidgets('simulation setup starts research with the unsaved draft', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1100, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _BackendApiFixture()..available = true;
    api.statusFields.addAll({
      'runId': 'draft',
      'schwabAuthorized': true,
      'research': {'running': false},
      'configuration': {
        'watchlist': ['SOXL'],
        'strategies': [
          {
            'strategyId': 'ma_crossover_long_short',
            'label': 'MA',
            'enabled': true,
            'intervalMinutes': 5,
          },
        ],
      },
    });
    final controller = DashboardController(api: api);
    addTearDown(controller.dispose);
    await controller.refresh();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AnimatedBuilder(
            animation: controller,
            builder: (_, _) => RunSetupView(controller: controller),
          ),
        ),
      ),
    );
    final watchlist = find.widgetWithText(TextField, 'Watchlist');
    final setupScroll = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(watchlist, 250, scrollable: setupScroll);
    await tester.enterText(watchlist, 'QQQ');
    FocusManager.instance.primaryFocus?.unfocus();
    final generations = find.byKey(
      const ValueKey('setup-research-generations'),
    );
    await tester.ensureVisible(generations);
    await tester.pumpAndSettle();
    await tester.enterText(generations, '4');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Evolution settings'));
    await tester.tap(find.text('Evolution settings'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Mutation size (%)'),
      '50',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Extra-variable mutation (%)'),
      '40',
    );
    await tester.enterText(find.byKey(const ValueKey('population-size')), '6');
    FocusManager.instance.primaryFocus?.unfocus();
    final buyAndHold = find.widgetWithText(CheckboxListTile, 'Buy & Hold');
    final equalWeight = find.widgetWithText(CheckboxListTile, 'Equal Weight');
    await tester.ensureVisible(buyAndHold);
    await tester.pumpAndSettle();
    expect(tester.widget<CheckboxListTile>(buyAndHold).value, isTrue);
    expect(tester.widget<CheckboxListTile>(equalWeight).value, isTrue);
    await tester.tap(buyAndHold);
    await tester.pumpAndSettle();
    final start = find.text('Start');
    await tester.ensureVisible(start);
    await tester.pumpAndSettle();
    await tester.tap(start);
    await tester.pumpAndSettle();
    final request = api.posts.single;
    expect(request.$1, '/api/research/start');
    expect(request.$2['runId'], 'draft');
    expect(request.$2['evolutions'], 4);
    expect(request.$2['evolution'], {
      'mutationAmount': .5,
      'additionalMutationProbability': .4,
      'candidatesPerGeneration': 6,
      'eliteFraction': .15,
      'parentFraction': .5,
      'crossoverProbability': .8,
      'minimumMutationAmount': .005,
    });
    expect((request.$2['configuration'] as Map)['watchlist'], ['QQQ']);
    expect((request.$2['configuration'] as Map)['benchmarks'], {
      'buyAndHold': false,
      'equalWeight': true,
    });
    final range = request.$2['historicalRange'] as Map;
    expect(range['startDate'], range['endDate']);
    expect(range['startTime'], '07:30');
    expect(range['endTime'], '14:00');
  });

  test(
    'historical research sends the selected dates and Mountain times',
    () async {
      final api = _BackendApiFixture()..available = true;
      api.statusFields
        ..['runId'] = 'historical'
        ..['research'] = {'running': false};
      final controller = DashboardController(api: api);
      addTearDown(controller.dispose);
      await controller.refresh();
      await controller.setAutoResearch(
        true,
        historicalRange: DateTimeRange(
          start: DateTime(2026, 5, 4),
          end: DateTime(2026, 5, 5),
        ),
        startTime: const TimeOfDay(hour: 8, minute: 15),
        endTime: const TimeOfDay(hour: 13, minute: 45),
      );
      expect(api.posts.single.$2['historicalRange'], {
        'startDate': '2026-05-04',
        'endDate': '2026-05-05',
        'startTime': '08:15',
        'endTime': '13:45',
        'timeZone': MountainTime.zoneId,
      });
    },
  );

  testWidgets('training controls use explicit backend endpoints', (
    tester,
  ) async {
    final api = _BackendApiFixture()..available = true;
    api.statusFields['training'] = {
      'ready': true,
      'autoTraining': false,
      'training': false,
      'readiness': 'Collecting mature labels',
      'candidates': {'neural_network': null},
    };
    final controller = DashboardController(api: api);
    addTearDown(controller.dispose);
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
    await tester.scrollUntilVisible(
      find.text('Automatic training'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Automatic training'));
    await tester.pumpAndSettle();
    expect(api.posts.last.$1, '/api/training/settings');
    expect(api.posts.last.$2, {'autoTrain': true});
    await tester.ensureVisible(find.text('Train now'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Train now'));
    await tester.pumpAndSettle();
    expect(api.posts.last.$1, '/api/training/train');
  });

  testWidgets(
    'run setup preserves saved risk flags and defaults legacy flags to false',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = _BackendApiFixture()..available = true;
      final controller = DashboardController(api: api);
      addTearDown(controller.dispose);
      await controller.refresh();
      Future<void> render() => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RunSetupView(
              key: ValueKey(controller.status['runId']),
              controller: controller,
            ),
          ),
        ),
      );
      await render();
      expect(
        tester
            .widget<CheckboxListTile>(
              find.widgetWithText(CheckboxListTile, 'Enable short selling'),
            )
            .value,
        isFalse,
      );
      expect(
        tester
            .widget<CheckboxListTile>(
              find.widgetWithText(CheckboxListTile, 'Market close rule'),
            )
            .value,
        isFalse,
      );
      controller.status = {
        'runId': 'saved',
        'startingCash': 45000,
        'risk': {'enableShortSelling': true, 'sessionClosePolicyEnabled': true},
      };
      await render();
      expect(
        tester
            .widget<CheckboxListTile>(
              find.widgetWithText(CheckboxListTile, 'Enable short selling'),
            )
            .value,
        isTrue,
      );
      expect(
        tester
            .widget<CheckboxListTile>(
              find.widgetWithText(CheckboxListTile, 'Market close rule'),
            )
            .value,
        isTrue,
      );
      await tester.ensureVisible(find.text('Save configuration'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save configuration'));
      await tester.pumpAndSettle();
      final configuration = api.posts.last.$2;
      expect(configuration['startingCash'], 45000);
      expect((configuration['risk'] as Map)['enableShortSelling'], isTrue);
      expect(
        (configuration['risk'] as Map)['sessionClosePolicyEnabled'],
        isTrue,
      );
    },
  );

  test('polling cannot mix selected run data during a selection', () async {
    final api = _SelectingBackendApiFixture()..available = true;
    api.statusFields.addAll({
      'runId': 'one',
      'runs': [
        {'id': 'one', 'name': 'First'},
        {'id': 'two', 'name': 'Second'},
      ],
    });
    final controller = DashboardController(api: api);
    addTearDown(controller.dispose);
    await controller.refresh();
    final previousReads = api.gets.length;
    final selection = controller.selectRun('two');
    await api.selectionStarted.future;
    await controller.refresh();
    expect(api.gets.length, previousReads);
    expect(controller.status['runId'], 'one');
    api.finishSelection.complete();
    await selection;
    expect(controller.status['runId'], 'two');
    expect(api.gets.take(3), [
      '/api/status',
      '/api/snapshot?runId=one',
      '/api/log?runId=one',
    ]);
    expect(api.gets.skip(3), [
      '/api/status',
      '/api/snapshot?runId=two',
      '/api/log?runId=two',
    ]);
  });

  testWidgets(
    'starting saved data offers a new stopped run instead of overwrite',
    (tester) async {
      final api = _BackendApiFixture()..available = true;
      api.statusFields.addAll({
        'runId': 'one',
        'runs': [
          {'id': 'one', 'name': 'First', 'running': false},
        ],
        'feed': 'live',
      });
      api.snapshotFields = {
        'accounts': [
          {'label': 'Saved portfolio'},
        ],
      };
      final controller = DashboardController(api: api);
      addTearDown(controller.dispose);
      await controller.refresh();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: RunSetupView(controller: controller)),
        ),
      );
      await tester.tap(find.text('Live'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Start'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start'));
      await tester.pumpAndSettle();
      expect(find.text('Create a new simulation?'), findsOneWidget);
      expect(api.posts, isEmpty);
      await tester.tap(find.widgetWithText(FilledButton, 'New simulation'));
      await tester.pumpAndSettle();
      expect(api.posts.single.$1, '/api/runs/create');
      expect(api.resets, 0);
      expect(api.running, isFalse);
    },
  );

  testWidgets('hidden chart lines are excluded from hover data', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 300,
            child: EquityChart(
              hiddenLabels: const {'Hidden'},
              accounts: [
                for (final label in ['Hidden', 'Visible'])
                  {
                    'label': label,
                    'startingCash': 10000,
                    'history': [
                      {'time': '2026-11-16T15:00:00Z', 'value': 10000},
                      {'time': '2026-11-16T15:01:00Z', 'value': 10100},
                    ],
                  },
              ],
            ),
          ),
        ),
      ),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byType(EquityChart)));
    await tester.pump();
    final painter =
        tester
                .widgetList<CustomPaint>(
                  find.descendant(
                    of: find.byType(EquityChart),
                    matching: find.byType(CustomPaint),
                  ),
                )
                .map((widget) => widget.painter)
                .whereType<CustomPainter>()
                .first
            as dynamic;
    expect(painter.hover, isNotNull);
    expect((painter.series as List).map((dynamic series) => series.label), [
      'Visible',
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dashboard embeds decisions and trades without run creation', (
    tester,
  ) async {
    final controller = DashboardController()
      ..status = {
        'runId': 'one',
        'runs': [
          {'id': 'one', 'name': 'Morning simulation'},
        ],
        'training': {'ready': false},
      }
      ..snapshot = {
        'accounts': [
          {
            'label': 'Alpha strategy',
            'positions': [
              {
                'symbol': 'SOXL',
                'positionSide': 'long',
                'quantity': 7,
                'entryPrice': 20,
                'stop': 19,
                'target': 23,
                'entryTime': '2026-11-16T15:00:00Z',
              },
            ],
          },
          {
            'label': 'Beta strategy',
            'positions': [
              {
                'symbol': 'SMR',
                'positionSide': 'short',
                'quantity': 3,
                'entryPrice': 30,
                'stop': 31,
                'target': 27,
              },
            ],
          },
          {
            'label': 'Buy & Hold',
            'positions': [
              {'symbol': 'OKLO', 'quantity': 4},
            ],
          },
        ],
      };
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DashboardView(controller: controller)),
      ),
    );
    expect(find.text('Simulation: Morning simulation'), findsOneWidget);
    expect(find.text('New simulation'), findsNothing);
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);
    await tester.scrollUntilVisible(
      find.text('Open trades by strategy (2)'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('LONG'), findsOneWidget);
    expect(find.text('SHORT'), findsOneWidget);
    expect(find.text('2026-11-16 8:00:00 AM MST'), findsOneWidget);
    expect(find.text('\$20.00'), findsOneWidget);
    expect(find.text('\$31.00'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byType(DecisionLogView),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -1000));
    await tester.pumpAndSettle();
    expect(find.text('Model training'), findsNothing);
    expect(find.text('Decision log'), findsOneWidget);
    controller.status['training'] = {'ready': true};
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DashboardView(controller: controller)),
      ),
    );
    await tester.scrollUntilVisible(
      find.text('Model training'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Model training'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'decision filters select multiple values and combine categories',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final events = [
        for (final (strategy, ticker, side, action, kind, reason) in [
          ('Alpha', 'SOXL', 'long', 'buy', 'signal', 'Recovery A'),
          ('Beta', 'SMR', 'short', 'sell', 'fill', 'Breakdown B'),
          ('Gamma', 'OKLO', 'short', 'sell', 'order', 'Breakdown C'),
          ('Alpha', 'SMR', 'short', 'sell', 'signal', 'Recovery D'),
          ('Beta', 'SOXL', 'long', 'wait', 'signal', 'Warm-up E'),
        ])
          <String, dynamic>{
            'strategy': strategy,
            'symbol': ticker,
            'positionSide': side,
            'action': action,
            'kind': kind,
            'reason': reason,
            'time': '2026-11-16T15:00:00Z',
          },
        <String, dynamic>{
          'strategy': 'Legacy',
          'symbol': 'SMR',
          'action': 'sell',
          'kind': 'fill',
          'reason': 'Legacy exit',
        },
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DecisionLogView(events: events, status: const {}),
          ),
        ),
      );
      Future<void> select(String label, List<String> options) async {
        await tester.tap(find.widgetWithText(OutlinedButton, '$label: All'));
        await tester.pumpAndSettle();
        for (final option in options) {
          await tester.tap(find.widgetWithText(CheckboxMenuButton, option));
          await tester.pumpAndSettle();
        }
        await tester.tap(find.text('Decision log'));
        await tester.pumpAndSettle();
      }

      await select('Strategy', ['Alpha', 'Beta']);
      expect(find.text('4 matching events'), findsOneWidget);
      expect(find.text('Strategy: 2 selected'), findsOneWidget);
      await select('Ticker', ['SOXL', 'SMR']);
      expect(find.text('Ticker: 2 selected'), findsOneWidget);
      await select('Side', ['SHORT']);
      expect(find.text('2 matching events'), findsOneWidget);
      expect(find.text('Legacy exit'), findsNothing);
      await select('Action', ['SELL']);
      await select('Event', ['signal', 'fill']);
      expect(find.text('2 matching events'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, 'Search decisions'),
        'recovery',
      );
      await tester.pumpAndSettle();
      expect(find.text('1 matching events'), findsOneWidget);
      expect(find.text('Recovery D'), findsOneWidget);
      expect(find.text('Breakdown B'), findsNothing);
      await tester.tap(find.text('Clear filters'));
      await tester.pumpAndSettle();
      expect(find.text('6 matching events'), findsOneWidget);
      await tester.tap(find.widgetWithText(OutlinedButton, 'Ticker: All'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Find ticker'),
        'sm',
      );
      await tester.pumpAndSettle();
      expect(find.widgetWithText(CheckboxMenuButton, 'SMR'), findsOneWidget);
      expect(find.widgetWithText(CheckboxMenuButton, 'SOXL'), findsNothing);
      await tester.tap(find.widgetWithText(CheckboxMenuButton, 'SMR'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Decision log'));
      await tester.pumpAndSettle();
      expect(find.text('3 matching events'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('chart hover paints in root overlay over following content', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              SizedBox(
                height: 110,
                child: EquityChart(
                  accounts: [
                    for (var i = 0; i < 12; i++)
                      {
                        'label': 'Strategy $i',
                        'startingCash': 10000,
                        'history': [
                          {'time': '2026-11-16T15:00:00Z', 'value': 10000},
                          {'time': '2026-11-16T15:01:00Z', 'value': 10100},
                        ],
                      },
                  ],
                ),
              ),
              Expanded(child: Container(color: Colors.red)),
            ],
          ),
        ),
      ),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byType(EquityChart)));
    await tester.pump();
    final tooltip = find.byKey(const ValueKey('chart-hover-tooltip'));
    expect(tooltip, findsOneWidget);
    expect(
      tester.getBottomLeft(tooltip).dy,
      greaterThan(tester.getBottomLeft(find.byType(EquityChart)).dy),
    );
    expect(tester.getBottomLeft(tooltip).dy, lessThanOrEqualTo(600));
    expect(
      tester.widget<OverlayPortal>(find.byType(OverlayPortal)).overlayLocation,
      OverlayChildLocation.rootOverlay,
    );
    expect(find.textContaining('Strategy 11: \$'), findsOneWidget);
    await mouse.moveTo(const Offset(20, 500));
    await tester.pump();
    expect(tooltip, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'candles and fill markers stay inside the plot with price padding',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 180,
              child: CandleChart(
                rows: const [
                  {
                    'time': '2026-11-16T15:00:00Z',
                    'open': 20,
                    'high': 20,
                    'low': 20,
                    'close': 20,
                    'volume': 100,
                  },
                  {
                    'time': '2026-11-16T15:01:00Z',
                    'open': 21,
                    'high': 22,
                    'low': 19,
                    'close': 21,
                    'volume': 100,
                  },
                ],
                events: const [
                  {
                    'kind': 'fill',
                    'action': 'buy',
                    'time': '2026-11-16T15:00:30Z',
                    'price': 25,
                  },
                  {
                    'kind': 'fill',
                    'action': 'sell',
                    'time': '2026-11-15T15:00:00Z',
                    'price': 9999,
                  },
                  {
                    'kind': 'signal',
                    'action': 'wait',
                    'time': '2026-11-16T15:00:30Z',
                    'price': 21,
                  },
                ],
              ),
            ),
          ),
        ),
      );
      final dynamic painter = tester
          .widgetList<CustomPaint>(
            find.descendant(
              of: find.byType(CandleChart),
              matching: find.byType(CustomPaint),
            ),
          )
          .firstWhere((paint) => paint.painter != null)
          .painter;
      final canvas = _RecordingCanvas();
      const size = Size(600, 180);
      painter.paint(canvas, size);
      expect(canvas.clips, [Offset.zero & size]);
      expect(canvas.rectangles, hasLength(2));
      expect(canvas.circles, hasLength(1));
      for (final rect in canvas.rectangles) {
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(size.width));
        expect(rect.top, greaterThan(0));
        expect(rect.bottom, lessThan(size.height));
      }
      for (final (center, radius) in canvas.circles) {
        expect(center.dy - radius, greaterThanOrEqualTo(0));
        expect(center.dy + radius, lessThanOrEqualTo(size.height));
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('candle hover uses the foreground overlay with OHLC values', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 180,
            child: CandleChart(
              rows: const [
                {
                  'time': '2026-11-16T15:00:00Z',
                  'open': 20,
                  'high': 22,
                  'low': 19,
                  'close': 21,
                  'volume': 100,
                },
              ],
              events: const [],
            ),
          ),
        ),
      ),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byType(CandleChart)));
    await tester.pump();
    expect(find.byKey(const ValueKey('chart-hover-tooltip')), findsOneWidget);
    expect(find.text('Open 20.00   High 22.00'), findsOneWidget);
    expect(find.text('Low 19.00   Close 21.00'), findsOneWidget);
    expect(find.text('Volume 100'), findsOneWidget);
    await mouse.removePointer();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'starting cash is a dotted reference included in the chart range',
    (tester) async {
      for (final percent in [false, true]) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                height: 220,
                child: EquityChart(
                  percent: percent,
                  showStartingCash: true,
                  accounts: [
                    {
                      'label': 'Alpha',
                      'startingCash': 10000,
                      'history': [
                        {'time': '2026-11-16T15:00:00Z', 'value': 12000},
                        {'time': '2026-11-16T15:01:00Z', 'value': 13000},
                      ],
                    },
                  ],
                ),
              ),
            ),
          ),
        );
        final painter =
            tester
                    .widgetList<CustomPaint>(
                      find.descendant(
                        of: find.byType(EquityChart),
                        matching: find.byType(CustomPaint),
                      ),
                    )
                    .map((widget) => widget.painter)
                    .whereType<CustomPainter>()
                    .first
                as dynamic;
        expect(painter.startingCashLevels, [percent ? 0.0 : 10000.0]);
        final canvas = _RecordingCanvas();
        painter.paint(canvas, const Size(650, 220));
        final dashes = canvas.segments
            .where((segment) => (segment.$4 - 1.2).abs() < .0001)
            .toList();
        expect(dashes.length, greaterThan(50));
        for (final (start, end, _, _) in dashes) {
          expect(start.dy, 198);
          expect(end.dy, 198);
          expect(end.dx - start.dx, lessThanOrEqualTo(3));
        }
        expect(dashes[1].$1.dx - dashes[0].$1.dx, 8);
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'single dashboard shows every ticker and keeps controls accessible',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = _BackendApiFixture()..available = true;
      final controller = DashboardController(api: api)
        ..status = {
          'runId': 'one',
          'runs': [
            {'id': 'one', 'name': 'First', 'running': false},
          ],
          'watchlist': ['SOXL', 'SMR', 'OKLO'],
        }
        ..snapshot = {
          'candles': {
            for (final symbol in ['SOXL', 'SMR', 'OKLO'])
              '$symbol:1': [
                {
                  'time': '2026-11-16T15:00:00Z',
                  'open': 20,
                  'high': 22,
                  'low': 19,
                  'close': 21,
                  'volume': 100,
                },
              ],
            'SOXL:5': [
              {
                'time': '2026-11-16T15:05:00Z',
                'open': 50,
                'high': 56,
                'low': 49,
                'close': 55,
                'volume': 1000,
              },
            ],
          },
        };
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(home: SimulatorHome(controller: controller)),
      );
      expect(find.byType(NavigationRail), findsNothing);
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.textContaining('Simulation: '), findsOneWidget);
      expect(find.text('New simulation'), findsNothing);
      await tester.scrollUntilVisible(
        find.text('Candle charts'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('SOXL candles'), findsOneWidget);
      expect(find.text('SMR candles'), findsOneWidget);
      expect(find.text('OKLO candles'), findsOneWidget);
      expect(find.byType(CandleChart), findsNWidgets(3));
      await tester.tap(find.byKey(const ValueKey('candle-interval-SOXL')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('5m').last);
      await tester.pumpAndSettle();
      final charts = tester
          .widgetList<CandleChart>(find.byType(CandleChart))
          .toList();
      expect((charts.first.rows.single as Map)['close'], 55);
      expect((charts[1].rows.single as Map)['close'], 21);
      expect((charts[2].rows.single as Map)['close'], 21);
      await tester.scrollUntilVisible(
        find.text('Simulation controls'),
        -300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Simulation controls'));
      await tester.pumpAndSettle();
      expect(find.text('Run setup'), findsOneWidget);
      expect(find.text('New simulation'), findsOneWidget);
      expect(find.text('Simulation run'), findsOneWidget);
      final watchlist = find.widgetWithText(TextField, 'Watchlist');
      await tester.ensureVisible(watchlist);
      await tester.enterText(watchlist, 'QQQ, SPY');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      final dashboard = find.byType(Scrollable).first;
      final position = tester.state<ScrollableState>(dashboard).position;
      await tester.scrollUntilVisible(
        find.text('Decision log'),
        600,
        scrollable: dashboard,
      );
      await tester.pumpAndSettle();
      expect(find.text('Simulation controls').hitTestable(), findsNothing);
      position.jumpTo(0);
      await tester.pumpAndSettle();
      expect(find.text('Run setup').hitTestable(), findsOneWidget);
      expect(tester.widget<TextField>(watchlist).controller!.text, 'QQQ, SPY');
      expect(api.posts, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'expanded strategy metrics show recorded graphs and only own decisions',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final accounts = [
        for (final label in ['Alpha', 'Beta'])
          <String, dynamic>{
            'label': label,
            'startingCash': 10000.0,
            'equity': 10100.0,
            'history': [
              {'time': '2026-11-16T15:00:00Z', 'value': 10000},
              {'time': '2026-11-16T15:01:00Z', 'value': 10100},
            ],
            'events': [
              {
                'strategy': label,
                'symbol': 'SOXL',
                'action': 'wait',
                'kind': 'signal',
                'reason': '$label specific decision',
                'time': '2026-11-16T15:01:00Z',
              },
            ],
          },
      ];
      final controller = DashboardController()
        ..status = {'runId': 'one'}
        ..snapshot = {'accounts': accounts};
      addTearDown(controller.dispose);
      Future<void> render() => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: DashboardView(controller: controller)),
        ),
      );
      await render();
      expect(find.text('Performance: Alpha'), findsNothing);
      await tester.scrollUntilVisible(
        find.byTooltip('Expand Alpha performance'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Expand Alpha performance'));
      await tester.pumpAndSettle();
      final alpha = find.byKey(const ValueKey('strategy-performance-Alpha'));
      expect(alpha, findsOneWidget);
      expect(find.text('Performance: Beta'), findsNothing);
      final charts = tester
          .widgetList<EquityChart>(
            find.descendant(of: alpha, matching: find.byType(EquityChart)),
          )
          .toList();
      expect(charts.length, 2);
      expect(charts.first.percent, isTrue);
      expect(charts.last.drawdown, isTrue);
      expect(
        charts.first.colorsByLabel['Alpha'],
        tester
            .widget<EquityChart>(find.byType(EquityChart).first)
            .colorsByLabel['Alpha'],
      );
      expect(
        charts.every(
          (chart) => identical(chart.accounts.single, accounts.first),
        ),
        isTrue,
      );
      expect(
        find.descendant(
          of: alpha,
          matching: find.text('Alpha specific decision'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: alpha,
          matching: find.text('Beta specific decision'),
        ),
        findsNothing,
      );
      await tester.ensureVisible(find.byTooltip('Expand Beta performance'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Expand Beta performance'));
      await tester.pumpAndSettle();
      expect(find.text('Performance: Alpha'), findsOneWidget);
      expect(find.text('Performance: Beta'), findsOneWidget);
      (accounts.first['history'] as List).add({
        'time': '2026-11-16T15:02:00Z',
        'value': 10200,
      });
      await render();
      expect(find.text('Performance: Alpha'), findsOneWidget);
      expect(
        tester
            .widgetList<EquityChart>(
              find.descendant(of: alpha, matching: find.byType(EquityChart)),
            )
            .first
            .accounts
            .single['history'],
        hasLength(3),
      );
      controller.status['runId'] = 'two';
      await render();
      expect(find.text('Performance: Alpha'), findsNothing);
      expect(find.text('Performance: Beta'), findsNothing);
      controller.status['runId'] = 'one';
      await render();
      expect(find.text('Performance: Alpha'), findsOneWidget);
      await tester.ensureVisible(find.byTooltip('Collapse Alpha performance'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Collapse Alpha performance'));
      await tester.pumpAndSettle();
      expect(find.text('Performance: Alpha'), findsNothing);
      expect(find.text('Performance: Beta'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('decision reasoning uses the last column instead of a footer', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DecisionLogView(
            status: const {},
            events: const [
              {
                'strategy': 'Alpha',
                'symbol': 'SOXL',
                'action': 'buy',
                'kind': 'fill',
                'positionSide': 'long',
                'positionEffect': 'open',
                'time': '2026-11-16T15:00:00Z',
                'entryPrice': 20,
                'stop': 19,
                'target': 23,
                'price': 20,
                'reason': 'Recovery confirmed',
              },
            ],
          ),
        ),
      ),
    );
    expect(
      tester.getTopLeft(find.text('Reason')).dy,
      tester.getTopLeft(find.text('Time')).dy,
    );
    expect(
      tester.getTopLeft(find.text('Reason')).dx,
      greaterThan(tester.getTopLeft(find.text('Event')).dx),
    );
    expect(find.text('Recovery confirmed'), findsOneWidget);
    expect(find.byTooltip('Recovery confirmed'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('all portfolio lines have unique matching legend colors', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = DashboardController()
      ..snapshot = {
        'accounts': [
          for (var index = 0; index < 40; index++)
            {
              'label': 'Portfolio $index',
              'startingCash': 10000,
              'history': [
                {'time': '2026-11-16T15:00:00Z', 'value': 10000},
                {'time': '2026-11-16T15:01:00Z', 'value': 10000 + index},
              ],
            },
        ],
      };
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DashboardView(controller: controller)),
      ),
    );
    final chips = tester
        .widgetList<FilterChip>(find.byType(FilterChip))
        .toList();
    expect(chips.length, 40);
    expect(
      chips.map((chip) => chip.selectedColor!.toARGB32()).toSet(),
      hasLength(40),
    );
    Map<String, Color> paintedColors() {
      final painter =
          tester
                  .widgetList<CustomPaint>(
                    find.descendant(
                      of: find.byType(EquityChart).first,
                      matching: find.byType(CustomPaint),
                    ),
                  )
                  .map((widget) => widget.painter)
                  .whereType<CustomPainter>()
                  .first
              as dynamic;
      return {
        for (final dynamic series in painter.series as List)
          series.label as String: series.color as Color,
      };
    }

    final original = paintedColors();
    for (final chip in chips) {
      expect(chip.selectedColor, original[(chip.label as Text).data]);
    }
    await tester.ensureVisible(find.byType(FilterChip).at(10));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FilterChip).at(10));
    await tester.pumpAndSettle();
    final filtered = paintedColors();
    expect(filtered.length, 39);
    expect(filtered, {
      for (final entry in original.entries)
        if (entry.key != 'Portfolio 10') entry.key: entry.value,
    });
    expect(tester.takeException(), isNull);
  });
}
