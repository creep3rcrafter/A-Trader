import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'backend_api.dart';
import 'algorithm_file_picker.dart';
import 'algorithms/imported_definition.dart';
import 'data_export.dart';
import 'mountain_time.dart';
import 'simulator.dart';
import 'strategy_tuning.dart' show maxTuningGenerations, EvolutionSettings;

void main() => runApp(const MyApp());

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final _controller = DashboardController();

  @override
  void initState() {
    super.initState();
    _controller.start();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    builder: (context, _) => MaterialApp(
      title: 'A-Trader Live Simulator',
      debugShowCheckedModeBanner: false,
      themeMode: _controller.themeMode,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      home: SimulatorHome(controller: _controller),
    ),
  );

  ThemeData _theme(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xff3d80c6),
      brightness: brightness,
      surface: brightness == Brightness.dark
          ? const Color(0xff141922)
          : const Color(0xfff7f9fc),
    );
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      visualDensity: VisualDensity.compact,
      scaffoldBackgroundColor: scheme.surface,
      cardTheme: CardThemeData(
        color: brightness == Brightness.dark
            ? const Color(0xff1b222d)
            : Colors.white,
        elevation: 0,
        margin: const EdgeInsets.all(2),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: .55)),
        ),
      ),
      listTileTheme: const ListTileThemeData(
        dense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 10),
        minVerticalPadding: 2,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        isDense: true,
        fillColor: scheme.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
      ),
    );
  }
}

Future<void> _exportRunData(
  BuildContext context,
  DashboardController controller,
) async {
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(
    const SnackBar(content: Text('Exporting simulation data...')),
  );
  try {
    final folder = await exportRunData(
      data: controller.backendConnected
          ? await controller.api.get('/api/export')
          : null,
    );
    if (!context.mounted) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text('Run data exported to $folder'),
        duration: const Duration(seconds: 12),
        action: SnackBarAction(
          label: 'Show file',
          onPressed: () => unawaited(_openRunDataExportFolder(context, folder)),
        ),
      ),
    );
  } catch (error) {
    if (!context.mounted) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(content: Text('Could not export run data: $error')),
    );
  }
}

Future<void> _openRunDataExportFolder(
  BuildContext context,
  String folder,
) async {
  try {
    await openRunDataExportFolder(folder);
  } catch (error) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Could not open export folder: $error')),
    );
  }
}

class DashboardController extends ChangeNotifier {
  DashboardController({
    this.api = const BackendApi(),
    Future<AlgorithmSourceFile?> Function()? algorithmPicker,
  }) : _algorithmPicker = algorithmPicker ?? pickAlgorithmFile;

  final BackendApi api;
  final Future<AlgorithmSourceFile?> Function() _algorithmPicker;
  bool importingAlgorithm = false;
  String algorithmImportStatus = '';
  String _algorithmCatalogue = '';

  Future<TradingStrategy?> importAlgorithm() async {
    if (importingAlgorithm) return null;
    importingAlgorithm = true;
    algorithmImportStatus = 'Choosing an algorithm file…';
    notifyListeners();
    try {
      final file = await _algorithmPicker();
      if (file == null || _disposed) return null;
      algorithmImportStatus = file.name.toLowerCase().endsWith('.dart')
          ? 'Compiling and validating ${file.name}…'
          : 'Validating ${file.name}…';
      notifyListeners();
      final result = await api.post('/api/algorithms/import', {
        'filename': file.name,
        'source': file.source,
      });
      await _refreshInProgress;
      if (_disposed) return null;
      await _refresh();
      final metadata = ImportedAlgorithmDefinition.fromJson(
        result['metadata'] as Map<String, dynamic>,
      );
      final registered = StrategyRegistry.all
          .where((s) => s.id == metadata.id)
          .firstOrNull;
      if (registered != null) return registered;
      StrategyRegistry.replaceImported([
        ...StrategyRegistry.all.where(
          (s) => !StrategyRegistry.builtinIds.contains(s.id),
        ),
        metadata,
      ]);
      return metadata;
    } finally {
      importingAlgorithm = false;
      algorithmImportStatus = '';
      if (!_disposed) notifyListeners();
    }
  }

  Timer? _timer;
  Map<String, dynamic> status = {};
  Map<String, dynamic> snapshot = {};
  List<Map<String, dynamic>> events = [];
  int page = 0;
  ThemeMode themeMode = ThemeMode.system;
  String backendError = '';
  bool backendConnected = false;
  bool backendStarting = false;
  DateTime? lastUpdated;
  Future<void>? _refreshInProgress;
  bool _disposed = false;
  bool _changingRun = false;
  final Map<String, Set<String>> _hiddenSeriesByRun = {};

  bool get supportsRuns => status['runs'] is List && status['runId'] != null;
  bool get isResearchPreview => status['researchPreview'] == true;
  bool get supportsTraining => status['training'] is Map;
  bool get supportsMountainHistoricalReplay =>
      status['historicalTimeZones'] is List &&
      (status['historicalTimeZones'] as List).contains(MountainTime.zoneId);
  Set<String> get hiddenSeries => _hiddenSeriesByRun.putIfAbsent(
    status['runId']?.toString() ?? 'legacy',
    () => <String>{},
  );

  void toggleSeries(String label) {
    if (!hiddenSeries.remove(label)) hiddenSeries.add(label);
    notifyListeners();
  }

  Future<void> selectRun(String runId) =>
      _changeRun('/api/runs/select', {'runId': runId});

  Future<void> renameRun(String runId, String name) =>
      _changeRun('/api/runs/rename', {'runId': runId, 'name': name});

  Future<void> deleteRun(String runId) =>
      _changeRun('/api/runs/delete', {'runId': runId});

  Future<void> createRun(
    Map<String, Object?> configuration, {
    String? name,
    Map<String, Object?>? historicalRange,
  }) => _changeRun('/api/runs/create', {
    'configuration': configuration,
    'name': ?name,
    'historicalRange': ?historicalRange,
  });

  Future<void> setAutoResearch(
    bool enabled, {
    Map<String, Object?>? configuration,
    int generations = 2,
    DateTimeRange? historicalRange,
    TimeOfDay? startTime,
    TimeOfDay? endTime,
    EvolutionSettings evolution = const EvolutionSettings(),
    bool resume = false,
  }) async {
    await api.post(
      enabled ? '/api/research/start' : '/api/research/stop',
      enabled
          ? {
              'runId': status['runId'],
              'evolutions': generations,
              'evolution': evolution.toJson(),
              'resume': resume,
              'configuration': ?configuration,
              if (historicalRange != null)
                'historicalRange': _historicalRequest(
                  historicalRange,
                  startTime: startTime,
                  endTime: endTime,
                ),
            }
          : const {},
    );
    await refresh();
  }

  Future<void> _changeRun(String path, Map<String, Object?> body) async {
    if (_changingRun) {
      throw StateError('A simulation selection is in progress.');
    }
    _changingRun = true;
    try {
      await _refreshInProgress;
      if (_disposed) return;
      await api.post(path, body);
      await _refresh();
    } finally {
      _changingRun = false;
    }
  }

  Future<void> setAutoTraining(bool enabled) async {
    await api.post('/api/training/settings', {'autoTrain': enabled});
    await refresh();
  }

  Future<void> trainNow() async {
    await api.post('/api/training/train', const {});
    await refresh();
  }

  void start() {
    unawaited(refresh());
    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(refresh());
    });
  }

  Future<void> refresh() {
    if (_disposed || backendStarting || _changingRun) {
      return Future<void>.value();
    }
    return _refreshInProgress ??= _refresh().whenComplete(() {
      _refreshInProgress = null;
    });
  }

  Future<void> _refresh() async {
    try {
      final response = await api.get('/api/status');
      final runQuery = response['runId'] == null
          ? ''
          : '?runId=${Uri.encodeQueryComponent('${response['runId']}')}';
      final data = await api.get('/api/snapshot$runQuery');
      final previewEvents = data['previewEvents'];
      final log = previewEvents is List
          ? previewEvents
          : (await api.get('/api/log$runQuery'))['events'] as List? ?? const [];
      if (_disposed) return;
      if (response['algorithms'] case final List imported) {
        final signature = jsonEncode(imported);
        if (signature != _algorithmCatalogue) {
          StrategyRegistry.replaceImported([
            for (final row in imported.cast<Map>())
              ImportedAlgorithmDefinition.fromJson(
                Map<String, dynamic>.from(row['metadata'] as Map),
              ),
          ]);
          _algorithmCatalogue = signature;
        }
      }
      status = previewEvents is List
          ? data['status'] as Map<String, dynamic>? ?? response
          : response;
      snapshot = data;
      events = log.whereType<Map<String, dynamic>>().toList();
      backendConnected = true;
      backendError = '';
      lastUpdated = DateTime.now();
      notifyListeners();
    } catch (error) {
      if (_disposed) return;
      backendConnected = false;
      if (backendError.isEmpty) {
        backendError = error.toString().replaceFirst('Bad state: ', '');
      }
      notifyListeners();
    }
  }

  Future<void> startBackend() async {
    if (_disposed || backendStarting || backendConnected) return;
    backendStarting = true;
    backendError = '';
    notifyListeners();
    try {
      final pendingRefresh = _refreshInProgress;
      if (pendingRefresh != null) await pendingRefresh;
      if (_disposed) return;
      await api.startBackend();
      if (_disposed) return;
      backendStarting = false;
      await refresh();
    } catch (error) {
      if (_disposed) return;
      backendError = error.toString().replaceFirst('Bad state: ', '');
    } finally {
      backendStarting = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> saveRun(Map<String, Object?> configuration) async {
    await api.post('/api/settings/run', configuration);
    await refresh();
  }

  Future<void> startRun(Map<String, Object?> configuration) async {
    await saveRun(configuration);
    await api.post('/api/run/start', const {});
    await refresh();
  }

  /// Starts a replay of Schwab minute history for Mountain calendar dates.
  Future<void> startHistoricalRun(
    Map<String, Object?> configuration,
    DateTimeRange range, {
    TimeOfDay? startTime,
    TimeOfDay? endTime,
  }) async {
    if (!supportsMountainHistoricalReplay) {
      throw StateError(
        'The backend must be updated before starting a Mountain-time replay. '
        'Stop any running simulations before restarting it.',
      );
    }
    final strategies = configuration['strategies'];
    final usesLmSelector =
        strategies is List &&
        strategies.whereType<Map>().any(
          (strategy) =>
              strategy['strategyId'] == 'lm_selector' &&
              strategy['enabled'] == true,
        );
    if (usesLmSelector && status['historicalLmAwaited'] != true) {
      throw StateError(
        'Update the backend before replaying with LM Studio so each candle '
        'waits for its response. Restarting clears in-memory historical '
        'results; preserve any needed results and stop all simulations first.',
      );
    }
    await saveRun(configuration);
    await api.post(
      '/api/run/historical/start',
      _historicalRequest(range, startTime: startTime, endTime: endTime),
    );
    await refresh();
  }

  Map<String, Object?> _historicalRequest(
    DateTimeRange range, {
    TimeOfDay? startTime,
    TimeOfDay? endTime,
  }) {
    String? clock(TimeOfDay? value) => value == null
        ? null
        : '${value.hour.toString().padLeft(2, '0')}:'
              '${value.minute.toString().padLeft(2, '0')}';
    return {
      'startDate': MountainTime.formatDate(range.start),
      'endDate': MountainTime.formatDate(range.end),
      'startTime': ?clock(startTime),
      'endTime': ?clock(endTime),
      'timeZone': MountainTime.zoneId,
    };
  }

  Future<void> stopRun() async {
    await api.post('/api/run/stop', const {});
    await refresh();
  }

  Future<void> resetRun() async {
    await api.post('/api/run/reset', const {});
    await _refreshInProgress;
    await refresh();
  }

  /// Saves any newly entered credentials, then either connects the stream (if
  /// already authorized) or opens Schwab's login page. Returns guidance text.
  Future<String> connectSchwab({
    required String appKey,
    required String appSecret,
    required String redirectUri,
  }) async {
    if (appKey.isNotEmpty || appSecret.isNotEmpty) {
      if (appKey.trim().isEmpty || appSecret.isEmpty) {
        throw StateError(
          'Enter both the Schwab Client ID (App Key) and Client Secret.',
        );
      }
      await api.post('/api/schwab/credentials', {
        'appKey': appKey.trim(),
        'appSecret': appSecret,
        'redirectUri': redirectUri.trim(),
      });
      status = await api.get('/api/status');
    } else if (status['schwabCredentialsSaved'] != true) {
      throw StateError(
        'Enter the Schwab Client ID (App Key) and Client Secret first.',
      );
    }
    final isAuthorized = status['schwabAuthorized'] == true;
    String message;
    if (isAuthorized) {
      await api.post('/api/schwab/connect', const {});
      message = 'Schwab stream connection requested.';
    } else {
      final result = await api.post('/api/schwab/oauth/start', const {});
      api.openExternal(result['authorizationUrl'] as String);
      message =
          'Schwab login opened in your browser. '
          '${result['message'] ?? ''}';
    }
    await refresh();
    return message;
  }

  /// Finishes OAuth from the address the browser showed after Schwab login.
  Future<String> completeSchwabAuthorization(String redirectedUrl) async {
    final result = await api.post('/api/schwab/oauth/complete', {
      'redirectedUrl': redirectedUrl.trim(),
    });
    await refresh();
    return result['message']?.toString() ?? 'Schwab authorized.';
  }

  Future<void> disconnectSchwab() async {
    await api.post('/api/schwab/disconnect', const {});
    await refresh();
  }

  Future<void> removeSchwabCredentials() async {
    await api.post('/api/schwab/credentials/remove', const {});
    await refresh();
  }

  Future<List<String>> discoverModels({
    required String url,
    required String model,
  }) async {
    await api.post('/api/lm/config', {'url': url, 'model': model});
    final response = await api.get('/api/lm/models');
    return (response['models'] as List<dynamic>? ?? [])
        .map((item) => item.toString())
        .toList();
  }

  Future<void> testLmStudio({
    required String url,
    required String model,
  }) async {
    await api.post('/api/lm/config', {'url': url, 'model': model});
    await api.post('/api/lm/test', const {});
  }

  void navigateTo(int page) {
    this.page = page;
    notifyListeners();
  }

  void setThemeMode(ThemeMode mode) {
    themeMode = mode;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}

class SimulatorHome extends StatelessWidget {
  const SimulatorHome({required this.controller, super.key});

  final DashboardController controller;
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: Row(
          children: [
            const Icon(Icons.show_chart_rounded, color: Color(0xff438ad2)),
            const SizedBox(width: 10),
            const Text('A-Trader'),
            if (MediaQuery.sizeOf(context).width > 650) ...[
              const SizedBox(width: 12),
              _ModePill(label: 'LIVE SIMULATION'),
            ],
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Export all run data',
            onPressed: canExportRunData
                ? () => _exportRunData(context, controller)
                : null,
            icon: const Icon(Icons.file_download_outlined),
          ),
          if (MediaQuery.sizeOf(context).width > 650)
            _FeedPill(status: controller.status),
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Settings',
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => SettingsDialog(controller: controller),
            ),
            icon: const Icon(Icons.settings_outlined),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          if (controller.backendError.isNotEmpty || controller.backendStarting)
            _BackendNotice(
              message: controller.backendError,
              onRetry: controller.backendStarting ? null : controller.refresh,
              onStart: controller.api.supportsBackendLaunch
                  ? controller.startBackend
                  : null,
              starting: controller.backendStarting,
            ),
          Expanded(child: DashboardView(controller: controller)),
        ],
      ),
    );
  }
}

class _RunManager extends StatefulWidget {
  const _RunManager({required this.controller, this.configuration});
  final DashboardController controller;
  final Map<String, Object?> Function()? configuration;

  @override
  State<_RunManager> createState() => _RunManagerState();
}

class _RunManagerState extends State<_RunManager> {
  bool _busy = false;
  String? _error;

  Future<String?> _askName({String? current}) {
    var name = current ?? '';
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(current == null ? 'New simulation' : 'Rename simulation'),
        content: TextFormField(
          initialValue: name,
          autofocus: true,
          decoration: InputDecoration(
            labelText: 'Simulation name',
            hintText: current == null ? 'Use the default name' : null,
          ),
          onChanged: (value) => name = value,
          onFieldSubmitted: (_) => Navigator.pop(context, name.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, name.trim()),
            child: Text(current == null ? 'Create' : 'Rename'),
          ),
        ],
      ),
    );
  }

  Future<void> _delete(String id, String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete $name?'),
        content: const Text(
          'This permanently deletes the simulation and its saved results.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete simulation'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _act(() => widget.controller.deleteRun(id));
    }
  }

  Future<void> _act(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    if (!controller.supportsRuns) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text(
          'Multiple runs unavailable on this backend. '
          'An updated backend must be started to enable this feature.',
        ),
      );
    }
    final runs = (controller.status['runs'] as List)
        .whereType<Map<String, dynamic>>()
        .toList();
    final selected = controller.status['runId'].toString();
    final selectedRun = runs.where((run) => run['id'] == selected).firstOrNull;
    final name = (selectedRun?['name'] ?? selected).toString();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: math.min(340, MediaQuery.sizeOf(context).width - 48),
                child: DropdownButtonFormField<String>(
                  key: ValueKey(selected),
                  initialValue: runs.any((run) => '${run['id']}' == selected)
                      ? selected
                      : null,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Simulation run',
                  ),
                  items: [
                    for (final run in runs)
                      DropdownMenuItem(
                        value: '${run['id']}',
                        child: Text(
                          '${run['name'] ?? run['id']}'
                          ' · ${run['running'] == true ? 'Running' : 'Stopped'}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: _busy
                      ? null
                      : (id) {
                          if (id != null && id != selected) {
                            unawaited(_act(() => controller.selectRun(id)));
                          }
                        },
                ),
              ),
              if (controller.isResearchPreview &&
                  (controller.status['research'] as Map?)?['running'] == true)
                FilledButton(
                  onPressed: _busy
                      ? null
                      : () => _act(() => controller.setAutoResearch(false)),
                  child: const Text('Stop'),
                ),
              OutlinedButton.icon(
                onPressed: _busy
                    ? null
                    : () async {
                        final name = await _askName();
                        if (!mounted || name == null) return;
                        await _act(() {
                          final configuration =
                              widget.configuration?.call() ??
                              (controller.status['configuration']
                                  as Map<String, dynamic>?) ??
                              <String, Object?>{
                                for (final key in [
                                  'watchlist',
                                  'startingCash',
                                  'risk',
                                  'strategies',
                                ])
                                  if (controller.status.containsKey(key))
                                    key: controller.status[key],
                              };
                          return controller.createRun(
                            configuration,
                            name: name,
                          );
                        });
                      },
                icon: const Icon(Icons.add),
                label: const Text('New simulation'),
              ),
              if (selectedRun != null && !controller.isResearchPreview) ...[
                OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () async {
                          final updated = await _askName(current: name);
                          if (!mounted || updated == null) return;
                          await _act(
                            () => controller.renameRun(selected, updated),
                          );
                        },
                  child: const Text('Rename'),
                ),
                OutlinedButton(
                  onPressed: _busy || selectedRun['running'] == true
                      ? null
                      : () => _delete(selected, name),
                  child: const Text('Delete'),
                ),
              ],
            ],
          ),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    );
  }
}

class _TrainingPanel extends StatefulWidget {
  const _TrainingPanel({required this.controller});
  final DashboardController controller;

  @override
  State<_TrainingPanel> createState() => _TrainingPanelState();
}

class _TrainingPanelState extends State<_TrainingPanel> {
  bool _busy = false;
  String? _error;

  Future<void> _act(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final training = controller.status['training'];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Model training',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (training is! Map)
              const Text(
                'Training unavailable on this backend. '
                'Start an updated backend; reloading the dashboard does not update it.',
              )
            else ...[
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Automatic training'),
                subtitle: const Text(
                  'Train when collected data meets backend readiness rules.',
                ),
                value:
                    (training['autoTrain'] ?? training['autoTraining']) == true,
                onChanged: _busy
                    ? null
                    : (enabled) =>
                          _act(() => controller.setAutoTraining(enabled)),
              ),
              for (final entry in training.entries.where(
                (entry) =>
                    entry.key != 'autoTrain' &&
                    entry.key != 'autoTraining' &&
                    entry.key != 'candidates',
              ))
                Text(
                  '${_readable('${entry.key}')}: '
                  '${_trainingValue(entry.value, '${entry.key}')}',
                ),
              if (training['candidates'] case final Map candidates)
                for (final entry in candidates.entries)
                  Text(
                    '${_readable('${entry.key}')} candidate: '
                    '${entry.value == null ? 'No validated model yet' : _trainingValue(entry.value, '${entry.key}')}',
                  ),
              const Text(
                'Collection: complete 1-minute live candles only, not historical replays. '
                'Models use 1-minute bars. Validated candidates are pinned only for new runs; '
                'existing run pins never change. An untrained pin stays WAIT.',
              ),
              if (controller.status['pinnedModels'] case final Map pins)
                for (final entry in pins.entries)
                  Text(
                    'Pinned ${_readable('${entry.key}')}: '
                    '${entry.value ?? 'Untrained — WAIT'}',
                  ),
              OutlinedButton.icon(
                onPressed:
                    _busy ||
                        training['training'] == true ||
                        training['running'] == true
                    ? null
                    : () => _act(controller.trainNow),
                icon: const Icon(Icons.model_training),
                label: const Text('Train now'),
              ),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PositionTally extends StatelessWidget {
  const _PositionTally({required this.accounts});
  final List<Map<String, dynamic>> accounts;

  @override
  Widget build(BuildContext context) {
    var longs = 0;
    var shorts = 0;
    var closed = 0;
    for (final account in accounts.where(
      (account) =>
          account['label'] != 'Buy & Hold' &&
          account['label'] != 'Equal Weight',
    )) {
      for (final position
          in (account['positions'] as List? ?? []).whereType<Map>()) {
        final side = position['positionSide'] ?? position['side'];
        if (side == 'short') {
          shorts++;
        } else if (side == 'long' ||
            (side == null && (position['quantity'] as num? ?? 0) > 0)) {
          longs++;
        }
      }
      closed += (account['closedPnl'] as List? ?? []).length;
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Wrap(
        spacing: 16,
        runSpacing: 4,
        children: [
          Text('Open longs: $longs'),
          Text('Open shorts: $shorts'),
          Text('Closed positions: $closed'),
          const Text('All strategies · selected run'),
        ],
      ),
    );
  }
}

class _SimulationControls extends StatefulWidget {
  const _SimulationControls({required this.controller});

  final DashboardController controller;

  @override
  State<_SimulationControls> createState() => _SimulationControlsState();
}

class _SimulationControlsState extends State<_SimulationControls>
    with AutomaticKeepAliveClientMixin<_SimulationControls> {
  bool _opened = false;
  Object? _setupRunId;

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final controller = widget.controller;
    final researchPreview = controller.isResearchPreview;
    if (!researchPreview) _setupRunId = controller.status['runId'];
    return Card(
      child: ExpansionTile(
        title: const Text('Simulation controls'),
        subtitle: Text(
          researchPreview
              ? 'Select a simulation to change the dashboard view'
              : 'Select a run, start or stop, and configure simulations',
        ),
        onExpansionChanged: (expanded) {
          if (expanded && !_opened) {
            setState(() => _opened = true);
          }
        },
        maintainState: true,
        children: [
          if (_opened && (!researchPreview || _setupRunId != null))
            Offstage(
              offstage: researchPreview,
              child: RunSetupView(
                key: ValueKey(_setupRunId),
                controller: controller,
                embedded: true,
              ),
            ),
          if (_opened && researchPreview)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: _RunManager(controller: controller),
            ),
        ],
      ),
    );
  }
}

class DashboardView extends StatefulWidget {
  const DashboardView({required this.controller, super.key});

  final DashboardController controller;

  @override
  State<DashboardView> createState() => _DashboardViewState();
}

class _StrategyBests extends StatefulWidget {
  const _StrategyBests({required this.controller, required this.bests});
  final DashboardController controller;
  final Map bests;

  @override
  State<_StrategyBests> createState() => _StrategyBestsState();
}

class _StrategyBestsState extends State<_StrategyBests> {
  bool _busy = false;
  String? _error;

  Future<void> _use(String label, Map record) async {
    setState(() => _busy = true);
    try {
      final status = widget.controller.status;
      final source =
          (status['trainingSession'] as Map?)?['source'] as Map? ??
          status['configuration'] as Map;
      final configuration = Map<String, Object?>.from(source);
      configuration['strategies'] = [
        for (final row in (source['strategies'] as List).cast<Map>())
          {
            ...row,
            if (row['label'] == label) 'parameters': record['parameters'],
          },
      ];
      final from = MountainTime.at(
        DateTime.parse(record['startUtc'] as String),
      );
      final to = MountainTime.at(DateTime.parse(record['endUtc'] as String));
      await widget.controller.createRun(
        configuration,
        name: '$label · generation ${record['generation']}',
        historicalRange: {
          'startDate': MountainTime.formatDate(from),
          'endDate': MountainTime.formatDate(to),
          'startTime':
              '${from.hour.toString().padLeft(2, '0')}:${from.minute.toString().padLeft(2, '0')}',
          'endTime':
              '${to.hour.toString().padLeft(2, '0')}:${to.minute.toString().padLeft(2, '0')}',
          'timeZone': MountainTime.zoneId,
        },
      );
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Card(
    child: ExpansionTile(
      title: const Text('Best saved strategy settings'),
      children: [
        if (_error != null) Text(_error!),
        for (final entry in widget.bests.entries)
          for (final metric in ['profit', 'winRate'])
            if ((entry.value as Map)[metric] case final Map record)
              ListTile(
                title: Text(
                  '${entry.key} · Best ${metric == 'profit' ? 'net profit' : 'win rate'}',
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Generation ${record['generation']} · '
                      'Profit ${_money((record['performance']['netProfit'] as num).toDouble())} · '
                      'Win rate ${(record['performance']['winRatePercent'] as num?)?.toStringAsFixed(2) ?? '—'}% · '
                      '${record['performance']['closedTrades']} closed trades',
                    ),
                    SelectableText(
                      (record['parameters'] as Map).entries
                          .map(
                            (parameter) =>
                                '${_readable('${parameter.key}')}: ${parameter.value}',
                          )
                          .join(' · '),
                    ),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => _use('${entry.key}', record),
                      child: const Text('New simulation from these settings'),
                    ),
                  ],
                ),
              ),
      ],
    ),
  );
}

class _GenerationChanges extends StatefulWidget {
  const _GenerationChanges({required this.controller, super.key});
  final DashboardController controller;

  @override
  State<_GenerationChanges> createState() => _GenerationChangesState();
}

class _GenerationChangesState extends State<_GenerationChanges>
    with AutomaticKeepAliveClientMixin<_GenerationChanges> {
  Map? _selected;
  bool _tested = true;
  bool _showUnchanged = false;
  bool _loading = false;
  String? _error;
  int _request = 0;

  @override
  bool get wantKeepAlive => true;

  Future<void> _load(int generation) async {
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final runId = Uri.encodeQueryComponent(
        '${widget.controller.status['runId']}',
      );
      final response = await widget.controller.api.get(
        '/api/runs/variable-changes?runId=$runId&generation=$generation',
      );
      if (mounted && request == _request) setState(() => _selected = response);
    } catch (error) {
      if (mounted && request == _request) setState(() => _error = '$error');
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  String _number(num value) => value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toString();

  Widget _strategy(Map row) {
    final current = row['currentParameters'] as Map? ?? const {};
    final proposed =
        (_tested ? row['candidateParameters'] : row['tunedParameters'])
            as Map? ??
        current;
    final keys = {...current.keys, ...proposed.keys}.toList();
    final changed = keys.where((key) => current[key] != proposed[key]).toList();
    final visible = _showUnchanged ? keys : changed;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${row['label']}',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          if (row['message'] case final String message) Text(message),
          if (changed.isEmpty) const Text('Values unchanged'),
          for (final key in visible)
            Wrap(
              spacing: 8,
              children: [
                SelectableText(
                  '${_readable('$key')}: ${current[key] ?? '—'} → ${proposed[key] ?? '—'}',
                ),
                if (current[key] is num && proposed[key] is num)
                  Builder(
                    builder: (context) {
                      final delta =
                          (proposed[key] as num) - (current[key] as num);
                      return Text(
                        delta == 0
                            ? 'Unchanged'
                            : '${delta > 0 ? '+' : '−'}${_number(delta.abs())}',
                        style: TextStyle(
                          color: delta == 0
                              ? Theme.of(context).colorScheme.onSurfaceVariant
                              : _signedValueColor(context, delta),
                        ),
                      );
                    },
                  ),
              ],
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final latest = widget.controller.snapshot['variableChanges'] as Map;
    final selected = _selected ?? latest;
    final generation = selected['generation'] as int;
    final last = latest['latestGeneration'] as int;
    return Card(
      child: ExpansionTile(
        title: const Text('Strategy variable changes'),
        subtitle: Text(
          'Generation $generation · ${_selected == null ? 'Following latest' : 'Saved generation'}',
        ),
        maintainState: true,
        childrenPadding: const EdgeInsets.all(12),
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              IconButton(
                tooltip: 'Previous generation',
                onPressed: _loading || generation <= 1
                    ? null
                    : () => _load(generation - 1),
                icon: const Icon(Icons.chevron_left),
              ),
              Text('Generation $generation of $last'),
              IconButton(
                tooltip: 'Next generation',
                onPressed: _loading || generation >= last
                    ? null
                    : () => _load(generation + 1),
                icon: const Icon(Icons.chevron_right),
              ),
              TextButton(
                onPressed: _selected == null
                    ? null
                    : () {
                        _request++;
                        setState(() {
                          _selected = null;
                          _loading = false;
                          _error = null;
                        });
                      },
                child: const Text('Follow latest'),
              ),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: true, label: Text('Tested values')),
                  ButtonSegment(value: false, label: Text('Accepted values')),
                ],
                selected: {_tested},
                onSelectionChanged: (value) =>
                    setState(() => _tested = value.first),
              ),
            ],
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Show unchanged variables'),
            value: _showUnchanged,
            onChanged: (value) => setState(() => _showUnchanged = value!),
          ),
          if (_loading) const LinearProgressIndicator(),
          if (_error != null) Text(_error!),
          for (final row in (selected['strategies'] as List).cast<Map>())
            _strategy(row),
        ],
      ),
    );
  }
}

class _SimulationActivity extends StatelessWidget {
  const _SimulationActivity({required this.status});

  final Map<String, dynamic> status;

  @override
  Widget build(BuildContext context) {
    final research = status['research'] as Map?;
    final phase = research?['phase'];
    final researchRunning = research?['running'] == true;
    final researchStopping = research?['stopping'] == true;
    final showResearch =
        researchRunning ||
        researchStopping ||
        phase == 'error' ||
        phase == 'complete' ||
        (phase == 'stopped' && research?['runName'] != null);
    final historical =
        status['runMode'] == 'historical' && status['researchPreview'] != true;
    final running = status['running'] == true;
    final runStatus = status['runStatus'] as String?;
    final showRun = running || (runStatus == 'Stopped' || historical);
    final symbols = (status['symbols'] as Map?)?.values
        .whereType<Map>()
        .toList();
    final freshQuotes = symbols?.where((symbol) => symbol['state'] == 'live');
    final manualTuning = status['tuningProgress'] as Map?;
    if (!showResearch && !showRun && manualTuning == null) {
      return const SizedBox.shrink();
    }

    final researchStage = switch (phase) {
      'downloading' => 'Downloading market history',
      'tuning' => 'Tuning strategies',
      'replaying' => 'Replaying tuned simulation',
      'waiting' => 'Waiting for next cycle',
      'stopping' => 'Stopping',
      'stopped' => 'Stopped',
      'error' => 'Cycle failed',
      'complete' => research?['message'] as String? ?? 'Generations complete',
      _ =>
        research?['message'] as String? ??
            (researchStopping ? 'Stopping' : 'Running'),
    };
    final nextCycle = research?['nextCycleAt'] is String
        ? DateTime.tryParse(research!['nextCycleAt'] as String)
        : null;
    final researchWork = switch (phase) {
      'downloading' || 'tuning' || 'replaying' => true,
      _ => false,
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Simulation activity',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            if (showRun)
              _ActivityRow(
                title: historical ? 'Historical replay' : 'Live simulation',
                stage: runStatus ?? (running ? 'Running' : 'Ready'),
                icon: running
                    ? Icons.play_circle_outline
                    : Icons.stop_circle_outlined,
                details: [
                  if (!historical &&
                      running &&
                      symbols != null &&
                      symbols.isNotEmpty)
                    '${freshQuotes!.length}/${symbols.length} symbols have fresh quotes',
                  if (!historical && running && status['feed'] != 'live')
                    if (status['feedReason'] case final String reason) reason,
                ],
                progress: historical && running
                    ? _fraction(status['replayProgress'])
                    : null,
                working: historical && running,
              ),
            if (showResearch)
              _ActivityRow(
                title: 'Automatic research',
                stage: researchStage,
                details: [
                  if (research?['evolutionLimit'] case final int limit)
                    '${research?['cycles'] ?? 0} of $limit generations processed',
                  if (research?['detail'] case final String detail
                      when detail.isNotEmpty && detail != researchStage)
                    detail,
                  if (phase == 'error' && research?['detail'] == null)
                    if (research?['message'] case final String message) message,
                  if (nextCycle != null)
                    'Next cycle ${MountainTime.format(nextCycle, includeSeconds: false)}',
                ],
                icon: switch (phase) {
                  'waiting' => Icons.schedule,
                  'stopping' || 'stopped' => Icons.stop_circle_outlined,
                  'error' => Icons.error_outline,
                  _ => Icons.science_outlined,
                },
                progress: researchWork
                    ? _fraction(research?['progress'])
                    : null,
                remaining: researchWork
                    ? (research?['remainingSeconds'])
                    : null,
                working: researchWork,
              ),
            if (manualTuning != null)
              _ActivityRow(
                title: 'Manual retune',
                stage: 'Tuning strategies',
                icon: Icons.tune,
                progress: _fraction(manualTuning['fraction']),
                remaining: manualTuning['remainingSeconds'],
                working: true,
              ),
          ],
        ),
      ),
    );
  }

  static double? _fraction(Object? value) =>
      value is num && value.isFinite ? value.clamp(0.0, 1.0).toDouble() : null;
}

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({
    required this.title,
    required this.stage,
    required this.icon,
    this.details = const [],
    this.progress,
    this.remaining,
    this.working = false,
  });

  final String title;
  final String stage;
  final IconData icon;
  final List<String> details;
  final double? progress;
  final Object? remaining;
  final bool working;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final seconds = switch (remaining) {
      final num value when value.isFinite && value > 0 => value.ceil(),
      _ => null,
    };
    final information = [
      if (progress != null) '${(progress! * 100).floor()}% complete',
      if (seconds != null)
        seconds < 60
            ? 'About ${seconds}s remaining'
            : 'About ${(seconds / 60).ceil()} min remaining',
      ...details,
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            icon,
            size: 18,
            color: icon == Icons.error_outline
                ? theme.colorScheme.error
                : theme.colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  liveRegion: true,
                  child: Text(
                    '$title · $stage',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                if (information.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    information.join(' · '),
                    style: theme.textTheme.bodySmall,
                  ),
                ],
                if (working) ...[
                  const SizedBox(height: 6),
                  LinearProgressIndicator(
                    value: progress,
                    semanticsLabel: '$title progress',
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DashboardViewState extends State<DashboardView> {
  bool _showTrialEquity = true;
  bool dollars = true;
  int sortColumn = 2;
  bool ascending = false;
  final Map<String, Set<String>> _expandedMetricsByRun = {};

  Set<String> get _expandedMetrics => _expandedMetricsByRun.putIfAbsent(
    '${widget.controller.status['runId']}',
    () => {},
  );

  @override
  Widget build(BuildContext context) {
    final accounts = _accounts(widget.controller.snapshot);
    final generationEquity =
        (widget.controller.snapshot['generationEquity'] as List? ?? const [])
            .whereType<Map<String, dynamic>>()
            .toList();
    final seriesColors = _portfolioColors(accounts);
    final live = widget.controller.status['running'] == true;
    final selectedRun = (widget.controller.status['runs'] as List? ?? [])
        .whereType<Map>()
        .where((run) => run['id'] == widget.controller.status['runId'])
        .firstOrNull;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.controller.isResearchPreview
                        ? 'Research dashboard'
                        : 'Live dashboard',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    widget.controller.isResearchPreview
                        ? widget.controller.status['runStatus']?.toString() ??
                              'Charts and metrics refresh after each research cycle'
                        : live
                        ? 'Independent strategy portfolios · live quotes'
                        : 'Waiting for Schwab connection and a live simulation',
                  ),
                ],
              ),
            ),
            TextButton.icon(
              onPressed: widget.controller.refresh,
              icon: const Icon(Icons.refresh),
              label: const Text('Refresh'),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            'Simulation: ${selectedRun?['name'] ?? widget.controller.status['runName'] ?? widget.controller.status['runId'] ?? 'Not selected'}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        _SimulationActivity(status: widget.controller.status),
        _SimulationControls(controller: widget.controller),
        if (widget.controller.status['strategyBests'] case final Map bests
            when bests.isNotEmpty)
          _StrategyBests(controller: widget.controller, bests: bests),
        _summaryCards(context, accounts, widget.controller.status),
        _PositionTally(accounts: accounts),
        const SizedBox(height: 10),
        _DashboardCandles(
          key: ValueKey('candles-${widget.controller.status['runId']}'),
          controller: widget.controller,
        ),
        const SizedBox(height: 10),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Equity by portfolio (each strategy separate)',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(value: true, label: Text('\$')),
                        ButtonSegment(value: false, label: Text('%')),
                      ],
                      selected: {dollars},
                      onSelectionChanged: (value) =>
                          setState(() => dollars = value.first),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                _Legend(
                  accounts: accounts,
                  status: widget.controller.status,
                  hiddenLabels: widget.controller.hiddenSeries,
                  onToggle: (label) {
                    widget.controller.toggleSeries(label);
                    setState(() {});
                  },
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 245,
                  child: EquityChart(
                    accounts: accounts,
                    percent: !dollars,
                    showStartingCash: true,
                    colorsByLabel: seriesColors,
                    hiddenLabels: widget.controller.hiddenSeries,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        if (generationEquity.isNotEmpty) ...[
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Equity by portfolio across generations',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: true, label: Text('Tested')),
                      ButtonSegment(value: false, label: Text('Accepted')),
                    ],
                    selected: {_showTrialEquity},
                    onSelectionChanged: (value) =>
                        setState(() => _showTrialEquity = value.first),
                  ),
                  Text(
                    _showTrialEquity
                        ? 'Ending equity of the candidate tested in each generation'
                        : 'Ending equity after each generation’s validation',
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 220,
                    child: EquityChart(
                      accounts: generationEquity,
                      byGeneration: true,
                      showTrialEquity: _showTrialEquity,
                      percent: !dollars,
                      showStartingCash: true,
                      colorsByLabel: seriesColors,
                      hiddenLabels: widget.controller.hiddenSeries,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
        ],
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Drawdown',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 120,
                  child: EquityChart(
                    accounts: accounts,
                    drawdown: true,
                    colorsByLabel: seriesColors,
                    hiddenLabels: widget.controller.hiddenSeries,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        _metricsTable(context, accounts),
        if (widget.controller.snapshot['variableChanges'] case {
          'generation': final int _,
        })
          _GenerationChanges(
            key: ValueKey(
              'changes-${widget.controller.status['runId']}-'
              '${(widget.controller.snapshot['variableChanges'] as Map)['sessionId']}',
            ),
            controller: widget.controller,
          ),
        const SizedBox(height: 10),
        _warmupPanel(context, widget.controller.status),
        const SizedBox(height: 10),
        _OpenTrades(accounts: accounts, status: widget.controller.status),
        const SizedBox(height: 10),
        Card(
          child: SizedBox(
            height: 600,
            child: DecisionLogView(
              key: ValueKey(widget.controller.status['runId']),
              events: widget.controller.events,
              status: widget.controller.status,
            ),
          ),
        ),
        const SizedBox(height: 10),
        if (widget.controller.status['training'] case {'ready': true})
          _TrainingPanel(controller: widget.controller),
      ],
    );
  }

  Widget _summaryCards(
    BuildContext context,
    List<Map<String, dynamic>> accounts,
    Map<String, dynamic> status,
  ) {
    final start = (status['startingCash'] as num?)?.toDouble() ?? 0;
    double returnOf(Map<String, dynamic> account) {
      final begin = (account['startingCash'] as num?)?.toDouble() ?? 0;
      final equity = (account['equity'] as num?)?.toDouble() ?? begin;
      return begin > 0 ? (equity - begin) / begin * 100 : 0;
    }

    final strategies = accounts
        .where(
          (a) => a['label'] != 'Buy & Hold' && a['label'] != 'Equal Weight',
        )
        .toList();
    final ranked = [...strategies]
      ..sort((a, b) => returnOf(b).compareTo(returnOf(a)));
    String describe(Map<String, dynamic>? account) {
      if (account == null) return '?';
      final value = returnOf(account);
      return '${value >= 0 ? '+' : ''}${value.toStringAsFixed(2)}%';
    }

    final symbols = (status['watchlist'] as List<dynamic>? ?? []).join(' ? ');
    final values = [
      (
        'Starting cash',
        _money(start),
        'Each portfolio starts separately with this',
      ),
      (
        'Best strategy',
        describe(ranked.firstOrNull),
        ranked.firstOrNull?['label']?.toString() ?? 'No results yet',
      ),
      (
        'Worst strategy',
        describe(ranked.lastOrNull),
        ranked.lastOrNull?['label']?.toString() ?? 'No results yet',
      ),
      (
        'Watchlist',
        symbols.isEmpty ? 'SOXL ? OKLO ? SMR' : symbols,
        '${strategies.length} independent strategy portfolios',
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth > 1000 ? 4 : 2;
        return GridView.count(
          crossAxisCount: columns,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          childAspectRatio: columns == 4
              ? 1.9
              : constraints.maxWidth < 500
              ? 1.3
              : 2.4,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          children: [
            for (final item in values)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(15),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        item.$1,
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        item.$2,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      Text(
                        item.$3,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _metricsTable(
    BuildContext context,
    List<Map<String, dynamic>> accounts,
  ) {
    final metrics = accounts.map(_metrics).toList();
    metrics.sort((a, b) {
      final comparison = (a[sortColumn] as num).compareTo(b[sortColumn] as num);
      return ascending ? comparison : -comparison;
    });
    const headings = [
      'Portfolio',
      'Net P&L',
      'Return',
      'Max DD',
      'Trades',
      'Win rate',
      'Avg win',
      'Avg loss',
      'Avg / trade',
      'Time invested',
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Strategy metrics',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: math.max(1420, constraints.maxWidth),
                  child: Column(
                    children: [
                      for (var row = 0; row < metrics.length; row++) ...[
                        DataTable(
                          headingRowHeight: row == 0 ? 56 : 0,
                          columnSpacing: 24,
                          horizontalMargin: 12,
                          showCheckboxColumn: false,
                          sortColumnIndex: row == 0 ? sortColumn : null,
                          sortAscending: ascending,
                          columns: [
                            for (
                              var index = 0;
                              index < headings.length;
                              index++
                            )
                              DataColumn(
                                columnWidth: FixedColumnWidth(
                                  index == 0
                                      ? 280
                                      : index == 9
                                      ? 180
                                      : 120,
                                ),
                                label: row == 0
                                    ? Flexible(child: Text(headings[index]))
                                    : const SizedBox.shrink(),
                                onSort: index == 0 || row != 0
                                    ? null
                                    : (column, order) => setState(() {
                                        sortColumn = column;
                                        ascending = order;
                                      }),
                              ),
                          ],
                          rows: [
                            for (final metric in [metrics[row]])
                              DataRow(
                                onSelectChanged: (_) =>
                                    _toggleMetric('${metric[0]}'),
                                cells: [
                                  DataCell(
                                    Row(
                                      children: [
                                        IconButton(
                                          tooltip:
                                              '${_expandedMetrics.contains('${metric[0]}') ? 'Collapse' : 'Expand'} ${metric[0]} performance',
                                          iconSize: 18,
                                          visualDensity: VisualDensity.compact,
                                          icon: Icon(
                                            _expandedMetrics.contains(
                                                  '${metric[0]}',
                                                )
                                                ? Icons.expand_less
                                                : Icons.expand_more,
                                          ),
                                          onPressed: () =>
                                              _toggleMetric('${metric[0]}'),
                                        ),
                                        Expanded(
                                          child: _StrategyLabel(
                                            label: metric[0].toString(),
                                            info: _portfolioInformation(
                                              metric[0].toString(),
                                              widget.controller.status,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  DataCell(
                                    _metricValue(
                                      _money(metric[1] as double),
                                      metric[1] as num,
                                    ),
                                  ),
                                  DataCell(
                                    _metricValue(
                                      '${(metric[2] as double).toStringAsFixed(2)}%',
                                      metric[2] as num,
                                    ),
                                  ),
                                  DataCell(
                                    _metricValue(
                                      '${(metric[3] as double).toStringAsFixed(2)}%',
                                      metric[3] as num,
                                    ),
                                  ),
                                  DataCell(
                                    _metricValue(metric[4].toString(), 0),
                                  ),
                                  DataCell(
                                    Tooltip(
                                      message:
                                          '${metric[11]} winning and ${metric[12]} losing of ${metric[10]} closed trades',
                                      child: (metric[10] as int) == 0
                                          ? _metricValue('— (0 closed)', 0)
                                          : _metricValue(
                                              '${(metric[5] as double).toStringAsFixed(1)}% '
                                              '(${metric[11]}/${metric[10]})',
                                              (metric[5] as double) - 50,
                                            ),
                                    ),
                                  ),
                                  DataCell(
                                    (metric[11] as int) == 0
                                        ? _metricValue('— (no wins)', 0)
                                        : _metricValue(
                                            _money(metric[6] as double),
                                            metric[6] as num,
                                          ),
                                  ),
                                  DataCell(
                                    (metric[12] as int) == 0
                                        ? _metricValue('— (no losses)', 0)
                                        : _metricValue(
                                            _money(metric[7] as double),
                                            metric[7] as num,
                                          ),
                                  ),
                                  DataCell(
                                    (metric[10] as int) == 0
                                        ? _metricValue('—', 0)
                                        : _metricValue(
                                            _money(metric[8] as double),
                                            metric[8] as num,
                                          ),
                                  ),
                                  DataCell(
                                    _metricValue(
                                      '${(metric[9] as double).toStringAsFixed(1)}%',
                                      metric[9] as num,
                                    ),
                                  ),
                                ],
                              ),
                          ],
                        ),
                        if (_expandedMetrics.contains('${metrics[row][0]}'))
                          Align(
                            alignment: Alignment.centerLeft,
                            child: SizedBox(
                              width: constraints.maxWidth,
                              child: _StrategyPerformance(
                                key: ValueKey(
                                  '${widget.controller.status['runId']}-${metrics[row][0]}',
                                ),
                                account: accounts.firstWhere(
                                  (account) =>
                                      account['label'] == metrics[row][0],
                                ),
                                controller: widget.controller,
                              ),
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            if (accounts.isEmpty)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  'No portfolio history yet. Start a verified live run to collect results.',
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _toggleMetric(String label) => setState(() {
    if (!_expandedMetrics.remove(label)) _expandedMetrics.add(label);
  });

  Widget _metricValue(String text, num value) => Text(
    text,
    style: TextStyle(
      color: _signedValueColor(context, value),
      fontWeight: FontWeight.w600,
    ),
  );

  List<Object> _metrics(Map<String, dynamic> account) {
    final start = (account['startingCash'] as num?)?.toDouble() ?? 0;
    final equity = (account['equity'] as num?)?.toDouble() ?? start;
    final history = (account['history'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map((item) => (item['value'] as num).toDouble())
        .toList();
    var peak = start;
    var maximumDrawdown = 0.0;
    for (final value in history) {
      peak = value > peak ? value : peak;
      if (peak > 0) {
        maximumDrawdown = maximumDrawdown > (peak - value) / peak
            ? maximumDrawdown
            : (peak - value) / peak;
      }
    }
    final closed = (account['closedPnl'] as List<dynamic>? ?? [])
        .map((item) => (item as num).toDouble())
        .toList();
    final wins = closed.where((value) => value > 0).toList();
    final losses = closed.where((value) => value < 0).toList();
    final events =
        (account['events'] as List<dynamic>? ?? [])
            .whereType<Map<String, dynamic>>()
            .where((event) => event['kind'] == 'fill')
            .toList()
          ..sort(
            (a, b) => DateTime.parse(
              a['time'] as String,
            ).compareTo(DateTime.parse(b['time'] as String)),
          );
    final openTimes = <String, DateTime>{};
    final investedIntervals = <(DateTime, DateTime)>[];
    for (final event in events) {
      final time = DateTime.parse(event['time'] as String);
      final symbol = event['symbol'] as String;
      if (event['positionEffect'] == 'open' ||
          (event['positionEffect'] == null && event['action'] == 'buy')) {
        openTimes[symbol] = time;
      } else if (event['positionEffect'] == 'close' ||
          (event['positionEffect'] == null && event['action'] == 'sell')) {
        final opened = openTimes.remove(symbol);
        if (opened != null && time.isAfter(opened)) {
          investedIntervals.add((opened, time));
        }
      }
    }
    final historyPoints = (account['history'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .toList();
    final runStart = historyPoints.isEmpty
        ? null
        : DateTime.parse(historyPoints.first['time'] as String);
    final runEnd = historyPoints.isEmpty
        ? null
        : DateTime.parse(historyPoints.last['time'] as String);
    for (final position
        in account['positions'] as List<dynamic>? ?? <dynamic>[]) {
      final opened = DateTime.tryParse(
        (position as Map<String, dynamic>)['entryTime'] as String? ?? '',
      );
      if (opened != null && runEnd != null && runEnd.isAfter(opened)) {
        investedIntervals.add((opened, runEnd));
      }
    }
    investedIntervals.sort((a, b) => a.$1.compareTo(b.$1));
    var investedDuration = Duration.zero;
    DateTime? intervalStart;
    DateTime? intervalEnd;
    for (final interval in investedIntervals) {
      if (intervalStart == null || interval.$1.isAfter(intervalEnd!)) {
        if (intervalStart != null) {
          investedDuration += intervalEnd!.difference(intervalStart);
        }
        intervalStart = interval.$1;
        intervalEnd = interval.$2;
      } else if (interval.$2.isAfter(intervalEnd)) {
        intervalEnd = interval.$2;
      }
    }
    if (intervalStart != null) {
      investedDuration += intervalEnd!.difference(intervalStart);
    }
    final runDuration = runStart == null || runEnd == null
        ? Duration.zero
        : runEnd.difference(runStart);
    return [
      account['label'] ?? '',
      equity - start,
      start > 0 ? (equity - start) / start * 100 : 0.0,
      maximumDrawdown == 0 ? 0.0 : -maximumDrawdown * 100,
      (account['positions'] as List<dynamic>? ?? []).length + closed.length,
      closed.isEmpty ? 0.0 : wins.length / closed.length * 100,
      wins.isEmpty ? 0.0 : wins.reduce((a, b) => a + b) / wins.length,
      losses.isEmpty ? 0.0 : losses.reduce((a, b) => a + b) / losses.length,
      closed.isEmpty ? 0.0 : closed.reduce((a, b) => a + b) / closed.length,
      runDuration.inMicroseconds <= 0
          ? 0.0
          : (investedDuration.inMicroseconds / runDuration.inMicroseconds)
                    .clamp(0, 1)
                    .toDouble() *
                100,
      closed.length,
      wins.length,
      losses.length,
    ];
  }

  Widget _warmupPanel(BuildContext context, Map<String, dynamic> status) {
    final strategies = status['strategies'] as List<dynamic>? ?? [];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Strategy readiness',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            if (strategies.isEmpty)
              const Text('No strategies configured.')
            else
              for (final value in strategies)
                if ((value as Map<String, dynamic>)['enabled'] == true)
                  _WarmupRow(strategy: value),
          ],
        ),
      ),
    );
  }
}

class _WarmupRow extends StatelessWidget {
  const _WarmupRow({required this.strategy});

  final Map<String, dynamic> strategy;

  @override
  Widget build(BuildContext context) {
    final required = strategy['warmupRequired'] as int? ?? 1;
    final counts = strategy['warmupBySymbol'] as Map<String, dynamic>? ?? {};
    final readiness = strategy['readyBySymbol'] as Map<String, dynamic>?;
    bool readyFor(String symbol) =>
        readiness?[symbol] as bool? ??
        (counts[symbol] is num && (counts[symbol] as num) >= required);
    final ready = counts.isNotEmpty && counts.keys.every(readyFor);
    final color = _signedValueColor(context, ready ? 1 : -1);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Icon(
            ready ? Icons.check_circle : Icons.cancel,
            color: color,
            size: 16,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: _StrategyLabel(
              label: '${strategy['label']} · ${strategy['intervalMinutes']}m',
              portfolioLabel: strategy['label']?.toString(),
              info: _informationForStrategyId(strategy['strategyId']),
              style: TextStyle(color: color),
            ),
          ),
          Tooltip(
            message:
                strategy['readinessReason']?.toString() ??
                (ready
                    ? 'Ready for decisions.'
                    : 'Collecting bars or waiting for the configured model.'),
            child: Text(
              ready ? 'Ready' : 'Not ready',
              style: TextStyle(color: color),
            ),
          ),
          for (final entry in counts.entries)
            Padding(
              padding: const EdgeInsets.only(left: 14),
              child: Text(
                '${entry.key}: ${entry.value} of $required bars',
                style: TextStyle(
                  color: _signedValueColor(
                    context,
                    readyFor(entry.key) ? 1 : -1,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _DashboardCandles extends StatefulWidget {
  const _DashboardCandles({required this.controller, super.key});
  final DashboardController controller;

  @override
  State<_DashboardCandles> createState() => _DashboardCandlesState();
}

class _DashboardCandlesState extends State<_DashboardCandles> {
  final Map<String, int> _intervals = {};

  @override
  Widget build(BuildContext context) {
    final candles =
        widget.controller.snapshot['candles'] as Map<String, dynamic>? ?? {};
    final symbols =
        (widget.controller.status['watchlist'] as List<dynamic>? ?? [])
            .map((item) => item.toString())
            .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Candle charts', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (symbols.isEmpty)
          const Text('Select a simulation watchlist to see candle charts.'),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= 1200
                ? 3
                : constraints.maxWidth >= 760
                ? 2
                : 1;
            final width = (constraints.maxWidth - (columns - 1) * 8) / columns;
            return Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final symbol in symbols)
                  SizedBox(
                    width: width,
                    child: _chart(context, symbol, candles),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _chart(
    BuildContext context,
    String symbol,
    Map<String, dynamic> candles,
  ) {
    final available =
        candles.keys
            .where((key) => key.startsWith('$symbol:'))
            .map((key) => int.tryParse(key.substring(symbol.length + 1)))
            .whereType<int>()
            .where((interval) => interval > 0)
            .toSet()
            .toList()
          ..sort();
    final interval = _intervals[symbol] ?? available.firstOrNull ?? 1;
    final options = {...available, interval}.toList()..sort();
    final rows = candles['$symbol:$interval'] as List<dynamic>? ?? [];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '$symbol candles',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                DropdownButton<int>(
                  key: ValueKey('candle-interval-$symbol'),
                  value: interval,
                  underline: const SizedBox.shrink(),
                  items: [
                    for (final value in options)
                      DropdownMenuItem(value: value, child: Text('${value}m')),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      setState(() => _intervals[symbol] = value);
                    }
                  },
                ),
              ],
            ),
            SizedBox(
              height: 220,
              child: rows.isEmpty
                  ? _EmptyChart(
                      text:
                          'No completed ${interval}m candles for $symbol yet.',
                    )
                  : CandleChart(
                      key: ValueKey('$symbol:$interval'),
                      rows: rows,
                      events: widget.controller.events
                          .where((event) => event['symbol'] == symbol)
                          .toList(),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StrategyPerformance extends StatelessWidget {
  const _StrategyPerformance({
    required this.account,
    required this.controller,
    super.key,
  });
  final Map<String, dynamic> account;
  final DashboardController controller;

  @override
  Widget build(BuildContext context) {
    final label = '${account['label']}';
    final accountEvents = (account['events'] as List? ?? [])
        .whereType<Map<String, dynamic>>()
        .toList();
    final events = accountEvents.isNotEmpty
        ? [
            for (final event in accountEvents) {...event, 'strategy': label},
          ]
        : controller.events
              .where((event) => event['strategy'] == label)
              .toList();
    events.sort((a, b) {
      final aTime = DateTime.tryParse('${a['time'] ?? ''}');
      final bTime = DateTime.tryParse('${b['time'] ?? ''}');
      if (aTime == null) return bTime == null ? 0 : 1;
      if (bTime == null) return -1;
      return bTime.compareTo(aTime);
    });
    Widget chart(String heading, {bool drawdown = false}) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(heading, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        SizedBox(
          height: 190,
          child: EquityChart(
            accounts: [account],
            colorsByLabel: _portfolioColors(_accounts(controller.snapshot)),
            percent: !drawdown,
            drawdown: drawdown,
            showStartingCash: !drawdown,
          ),
        ),
      ],
    );
    return Container(
      key: ValueKey('strategy-performance-$label'),
      padding: const EdgeInsets.all(12),
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Performance: $label',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const Text('Recorded portfolio marks over time; hover for values.'),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, constraints) => constraints.maxWidth >= 760
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: chart('Return over time')),
                      const SizedBox(width: 12),
                      Expanded(
                        child: chart('Drawdown over time', drawdown: true),
                      ),
                    ],
                  )
                : Column(
                    children: [
                      chart('Return over time'),
                      const SizedBox(height: 8),
                      chart('Drawdown over time', drawdown: true),
                    ],
                  ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 480,
            child: DecisionLogView(
              title: 'Decisions: $label',
              events: events,
              status: controller.status,
            ),
          ),
        ],
      ),
    );
  }
}

class _OpenTrades extends StatelessWidget {
  const _OpenTrades({required this.accounts, required this.status});

  final List<Map<String, dynamic>> accounts;
  final Map<String, dynamic> status;

  @override
  Widget build(BuildContext context) {
    final portfolios = accounts.where(
      (account) =>
          account['label'] != 'Buy & Hold' &&
          account['label'] != 'Equal Weight',
    );
    final trades = [
      for (final account in portfolios)
        for (final position
            in (account['positions'] as List? ?? []).whereType<Map>())
          if ((position['quantity'] as num? ?? 0) > 0) (account, position),
    ];
    String price(Object? value) =>
        value is num ? _money(value.toDouble()) : '—';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Open trades by strategy (${trades.length})',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (trades.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('No open strategy trades in this simulation.'),
              )
            else
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  columnSpacing: 20,
                  horizontalMargin: 0,
                  columns: [
                    for (final label in [
                      'Strategy',
                      'Ticker',
                      'Side',
                      'Shares',
                      'Entry',
                      'Stop',
                      'Target',
                      'Opened (Mountain)',
                    ])
                      DataColumn(label: Text(label)),
                  ],
                  rows: [
                    for (final (account, position) in trades)
                      DataRow(
                        cells: [
                          DataCell(
                            _StrategyLabel(
                              label: '${account['label']}',
                              info: _portfolioInformation(
                                '${account['label']}',
                                status,
                              ),
                            ),
                          ),
                          DataCell(Text('${position['symbol'] ?? '—'}')),
                          DataCell(Text(_positionSideLabel(position))),
                          DataCell(Text('${position['quantity']}')),
                          DataCell(Text(price(position['entryPrice']))),
                          DataCell(Text(price(position['stop']))),
                          DataCell(Text(price(position['target']))),
                          DataCell(
                            Text(
                              _formatTime(
                                DateTime.tryParse(
                                  '${position['entryTime'] ?? ''}',
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

String _positionSideLabel(Map event) {
  final position = event['position'];
  final side =
      (event['positionSide'] ??
              event['side'] ??
              (position is Map
                  ? position['positionSide'] ?? position['side']
                  : null))
          ?.toString()
          .toLowerCase();
  if (side == 'short') return 'SHORT';
  if (side == 'long') return 'LONG';
  final quantity = position is Map ? position['quantity'] : event['quantity'];
  if (side == null && quantity is num && quantity > 0) return 'LONG';
  return 'Unspecified';
}

class DecisionLogView extends StatefulWidget {
  const DecisionLogView({
    required this.events,
    required this.status,
    this.title = 'Decision log',
    super.key,
  });
  final List<Map<String, dynamic>> events;
  final Map<String, dynamic> status;
  final String title;

  @override
  State<DecisionLogView> createState() => _DecisionLogViewState();
}

class _DecisionLogViewState extends State<DecisionLogView> {
  final Set<String> _strategies = {};
  final Set<String> _symbols = {};
  final Set<String> _actions = {};
  final Set<String> _sides = {};
  final Set<String> _kinds = {};
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    List<String> options(String key) =>
        widget.events
            .map((event) => event[key]?.toString() ?? '')
            .where((value) => value.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    bool matches(Set<String> selected, String value) =>
        selected.isEmpty || selected.contains(value);
    final query = _search.text.trim().toLowerCase();
    final visible = widget.events.where((event) {
      final eventAction = event['action'].toString().toUpperCase();
      return matches(_strategies, '${event['strategy']}') &&
          matches(_symbols, '${event['symbol']}') &&
          matches(_actions, eventAction) &&
          matches(_sides, _positionSideLabel(event)) &&
          matches(_kinds, '${event['kind']}') &&
          (query.isEmpty ||
              [
                event['strategy'],
                event['symbol'],
                eventAction,
                _positionSideLabel(event),
                event['kind'],
                event['reason'],
              ].join(' ').toLowerCase().contains(query));
    }).toList();
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.title, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          TextField(
            controller: _search,
            decoration: const InputDecoration(
              labelText: 'Search decisions',
              hintText: 'Ticker, strategy, direction, or reason',
              prefixIcon: Icon(Icons.search),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              _filter('Strategy', _strategies, options('strategy')),
              _filter('Ticker', _symbols, options('symbol')),
              _filter('Side', _sides, const ['LONG', 'SHORT', 'Unspecified']),
              _filter(
                'Action',
                _actions,
                options(
                  'action',
                ).map((value) => value.toUpperCase()).toSet().toList(),
              ),
              _filter('Event', _kinds, options('kind')),
              TextButton(
                onPressed: () => setState(() {
                  for (final selection in [
                    _strategies,
                    _symbols,
                    _sides,
                    _actions,
                    _kinds,
                  ]) {
                    selection.clear();
                  }
                  _search.clear();
                }),
                child: const Text('Clear filters'),
              ),
            ],
          ),
          Text(
            '${visible.length} matching events',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Expanded(
            child: visible.isEmpty
                ? const Text('No events match these filters.')
                : ListView.builder(
                    key: const PageStorageKey('decision-events'),
                    itemCount: visible.length,
                    itemBuilder: (context, index) => _EventCard(
                      event: visible[index],
                      status: widget.status,
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _filter(String label, Set<String> selected, List<String> options) =>
      _LogMultiFilter(
        label: label,
        selected: selected,
        options: {...options, ...selected}.toList()..sort(),
        onChanged: (value, enabled) => setState(() {
          enabled ? selected.add(value) : selected.remove(value);
        }),
        onClear: () => setState(selected.clear),
      );
}

class _LogMultiFilter extends StatefulWidget {
  const _LogMultiFilter({
    required this.label,
    required this.selected,
    required this.options,
    required this.onChanged,
    required this.onClear,
  });
  final String label;
  final Set<String> selected;
  final List<String> options;
  final void Function(String, bool) onChanged;
  final VoidCallback onClear;

  @override
  State<_LogMultiFilter> createState() => _LogMultiFilterState();
}

class _LogMultiFilterState extends State<_LogMultiFilter> {
  String _query = '';
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MenuAnchor(
    style: const MenuStyle(maximumSize: WidgetStatePropertyAll(Size(320, 360))),
    menuChildren: [
      SizedBox(
        width: math.min(280, MediaQuery.sizeOf(context).width - 48),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: TextField(
            controller: _search,
            decoration: InputDecoration(
              labelText: 'Find ${widget.label.toLowerCase()}',
            ),
            onChanged: (value) => setState(() => _query = value.toLowerCase()),
          ),
        ),
      ),
      MenuItemButton(
        onPressed: widget.onClear,
        child: const Text('All (clear selection)'),
      ),
      for (final option in widget.options.where(
        (option) => option.toLowerCase().contains(_query),
      ))
        CheckboxMenuButton(
          value: widget.selected.contains(option),
          closeOnActivate: false,
          onChanged: (enabled) => widget.onChanged(option, enabled == true),
          child: Text(option),
        ),
    ],
    builder: (context, controller, child) => OutlinedButton(
      onPressed: () =>
          controller.isOpen ? controller.close() : controller.open(),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${widget.label}: ${widget.selected.isEmpty
                ? 'All'
                : widget.selected.length == 1
                ? widget.selected.single
                : '${widget.selected.length} selected'}',
          ),
          const Icon(Icons.arrow_drop_down, size: 18),
        ],
      ),
    ),
  );
}

class _EventCard extends StatelessWidget {
  const _EventCard({required this.event, required this.status});

  final Map<String, dynamic> event;
  final Map<String, dynamic> status;

  @override
  Widget build(BuildContext context) {
    final action = event['action'].toString().toUpperCase();
    final color = action == 'BUY'
        ? const Color(0xff15803d)
        : action == 'SELL'
        ? const Color(0xffc2413b)
        : Colors.grey;
    final time = DateTime.tryParse(event['time']?.toString() ?? '');
    final measurements = event['measurements'] as Map<String, dynamic>? ?? {};
    final theme = Theme.of(context);
    final divider = theme.colorScheme.outlineVariant.withValues(alpha: .7);
    final small = theme.textTheme.bodySmall!;
    final strong = small.copyWith(fontWeight: FontWeight.w600);
    final reason = event['reason']?.toString() ?? '';
    final details = measurements.isEmpty ? '' : _measurements(measurements);

    String price(Object? value) =>
        value is num ? _money(value.toDouble()) : '—';
    final sideLabel = _positionSideLabel(event);
    final cells = <(String, Widget, double)>[
      ('Time', Text(_formatTime(time), style: small), 190),
      ('Action', Text(action, style: strong.copyWith(color: color)), 62),
      if (sideLabel != 'Unspecified')
        ('Side', Text(sideLabel, style: strong), 62),
      (
        'Strategy',
        _StrategyLabel(
          label: event['strategy']?.toString() ?? '—',
          style: small,
          info: _portfolioInformation(
            event['strategy']?.toString() ?? '',
            status,
          ),
        ),
        190,
      ),
      ('Ticker', Text(event['symbol']?.toString() ?? '—', style: strong), 65),
      if (event['entryPrice'] is num)
        ('Entry price', Text(price(event['entryPrice']), style: strong), 86),
      if (event['stop'] is num)
        ('Stop', Text(price(event['stop']), style: small), 86),
      if (event['target'] is num)
        ('Target', Text(price(event['target']), style: small), 86),
      if (event['price'] is num && event['price'] != event['entryPrice'])
        (
          event['kind'] == 'fill' ? 'Fill price' : 'Price',
          Text(price(event['price']), style: small),
          86,
        ),
      if (event['kind'] != null || event['positionEffect'] != null)
        (
          'Event',
          Text(
            [
              _readable(event['kind']?.toString() ?? ''),
              if (event['positionEffect'] != null) '${event['positionEffect']}',
            ].join(' · '),
            style: small,
          ),
          120,
        ),
    ];

    return Container(
      margin: const EdgeInsets.only(bottom: 3),
      decoration: BoxDecoration(
        color: theme.cardTheme.color,
        border: Border(
          left: BorderSide(color: color, width: 3),
          top: BorderSide(color: divider),
          right: BorderSide(color: divider),
          bottom: BorderSide(color: divider),
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          var usedWidth = 0.0;
          for (final (_, _, width) in cells) {
            final cellWidth = math.min(width, constraints.maxWidth);
            if (usedWidth + cellWidth > constraints.maxWidth) usedWidth = 0;
            usedWidth += cellWidth;
          }
          final remaining = constraints.maxWidth - usedWidth;
          final reasonWidth = remaining >= math.min(220, constraints.maxWidth)
              ? remaining
              : constraints.maxWidth;
          final reasonCell = (
            'Reason',
            Tooltip(
              message: details.isEmpty ? reason : '$reason\n$details',
              waitDuration: const Duration(milliseconds: 500),
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: reason),
                    if (details.isNotEmpty)
                      TextSpan(
                        text: '${reason.isEmpty ? '' : '  |  '}$details',
                        style: TextStyle(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
                style: small,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            reasonWidth,
          );
          return Wrap(
            children: [
              for (final (label, value, width) in [
                ...cells,
                if (reason.isNotEmpty || details.isNotEmpty) reasonCell,
              ])
                Container(
                  width: math.min(width, constraints.maxWidth),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    border: Border(right: BorderSide(color: divider)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: small.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      value,
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class RunSetupView extends StatefulWidget {
  const RunSetupView({
    required this.controller,
    this.embedded = false,
    super.key,
  });
  final DashboardController controller;
  final bool embedded;

  @override
  State<RunSetupView> createState() => _RunSetupViewState();
}

class _RunSetupViewState extends State<RunSetupView> {
  late final TextEditingController _watchlist;
  late final TextEditingController _cash;
  final List<String> _instances = [];
  final Map<String, String> _instanceStrategy = {};
  final Map<String, TextEditingController> _instanceLabels = {};
  final Map<String, bool> _enabled = {};
  final Map<String, int> _intervals = {};
  final Map<String, TextEditingController> _parameterValues = {};
  final Map<String, TextEditingController> _riskFields = {};
  bool _busy = false;
  bool _allowOvernight = true;
  bool _buyAndHold = true;
  bool _equalWeight = true;
  bool _enableShortSelling = false;
  bool _sessionClosePolicyEnabled = false;
  bool _historical = true;
  final _generationCount = TextEditingController(text: '2');
  final _mutationSize = TextEditingController(text: '35');
  final _mutationProbability = TextEditingController(text: '20');
  final _candidateCount = TextEditingController(text: '12');
  bool _resumeTraining = true;
  int? get _generations => int.tryParse(_generationCount.text.trim());

  EvolutionSettings _evolutionSettings() => EvolutionSettings.fromJson({
    'mutationAmount': (double.tryParse(_mutationSize.text) ?? double.nan) / 100,
    'additionalMutationProbability':
        (double.tryParse(_mutationProbability.text) ?? double.nan) / 100,
    'candidatesPerGeneration': int.tryParse(_candidateCount.text) ?? 0,
  });
  String? _loadedRunId;
  bool _configurationLoaded = false;
  DateTimeRange? _historicalRange;
  TimeOfDay? _historicalStartTime = const TimeOfDay(hour: 7, minute: 30);
  TimeOfDay? _historicalEndTime = const TimeOfDay(hour: 14, minute: 0);
  String? _error;

  bool get _hasRunData =>
      widget.controller.supportsRuns &&
      (widget.controller.status['configurationLocked'] == true ||
          _accounts(widget.controller.snapshot).isNotEmpty);

  @override
  void initState() {
    super.initState();
    final lastSession = MountainTime.lastFullTradingDate(DateTime.now());
    _historicalRange = DateTimeRange(start: lastSession, end: lastSession);
    _watchlist = TextEditingController(text: 'SOXL, OKLO, SMR');
    _cash = TextEditingController(text: '10000');
    for (final entry in const {
      'positionSizePercent': 20.0,
      'maxExposurePercent': 90.0,
      'dailyLossLimitPercent': 5.0,
      'riskPerTradePercent': 2.0,
      'defaultStopPercent': 3.0,
      'defaultTargetPercent': 0.0,
      'spreadBps': 2.0,
      'slippageBps': 3.0,
      'feePerShare': .005,
    }.entries) {
      _riskFields[entry.key] = TextEditingController(text: '${entry.value}');
    }
    for (final strategy in StrategyRegistry.all) {
      _addInstance(strategy, enabled: strategy.id != 'lm_selector');
    }
    _loadConfiguration();
  }

  @override
  void didUpdateWidget(covariant RunSetupView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller.isResearchPreview) return;
    final status = widget.controller.status;
    if (_loadedRunId != status['runId']?.toString() ||
        (!_configurationLoaded &&
            (status['configuration'] is Map ||
                status['startingCash'] is num))) {
      _loadConfiguration();
    }
  }

  void _loadConfiguration() {
    final status = widget.controller.status;
    final session = status['trainingSession'] as Map?;
    final configuration =
        session?['source'] as Map<String, dynamic>? ??
        status['configuration'] as Map<String, dynamic>? ??
        status;
    _resumeTraining = session != null;
    _generationCount.text =
        '${session?['evolutionLimit'] ?? configuration['trainingGenerations'] ?? 2}';
    final evolution = EvolutionSettings.fromJson(
      (session?['evolution'] ?? configuration['evolution'])
          as Map<String, dynamic>?,
    );
    _mutationSize.text = '${evolution.mutationAmount * 100}';
    _mutationProbability.text =
        '${evolution.additionalMutationProbability * 100}';
    _candidateCount.text = '${evolution.candidatesPerGeneration}';
    final savedRange = session ?? status['historicalRange'] as Map?;
    if (savedRange?['start'] case final String start) {
      final from = MountainTime.at(DateTime.parse(start));
      final until = MountainTime.at(
        DateTime.parse(savedRange!['end'] as String),
      );
      _historicalRange = DateTimeRange(
        start: DateTime(from.year, from.month, from.day),
        end: DateTime(until.year, until.month, until.day),
      );
      _historicalStartTime = TimeOfDay(hour: from.hour, minute: from.minute);
      _historicalEndTime = TimeOfDay(hour: until.hour, minute: until.minute);
    } else if (configuration['historicalSetup'] case final Map setup) {
      _historicalRange = DateTimeRange(
        start: DateTime.parse(setup['startDate'] as String),
        end: DateTime.parse(setup['endDate'] as String),
      );
      TimeOfDay? clock(Object? value) {
        if (value is! String) return null;
        final parts = value.split(':').map(int.parse).toList();
        return TimeOfDay(hour: parts[0], minute: parts[1]);
      }

      _historicalStartTime = clock(setup['startTime']);
      _historicalEndTime = clock(setup['endTime']);
    }
    _configurationLoaded =
        configuration['startingCash'] is num ||
        configuration['risk'] is Map ||
        configuration['strategies'] is List;
    _loadedRunId = status['runId']?.toString();
    if (configuration['watchlist'] is List) {
      _watchlist.text = (configuration['watchlist'] as List).join(', ');
    }
    if (configuration['startingCash'] is num) {
      _cash.text = '${configuration['startingCash']}';
    }
    final benchmarks = BenchmarkSettings.fromJson(
      configuration['benchmarks'] as Map<String, dynamic>?,
    );
    _buyAndHold = benchmarks.buyAndHold;
    _equalWeight = benchmarks.equalWeight;
    final risk = configuration['risk'];
    if (risk is Map) {
      const percentages = {
        'positionSizePercent': 'positionSizeFraction',
        'maxExposurePercent': 'maxExposureFraction',
        'dailyLossLimitPercent': 'dailyLossLimitFraction',
        'riskPerTradePercent': 'riskFraction',
        'defaultStopPercent': 'defaultRiskPerShareFraction',
        'defaultTargetPercent': 'defaultTargetFraction',
      };
      for (final entry in _riskFields.entries) {
        final value = risk[percentages[entry.key] ?? entry.key];
        if (value is num) {
          entry.value.text =
              '${value * (percentages.containsKey(entry.key) ? 100 : 1)}';
        }
      }
      _allowOvernight = risk['allowOvernight'] != false;
    }
    _enableShortSelling = risk is Map && risk['enableShortSelling'] == true;
    _sessionClosePolicyEnabled =
        risk is Map && risk['sessionClosePolicyEnabled'] == true;
    _historical = configuration['mode'] != 'live';
    if (status['running'] == true) {
      _historical = status['runMode'] == 'historical';
    }
    final savedStrategies = configuration['strategies'];
    if (savedStrategies is List) {
      for (final controller in [
        ..._instanceLabels.values,
        ..._parameterValues.values,
      ]) {
        controller.dispose();
      }
      _instances.clear();
      _instanceStrategy.clear();
      _instanceLabels.clear();
      _parameterValues.clear();
      _enabled.clear();
      _intervals.clear();
      for (final saved in savedStrategies.whereType<Map>()) {
        final strategy = StrategyRegistry.all
            .where((strategy) => strategy.id == saved['strategyId'])
            .firstOrNull;
        if (strategy == null) continue;
        _addInstance(strategy, enabled: saved['enabled'] != false);
        final instance = _instances.last;
        _instanceLabels[instance]!.text =
            saved['label']?.toString() ?? strategy.name;
        _intervals[instance] = (saved['intervalMinutes'] as num?)?.toInt() ?? 1;
        final parameters = saved['parameters'];
        if (parameters is Map) {
          for (final parameter in strategy.parameters) {
            if (parameters[parameter.name] is num) {
              _parameterValues['$instance:${parameter.name}']!.text =
                  '${parameters[parameter.name]}';
            }
          }
        }
      }
    }
  }

  @override
  void dispose() {
    _generationCount.dispose();
    _mutationSize.dispose();
    _mutationProbability.dispose();
    _candidateCount.dispose();
    _watchlist.dispose();
    _cash.dispose();
    for (final value in _parameterValues.values) {
      value.dispose();
    }
    for (final value in _instanceLabels.values) {
      value.dispose();
    }
    for (final value in _riskFields.values) {
      value.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final running = widget.controller.status['running'] == true;
    final feedLive = widget.controller.status['feed'] == 'live';
    final authorized = widget.controller.status['schwabAuthorized'] == true;
    final research = widget.controller.status['research'] as Map?;
    final researching = research?['running'] == true;
    final session = widget.controller.status['trainingSession'] as Map?;
    final completed = session?['cycles'] as int? ?? 0;
    final active = running || researching;
    final validGenerations =
        _generations != null &&
        _generations! >= 1 &&
        _generations! <= maxTuningGenerations &&
        (!_resumeTraining || _generations! > completed);
    final historicalStatus =
        widget.controller.status['runMode'] == 'historical';
    final range = _historicalRange;
    final canStart = _historical
        ? authorized && range != null && research != null && validGenerations
        : feedLive;
    return ListView(
      shrinkWrap: widget.embedded,
      physics: widget.embedded ? const NeverScrollableScrollPhysics() : null,
      padding: const EdgeInsets.all(12),
      children: [
        Text('Run setup', style: Theme.of(context).textTheme.headlineSmall),
        _RunManager(
          controller: widget.controller,
          configuration: _configuration,
        ),
        const SizedBox(height: 5),
        Text(
          _historical
              ? 'Historical replays Schwab 1-minute bars for the chosen dates '
                    'as fast as possible. Strategies see each minute only after '
                    'it ends, and orders fill at the next minute\'s open, so '
                    'nothing looks ahead.'
              : 'Live uses Schwab stream events as they arrive.',
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: _busy || running || !widget.controller.backendConnected
                ? null
                : _confirmReset,
            icon: const Icon(Icons.delete_outline),
            label: const Text('Clear run data'),
          ),
        ),
        if (running) const Text('Stop the run before clearing its data.'),
        const SizedBox(height: 12),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(
              value: false,
              icon: Icon(Icons.sensors),
              label: Text('Live'),
            ),
            ButtonSegment(
              value: true,
              icon: Icon(Icons.history),
              label: Text('Historical'),
            ),
          ],
          selected: {_historical},
          onSelectionChanged: running
              ? null
              : (value) => setState(() => _historical = value.first),
        ),
        if (_historical) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: running ? null : _pickHistoricalRange,
                icon: const Icon(Icons.calendar_month),
                label: Text(
                  range == null
                      ? 'Choose dates'
                      : '${MaterialLocalizations.of(context).formatMediumDate(range.start)}'
                            ' – '
                            '${MaterialLocalizations.of(context).formatMediumDate(range.end)}',
                ),
              ),
              for (final isStart in [true, false])
                InputChip(
                  avatar: const Icon(Icons.schedule, size: 16),
                  label: Text(
                    '${isStart ? 'Start' : 'End'} '
                    '${_formatMountain(isStart ? _historicalStartTime : _historicalEndTime, isStart)}',
                  ),
                  isEnabled: !running,
                  onPressed: () => _pickHistoricalTime(isStart),
                  onDeleted:
                      (isStart ? _historicalStartTime : _historicalEndTime) ==
                          null
                      ? null
                      : () => setState(() {
                          if (isStart) {
                            _historicalStartTime = null;
                          } else {
                            _historicalEndTime = null;
                          }
                        }),
                ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'Times are Mountain Time: the replay starts at the start '
            'time on the first date and stops before the end time on the last date. '
            'Schwab keeps about the last month of 1-minute history.',
          ),
          if (widget.controller.backendConnected &&
              !widget.controller.supportsMountainHistoricalReplay)
            const Text(
              'The backend must be updated before starting a Mountain-time '
              'replay. Stop any running simulations before restarting it.',
            ),
        ],
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (_historical)
              SizedBox(
                width: 160,
                child: TextFormField(
                  key: const ValueKey('setup-research-generations'),
                  controller: _generationCount,
                  enabled: !_busy && !active,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: 'Generations',
                    errorText: validGenerations
                        ? null
                        : 'Enter 1?$maxTuningGenerations',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
            FilledButton.icon(
              onPressed:
                  _busy ||
                      research?['stopping'] == true ||
                      (!active && !canStart)
                  ? null
                  : researching
                  ? () => _setResearch(false)
                  : running
                  ? _stop
                  : _historical
                  ? () => _setResearch(true)
                  : _start,
              icon: Icon(active ? Icons.stop : Icons.play_arrow),
              label: Text(active ? 'Stop' : 'Start'),
            ),
            OutlinedButton.icon(
              onPressed: _busy || active || _hasRunData ? null : _save,
              icon: const Icon(Icons.save_outlined),
              label: const Text('Save configuration'),
            ),
          ],
        ),
        if (_historical) ...[
          if (session != null)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                'Continue saved training ($completed generations completed)',
              ),
              subtitle: const Text(
                'Set Generations to the desired total. Saved dates and data will be reused.',
              ),
              value: _resumeTraining,
              onChanged: active
                  ? null
                  : (value) => setState(() => _resumeTraining = value!),
            ),
          ExpansionTile(
            title: const Text('Evolution settings'),
            maintainState: true,
            children: [
              for (final (label, field) in [
                ('Mutation size (%)', _mutationSize),
                ('Extra-variable mutation (%)', _mutationProbability),
                ('Mutation candidates per generation', _candidateCount),
              ])
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: TextField(
                    controller: field,
                    enabled: !active,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(labelText: label),
                  ),
                ),
              const Text(
                'Mutation size controls the step. Extra-variable mutation controls how often other values change. Weak candidates receive larger changes.',
              ),
            ],
          ),
        ],
        const SizedBox(height: 10),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _historical ? 'Run configuration' : 'Live run configuration',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _watchlist,
                  decoration: const InputDecoration(
                    labelText: 'Watchlist',
                    helperText:
                        'Comma-separated tickers · defaults: SOXL, OKLO, SMR',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _cash,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Starting cash per portfolio (USD)',
                    helperText:
                        'Every strategy and benchmark gets its own separate '
                        'portfolio that starts with this amount.',
                  ),
                ),
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Portfolio risk and execution',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 12,
                  runSpacing: 10,
                  children: [
                    for (final entry in const {
                      'positionSizePercent': 'Position size cap (%)',
                      'maxExposurePercent': 'Max exposure (%)',
                      'dailyLossLimitPercent': 'Daily loss limit (%)',
                      'riskPerTradePercent': 'Risk per trade (%)',
                      'defaultStopPercent': 'Fallback stop (%)',
                      'defaultTargetPercent': 'Fallback target (%)',
                      'spreadBps': 'Spread (bps)',
                      'slippageBps': 'Slippage (bps)',
                      'feePerShare': 'Fee per share (USD)',
                    }.entries)
                      SizedBox(
                        width: 190,
                        child: TextField(
                          controller: _riskFields[entry.key],
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: InputDecoration(labelText: entry.value),
                        ),
                      ),
                  ],
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _enableShortSelling,
                  title: const Text('Enable short selling'),
                  subtitle: const Text(
                    'Simulator collateral model: short proceeds are reserved; '
                    'short exposure requires available collateral. No broker orders.',
                  ),
                  onChanged: running
                      ? null
                      : (value) => setState(
                          () => _enableShortSelling = value ?? false,
                        ),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _sessionClosePolicyEnabled,
                  title: const Text('Market close rule'),
                  subtitle: const Text(
                    '10 minutes before close: stop new entries and close a strategy\'s positions if they are profitable after costs. '
                    '1 minute before close: close all remaining positions.',
                  ),
                  onChanged: running
                      ? null
                      : (value) => setState(
                          () => _sessionClosePolicyEnabled = value ?? false,
                        ),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _allowOvernight,
                  title: const Text('Allow positions to be held overnight'),
                  onChanged: (value) =>
                      setState(() => _allowOvernight = value ?? false),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 12,
                  children: [
                    const Chip(
                      label: Text('Chart intervals: 1m · 5m · 15m · 30m'),
                    ),
                    const Chip(label: Text('Orders: simulator only')),
                    Chip(
                      label: Text(
                        _historical
                            ? 'Fills: next minute open (no look-ahead)'
                            : 'Fills: next eligible quote',
                      ),
                    ),
                  ],
                ),
                const Divider(height: 28),
                Text(
                  'Benchmarks',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Buy & Hold'),
                  value: _buyAndHold,
                  onChanged: active
                      ? null
                      : (value) => setState(() => _buyAndHold = value!),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Equal Weight'),
                  value: _equalWeight,
                  onChanged: active
                      ? null
                      : (value) => setState(() => _equalWeight = value!),
                ),
                const Divider(height: 28),
                Text(
                  'Strategy instances',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const Text(
                  'Add as many independent portfolios as you want; there is no '
                  'fixed instance limit. Practical capacity depends on your '
                  'computer.',
                ),
                if (widget.controller.status['algorithmImportsSupported'] ==
                    true) ...[
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed: widget.controller.importingAlgorithm
                          ? null
                          : _importAlgorithm,
                      icon: const Icon(Icons.file_open_outlined),
                      label: const Text('Add algorithm from file'),
                    ),
                  ),
                  const Text(
                    'Choose a JSON rules file or Dart algorithm. Imported algorithms are saved and available in every simulation. Dart files require the Dart SDK on the backend computer.',
                  ),
                  if (widget.controller.importingAlgorithm) ...[
                    const SizedBox(height: 8),
                    const LinearProgressIndicator(),
                    Text(widget.controller.algorithmImportStatus),
                  ],
                  const SizedBox(height: 10),
                ],
                for (final instance in _instances)
                  _strategyTile(
                    StrategyRegistry.byId(_instanceStrategy[instance]!),
                    instance,
                  ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: PopupMenuButton<String>(
                    tooltip: 'Add another strategy instance',
                    onSelected: (strategyId) {
                      setState(() {
                        _addInstance(StrategyRegistry.byId(strategyId));
                      });
                    },
                    itemBuilder: (context) => [
                      for (final strategy in StrategyRegistry.all)
                        PopupMenuItem(
                          value: strategy.id,
                          child: Text(strategy.name),
                        ),
                    ],
                    child: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 10),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.add_circle_outline),
                          SizedBox(width: 8),
                          Text('Add strategy instance'),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                if (_hasRunData)
                  const Text(
                    'This run’s configuration is pinned to its saved data. '
                    'Create a new simulation to use different settings.',
                  ),
                if (running && historicalStatus)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: LinearProgressIndicator(
                      value:
                          (widget.controller.status['replayProgress'] as num?)
                              ?.toDouble(),
                    ),
                  ),
                Text(
                  running || historicalStatus
                      ? widget.controller.status['runStatus']?.toString() ??
                            'Running'
                      : _historical
                      ? authorized
                            ? range == null
                                  ? 'Choose a date range to replay.'
                                  : 'Ready to replay the chosen dates.'
                            : 'Connect Schwab in Settings before replaying.'
                      : feedLive
                      ? 'Schwab stream is live. Configure and start when ready.'
                      : 'Connect Schwab in Settings before starting.',
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _importAlgorithm() async {
    try {
      final strategy = await widget.controller.importAlgorithm();
      if (!mounted || strategy == null) return;
      final busy =
          widget.controller.status['running'] == true ||
          (widget.controller.status['research'] as Map?)?['running'] == true;
      final canAdd =
          !busy && !_hasRunData && !widget.controller.isResearchPreview;
      if (canAdd) setState(() => _addInstance(strategy));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            canAdd
                ? 'Imported ${strategy.name} and added it to this setup.'
                : 'Imported ${strategy.name}. Choose it under Add strategy instance when setting up a new simulation.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Algorithm could not be imported'),
          content: SizedBox(
            width: 650,
            child: SingleChildScrollView(
              child: SelectableText(error.toString()),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    }
  }

  void _addInstance(TradingStrategy strategy, {bool enabled = true}) {
    final duplicateCount = _instanceStrategy.values
        .where((id) => id == strategy.id)
        .length;
    final instance = '${strategy.id}_${DateTime.now().microsecondsSinceEpoch}';
    _instances.add(instance);
    _instanceStrategy[instance] = strategy.id;
    _instanceLabels[instance] = TextEditingController(
      text: duplicateCount == 0
          ? strategy.name
          : '${strategy.name} #${duplicateCount + 1}',
    );
    _enabled[instance] = enabled;
    _intervals[instance] = 1;
    for (final parameter in strategy.parameters) {
      _parameterValues['$instance:${parameter.name}'] = TextEditingController(
        text: '${parameter.defaultValue}',
      );
    }
  }

  Widget _strategyTile(TradingStrategy strategy, String instance) {
    final modelStrategy =
        strategy.id == 'neural_network' || strategy.id == 'logistic_regression';
    return ExpansionTile(
      key: ValueKey(instance),
      tilePadding: EdgeInsets.zero,
      leading: Checkbox(
        value: _enabled[instance],
        onChanged: (value) =>
            setState(() => _enabled[instance] = value ?? false),
      ),
      title: Row(
        children: [
          Expanded(
            child: Tooltip(
              message: strategy.description,
              child: Text(_instanceLabels[instance]!.text),
            ),
          ),
          IconButton(
            tooltip: 'About ${strategy.name}',
            icon: const Icon(Icons.info_outline),
            onPressed: () => _showStrategyInformation(
              context,
              _informationForStrategy(strategy),
              _instanceLabels[instance]!.text,
            ),
          ),
        ],
      ),
      subtitle: Text(
        '${strategy.description} · warm-up ${strategy.warmupBars} bars'
        '${modelStrategy ? ' · 1-minute model only; untrained pins stay WAIT' : ''}',
      ),
      childrenPadding: const EdgeInsets.only(bottom: 12),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Wrap(
            spacing: 12,
            runSpacing: 10,
            children: [
              SizedBox(
                width: 260,
                child: TextField(
                  controller: _instanceLabels[instance],
                  decoration: const InputDecoration(labelText: 'Chart label'),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              SizedBox(
                width: 200,
                child: DropdownButtonFormField<int>(
                  isExpanded: true,
                  initialValue: modelStrategy ? 1 : _intervals[instance],
                  decoration: const InputDecoration(
                    labelText: 'Strategy interval',
                  ),
                  items: (modelStrategy ? const [1] : const [1, 5, 15, 30])
                      .map(
                        (value) => DropdownMenuItem(
                          value: value,
                          child: Text('$value minute bars'),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value != null) {
                      setState(() => _intervals[instance] = value);
                    }
                  },
                ),
              ),
              for (final parameter in strategy.parameters)
                SizedBox(
                  width: 200,
                  child: TextField(
                    controller: _parameterValues['$instance:${parameter.name}'],
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText:
                          '${_readable(parameter.name)} (${parameter.unit})',
                      helperText:
                          '${parameter.minimum} to ${parameter.maximum}',
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Map<String, Object?> _configuration() {
    final symbols = _watchlist.text
        .split(',')
        .map((symbol) => symbol.trim().toUpperCase())
        .where((symbol) => symbol.isNotEmpty)
        .toSet()
        .toList();
    if (symbols.isEmpty ||
        symbols.any(
          (symbol) => !RegExp(r'^[A-Z][A-Z0-9.-]{0,9}$').hasMatch(symbol),
        )) {
      throw const FormatException('Enter one or more valid ticker symbols.');
    }
    final cash = double.tryParse(_cash.text);
    if (cash == null || !cash.isFinite || cash <= 0) {
      throw const FormatException(
        'Default starting cash must be a positive number.',
      );
    }
    final riskInputs = <String, double>{};
    for (final entry in _riskFields.entries) {
      final value = double.tryParse(entry.value.text);
      if (value == null || !value.isFinite || value < 0) {
        throw FormatException(
          '${_readable(entry.key)} must be a non-negative number.',
        );
      }
      riskInputs[entry.key] = value;
    }
    for (final name in const [
      'positionSizePercent',
      'maxExposurePercent',
      'dailyLossLimitPercent',
      'riskPerTradePercent',
    ]) {
      if (riskInputs[name]! <= 0 || riskInputs[name]! > 100) {
        throw FormatException('${_readable(name)} must be between 0 and 100%.');
      }
    }
    if (riskInputs['defaultStopPercent']! > 50 ||
        riskInputs['defaultTargetPercent']! > 500 ||
        riskInputs['spreadBps']! > 100 ||
        riskInputs['slippageBps']! > 100 ||
        riskInputs['feePerShare']! > 5) {
      throw const FormatException(
        'A risk or execution value is above its allowed maximum.',
      );
    }
    final strategies = <Map<String, Object?>>[];
    for (final instance in _instances) {
      final strategy = StrategyRegistry.byId(_instanceStrategy[instance]!);
      final parameters = <String, double>{};
      for (final parameter in strategy.parameters) {
        final value = double.tryParse(
          _parameterValues['$instance:${parameter.name}']!.text,
        );
        if (value == null ||
            !value.isFinite ||
            value < parameter.minimum ||
            value > parameter.maximum) {
          throw FormatException(
            '${strategy.name}: ${parameter.name} must be ${parameter.minimum}–${parameter.maximum} ${parameter.unit}.',
          );
        }
        parameters[parameter.name] = value;
      }
      strategies.add({
        'strategyId': strategy.id,
        'label': _instanceLabels[instance]!.text.trim(),
        'enabled': _enabled[instance] == true,
        'intervalMinutes':
            strategy.id == 'neural_network' ||
                strategy.id == 'logistic_regression'
            ? 1
            : _intervals[instance],
        'startingCash': cash,
        'parameters': parameters,
      });
    }
    return {
      'watchlist': symbols,
      'startingCash': cash,
      'evolution': _evolutionSettings().toJson(),
      'trainingGenerations': _generations ?? 2,
      'mode': _historical ? 'historical' : 'live',
      if (_historicalRange case final range?)
        'historicalSetup': widget.controller._historicalRequest(
          range,
          startTime: _historicalStartTime,
          endTime: _historicalEndTime,
        ),
      'benchmarks': BenchmarkSettings(
        buyAndHold: _buyAndHold,
        equalWeight: _equalWeight,
      ).toJson(),
      'risk': {
        'positionSizeFraction': riskInputs['positionSizePercent']! / 100,
        'maxExposureFraction': riskInputs['maxExposurePercent']! / 100,
        'dailyLossLimitFraction': riskInputs['dailyLossLimitPercent']! / 100,
        'riskFraction': riskInputs['riskPerTradePercent']! / 100,
        'defaultRiskPerShareFraction': riskInputs['defaultStopPercent']! / 100,
        'defaultTargetFraction': riskInputs['defaultTargetPercent']! / 100,
        'spreadBps': riskInputs['spreadBps'],
        'slippageBps': riskInputs['slippageBps'],
        'feePerShare': riskInputs['feePerShare'],
        'allowOvernight': _allowOvernight,
        'enableShortSelling': _enableShortSelling,
        'sessionClosePolicyEnabled': _sessionClosePolicyEnabled,
      },
      'strategies': strategies,
    };
  }

  Future<void> _save() async {
    try {
      setState(() {
        _busy = true;
        _error = null;
      });
      await widget.controller.saveRun(_configuration());
    } catch (error) {
      setState(() => _error = error.toString().replaceFirst('Bad state: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setResearch(bool enabled) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.controller.setAutoResearch(
        enabled,
        configuration: enabled ? _configuration() : null,
        generations: _generations ?? 2,
        evolution: _evolutionSettings(),
        resume: enabled && _resumeTraining,
        historicalRange: enabled && _historical ? _historicalRange : null,
        startTime: _historicalStartTime,
        endTime: _historicalEndTime,
      );
    } catch (error) {
      if (mounted) {
        setState(() => _error = '$error'.replaceFirst('Bad state: ', ''));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickHistoricalRange() async {
    final mountainNow = MountainTime.at(DateTime.now());
    final today = DateTime(
      mountainNow.year,
      mountainNow.month,
      mountainNow.day,
    );
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(today.year, today.month, today.day - 365),
      lastDate: today,
      initialDateRange:
          _historicalRange ??
          DateTimeRange(
            start: DateTime(today.year, today.month, today.day - 7),
            end: today,
          ),
      helpText: 'Choose dates to replay',
    );
    if (picked != null) setState(() => _historicalRange = picked);
  }

  String _formatMountain(TimeOfDay? time, bool isStart) => time == null
      ? (isStart ? 'start of day' : 'end of day')
      : '${MountainTime.formatClock(time.hour, time.minute)} MT';

  Future<void> _pickHistoricalTime(bool isStart) async {
    final picked = await showTimePicker(
      context: context,
      initialTime:
          (isStart ? _historicalStartTime : _historicalEndTime) ??
          (isStart
              ? const TimeOfDay(hour: 7, minute: 30)
              : const TimeOfDay(hour: 14, minute: 0)),
      helpText: isStart
          ? 'Replay start time (Mountain)'
          : 'Replay end time (Mountain)',
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: false),
        child: child!,
      ),
    );
    if (picked == null) return;
    setState(() {
      if (isStart) {
        _historicalStartTime = picked;
      } else {
        _historicalEndTime = picked;
      }
    });
  }

  Future<void> _start() async {
    try {
      setState(() {
        _busy = true;
        _error = null;
      });
      if (_hasRunData && widget.controller.supportsRuns) {
        final create = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Create a new simulation?'),
            content: const Text(
              'This run already contains saved data. Create a separate stopped '
              'simulation with these settings, then configure and start it. '
              'The existing run will not be changed.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('New simulation'),
              ),
            ],
          ),
        );
        if (create == true) {
          await widget.controller.createRun(_configuration());
        }
        return;
      }
      await widget.controller.startRun(_configuration());
    } catch (error) {
      setState(() => _error = error.toString().replaceFirst('Bad state: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stop() async {
    try {
      setState(() {
        _busy = true;
        _error = null;
      });
      await widget.controller.stopRun();
    } catch (error) {
      setState(() => _error = error.toString().replaceFirst('Bad state: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmReset() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear run data?'),
        content: const Text(
          'This permanently clears the current run’s simulated portfolios, '
          'positions, pending orders, candles, decisions, fills and charts. '
          'Your run configuration and Schwab credentials will be kept.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear data'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.controller.resetRun();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Run data cleared.')));
      }
    } catch (error) {
      if (mounted) {
        final message = error.toString().replaceFirst('Bad state: ', '');
        setState(() => _error = message);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// Callback URL commonly registered for this app in the Schwab developer
/// portal; the backend serves it over local HTTPS during authorization.
const defaultSchwabRedirectUri = 'https://127.0.0.1:8766/oauth/schwab/callback';

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({required this.controller, super.key});
  final DashboardController controller;

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  final _appKey = TextEditingController();
  final _appSecret = TextEditingController();
  late final _redirect = TextEditingController(
    text:
        (widget.controller.status['schwabRedirectUri'] as String?)
                ?.isNotEmpty ==
            true
        ? widget.controller.status['schwabRedirectUri'] as String
        : defaultSchwabRedirectUri,
  );
  final _redirectedUrl = TextEditingController();
  final _lmUrl = TextEditingController(text: 'http://localhost:1234');
  final _lmModel = TextEditingController();
  bool _busy = false;
  String? _message;
  String? _schwabMessage;
  bool _schwabMessageIsError = false;
  List<String> _models = [];

  @override
  void dispose() {
    _appKey.dispose();
    _appSecret.dispose();
    _redirect.dispose();
    _redirectedUrl.dispose();
    _lmUrl.dispose();
    _lmModel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) => _buildDialog(context),
  );

  Widget _buildDialog(BuildContext context) {
    final status = widget.controller.status;
    return AlertDialog(
      title: const Text('Settings'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Local backend',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                widget.controller.backendStarting
                    ? 'Starting backend...'
                    : widget.controller.backendConnected
                    ? 'Connected to ${widget.controller.api.baseUrl}'
                    : 'Not connected to ${widget.controller.api.baseUrl}',
              ),
              const SizedBox(height: 8),
              if (widget.controller.api.supportsBackendLaunch)
                FilledButton.icon(
                  onPressed:
                      _busy ||
                          widget.controller.backendStarting ||
                          widget.controller.backendConnected
                      ? null
                      : widget.controller.startBackend,
                  icon: const Icon(Icons.power_settings_new),
                  label: Text(
                    widget.controller.backendStarting
                        ? 'Starting backend...'
                        : 'Start backend',
                  ),
                ),
              const SizedBox(height: 8),
              Text(
                widget.controller.api.supportsBackendLaunch
                    ? 'The backend keeps running when this window closes. '
                          'Stop a simulation from Run setup before exiting '
                          'if you do not want trading to continue.'
                    : r'Start the backend from the Windows app or run '
                          r'dart run bin\server.dart in a separate terminal.',
              ),
              if (widget.controller.backendError.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    widget.controller.backendError,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const Divider(height: 30),
              Text(
                'Appearance',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<ThemeMode>(
                initialValue: widget.controller.themeMode,
                decoration: const InputDecoration(labelText: 'Theme'),
                items: const [
                  DropdownMenuItem(
                    value: ThemeMode.system,
                    child: Text('System'),
                  ),
                  DropdownMenuItem(
                    value: ThemeMode.light,
                    child: Text('Light'),
                  ),
                  DropdownMenuItem(value: ThemeMode.dark, child: Text('Dark')),
                ],
                onChanged: (value) {
                  if (value != null) {
                    widget.controller.setThemeMode(value);
                  }
                },
              ),
              const Divider(height: 30),
              Text(
                'Schwab market data',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 5),
              Text(
                status['schwabCredentialsSaved'] == true
                    ? 'App credentials saved in Windows DPAPI-protected backend storage.'
                    : 'Credentials are sent directly to the local backend and protected at rest with Windows DPAPI.',
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _appKey,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: 'Client ID (App Key)',
                  helperText: status['schwabCredentialsSaved'] == true
                      ? 'Saved. Leave blank to keep it, or enter a new one.'
                      : 'From your app on developer.schwab.com.',
                ),
              ),
              const SizedBox(height: 9),
              TextField(
                controller: _appSecret,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Client Secret (App Secret)',
                ),
              ),
              const SizedBox(height: 9),
              TextField(
                controller: _redirect,
                decoration: const InputDecoration(
                  labelText: 'Callback URL',
                  helperText:
                      'Must exactly match the Callback URL registered for '
                      'your Schwab app.',
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Connection: ${status['feedReason'] ?? 'Backend not connected'}',
              ),
              const SizedBox(height: 9),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton(
                    onPressed: _busy ? null : _connect,
                    child: Text(
                      _busy
                          ? 'Working...'
                          : status['schwabAuthorized'] == true
                          ? 'Connect Schwab stream'
                          : 'Connect Schwab (OAuth)',
                    ),
                  ),
                  OutlinedButton(
                    onPressed: _busy ? null : _disconnect,
                    child: const Text('Disconnect'),
                  ),
                  if (status['schwabCredentialsSaved'] == true)
                    TextButton(
                      onPressed: _busy ? null : _remove,
                      child: const Text('Remove credentials'),
                    ),
                ],
              ),
              if (_schwabMessage != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    _schwabMessage!,
                    style: _schwabMessageIsError
                        ? TextStyle(color: Theme.of(context).colorScheme.error)
                        : null,
                  ),
                )
              else if ((status['lastError'] as String?)?.isNotEmpty == true)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    'Last backend error: ${status['lastError']}',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (status['schwabCredentialsSaved'] == true &&
                  status['schwabAuthorized'] != true) ...[
                const SizedBox(height: 12),
                const Text(
                  'After you log in and approve access, Schwab sends the '
                  'browser to your callback URL. If the browser shows a '
                  'certificate warning, choose Advanced and continue. If the '
                  'page does not load, copy the full address from the '
                  'browser bar and paste it here.',
                  style: TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: _redirectedUrl,
                  decoration: const InputDecoration(
                    labelText: 'Redirected address (optional)',
                    hintText:
                        'https://127.0.0.1:8766/oauth/schwab/callback?code=...',
                  ),
                ),
                const SizedBox(height: 6),
                OutlinedButton(
                  onPressed: _busy ? null : _completeFromPastedUrl,
                  child: const Text('Finish with pasted address'),
                ),
              ],
              const Divider(height: 30),
              Text(
                'LM Studio · local inference only',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _lmUrl,
                decoration: const InputDecoration(labelText: 'Server URL'),
              ),
              const SizedBox(height: 9),
              TextField(
                controller: _lmModel,
                decoration: const InputDecoration(labelText: 'Model ID'),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: _busy ? null : _discoverModels,
                    child: const Text('Discover models'),
                  ),
                  OutlinedButton(
                    onPressed: _busy ? null : _testLm,
                    child: const Text('Test tool calling'),
                  ),
                ],
              ),
              if (_models.isNotEmpty)
                DropdownButton<String>(
                  value: _models.contains(_lmModel.text) ? _lmModel.text : null,
                  hint: const Text('Choose a discovered model'),
                  items: [
                    for (final model in _models)
                      DropdownMenuItem(value: model, child: Text(model)),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      setState(() => _lmModel.text = value);
                    }
                  },
                ),
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(_message!),
                ),
              const SizedBox(height: 10),
              const Text(
                'LM Studio requests are optional. A failed or unavailable model must produce WAIT; hard-coded strategies continue.',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }

  Future<void> _connect() async {
    setState(() {
      _busy = true;
      _schwabMessage = null;
    });
    try {
      final message = await widget.controller.connectSchwab(
        appKey: _appKey.text,
        appSecret: _appSecret.text,
        redirectUri: _redirect.text,
      );
      _appKey.clear();
      _appSecret.clear();
      _showSchwabMessage(message);
    } catch (error) {
      _showSchwabMessage(_readableError(error), isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _completeFromPastedUrl() async {
    setState(() {
      _busy = true;
      _schwabMessage = null;
    });
    try {
      final message = await widget.controller.completeSchwabAuthorization(
        _redirectedUrl.text,
      );
      _redirectedUrl.clear();
      _showSchwabMessage(message);
    } catch (error) {
      _showSchwabMessage(_readableError(error), isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showSchwabMessage(String message, {bool isError = false}) {
    if (!mounted) return;
    setState(() {
      _schwabMessage = message;
      _schwabMessageIsError = isError;
    });
  }

  static String _readableError(Object error) => error
      .toString()
      .replaceFirst('Bad state: ', '')
      .replaceFirst('Invalid argument(s): ', '');

  Future<void> _disconnect() async {
    await _runAction(widget.controller.disconnectSchwab);
  }

  Future<void> _remove() async {
    await _runAction(widget.controller.removeSchwabCredentials);
  }

  Future<void> _discoverModels() async {
    await _runAction(() async {
      _models = await widget.controller.discoverModels(
        url: _lmUrl.text,
        model: _lmModel.text,
      );
      if (_models.isEmpty) {
        _message = 'No models found at this server URL.';
      }
    });
  }

  Future<void> _testLm() async {
    await _runAction(
      () => widget.controller.testLmStudio(
        url: _lmUrl.text,
        model: _lmModel.text,
      ),
      success: 'LM Studio tool calling succeeded.',
    );
  }

  Future<void> _runAction(
    Future<void> Function() action, {
    String? success,
  }) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
      if (success != null) _message = success;
    } catch (error) {
      _message = error.toString().replaceFirst('Bad state: ', '');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// One plotted strategy or benchmark line: its label, color, and the points
/// converted to the chart's unit (dollars, percent return, or drawdown).
class _ChartSeries {
  _ChartSeries(this.label, this.color, this.points);
  final String label;
  final Color color;
  final List<_ChartPoint> points;

  /// Interpolates on the same straight segments used to paint this series.
  _ChartPoint? valueAt(DateTime time) {
    if (points.isEmpty || time.isBefore(points.first.time)) return null;
    for (var index = 1; index < points.length; index++) {
      final previous = points[index - 1];
      final next = points[index];
      if (time.isAfter(next.time)) continue;
      final duration = next.time.difference(previous.time).inMicroseconds;
      if (duration <= 0) return next;
      final progress = time.difference(previous.time).inMicroseconds / duration;
      return _ChartPoint(
        time,
        previous.value + (next.value - previous.value) * progress,
        previous.equity + (next.equity - previous.equity) * progress,
      );
    }
    return points.last;
  }
}

class _ChartPoint {
  const _ChartPoint(this.time, this.value, this.equity);
  final DateTime time;
  final double value;
  final double equity;
}

class _ChartHoverSurface extends StatefulWidget {
  const _ChartHoverSurface({
    required this.chartBuilder,
    required this.tooltipLines,
  });

  final Widget Function(Offset?) chartBuilder;
  final List<(String, Color)> Function(Size, Offset) tooltipLines;

  @override
  State<_ChartHoverSurface> createState() => _ChartHoverSurfaceState();
}

class _ChartHoverSurfaceState extends State<_ChartHoverSurface> {
  final _portal = OverlayPortalController();
  final _link = LayerLink();
  final _targetKey = GlobalKey();
  Offset? _hover;

  void _update(Offset? pointer) {
    setState(() => _hover = pointer);
    pointer == null ? _portal.hide() : _portal.show();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final size = constraints.biggest;
      final lines = _hover == null
          ? <(String, Color)>[]
          : widget.tooltipLines(size, _hover!);
      return OverlayPortal(
        overlayLocation: OverlayChildLocation.rootOverlay,
        controller: _portal,
        overlayChildBuilder: (context) {
          if (lines.isEmpty) return const SizedBox.shrink();
          final target = _targetKey.currentContext?.findRenderObject();
          if (target is! RenderBox || !target.attached) {
            return const SizedBox.shrink();
          }
          final viewport = MediaQuery.sizeOf(context);
          final origin = target.localToGlobal(Offset.zero);
          final width = math.min(390.0, viewport.width - 16);
          final maxHeight = math.max(1.0, viewport.height - 32);
          final height = math.min(lines.length * 34.0 + 16, maxHeight);
          final anchor = origin + _hover!;
          var left = anchor.dx + 12;
          if (left + width > viewport.width - 8) left = anchor.dx - width - 12;
          left = left.clamp(8.0, math.max(8.0, viewport.width - width - 8));
          final top = (anchor.dy - height / 2)
              .clamp(8.0, math.max(8.0, viewport.height - height - 8))
              .toDouble();
          return Positioned(
            left: 0,
            top: 0,
            child: CompositedTransformFollower(
              link: _link,
              showWhenUnlinked: false,
              offset: Offset(left, top) - origin,
              child: IgnorePointer(
                child: Material(
                  key: const ValueKey('chart-hover-tooltip'),
                  elevation: 8,
                  borderRadius: BorderRadius.circular(6),
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: Container(
                    width: width,
                    constraints: BoxConstraints(
                      maxHeight: viewport.height - top - 8,
                    ),
                    padding: const EdgeInsets.all(8),
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final (text, color) in lines)
                            Text(
                              text,
                              style: TextStyle(
                                color: color,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
        child: CompositedTransformTarget(
          key: _targetKey,
          link: _link,
          child: MouseRegion(
            onHover: (event) => _update(event.localPosition),
            onExit: (_) => _update(null),
            child: GestureDetector(
              onPanDown: (details) => _update(details.localPosition),
              onPanUpdate: (details) => _update(details.localPosition),
              onPanEnd: (_) => _update(null),
              onPanCancel: () => _update(null),
              child: widget.chartBuilder(_hover),
            ),
          ),
        ),
      );
    },
  );
}

String _chartTime(DateTime time, {bool includeSeconds = true}) =>
    MountainTime.format(time, includeSeconds: includeSeconds);

/// Equity, percent-return, or drawdown chart. Every account is its own
/// independent portfolio; lines share a time axis so they can be compared.
/// Hovering shows each line's value at the pointer's time.
class EquityChart extends StatefulWidget {
  const EquityChart({
    required this.accounts,
    this.percent = false,
    this.drawdown = false,
    this.showStartingCash = false,
    this.byGeneration = false,
    this.showTrialEquity = false,
    this.hiddenLabels = const {},
    this.colorsByLabel = const {},
    super.key,
  });

  final List<Map<String, dynamic>> accounts;
  final bool percent;
  final bool drawdown;
  final bool showStartingCash;
  final bool byGeneration;
  final bool showTrialEquity;
  final Set<String> hiddenLabels;
  final Map<String, Color> colorsByLabel;

  @override
  State<EquityChart> createState() => _EquityChartState();
}

class _EquityChartState extends State<EquityChart> {
  List<_ChartSeries> _series() {
    final result = <_ChartSeries>[];
    final colors = {
      ..._portfolioColors(widget.accounts),
      ...widget.colorsByLabel,
    };
    for (var index = 0; index < widget.accounts.length; index++) {
      final account = widget.accounts[index];
      if (widget.hiddenLabels.contains(account['label']?.toString())) continue;
      final start = (account['startingCash'] as num?)?.toDouble() ?? 0;
      final marksByTime = <int, (DateTime, double)>{};
      for (final item
          in (account['history'] as List<dynamic>? ?? [])
              .whereType<Map<String, dynamic>>()) {
        final generation = item['generation'];
        final time = widget.byGeneration
            ? generation is int
                  ? DateTime.fromMillisecondsSinceEpoch(
                      generation * 1000,
                      isUtc: true,
                    )
                  : null
            : DateTime.tryParse(item['time']?.toString() ?? '');
        final value =
            ((widget.showTrialEquity ? item['trialValue'] : null) as num? ??
                    item['value'] as num?)
                ?.toDouble();
        if (time != null && value != null) {
          marksByTime[time.toUtc().microsecondsSinceEpoch] = (time, value);
        }
      }
      final raw = marksByTime.values.toList();
      raw.sort((a, b) => a.$1.compareTo(b.$1));
      var peak = start;
      final points = <_ChartPoint>[];
      for (final (time, value) in raw) {
        peak = value > peak ? value : peak;
        final converted = widget.drawdown
            ? (peak > 0 ? (value - peak) / peak * 100 : 0.0)
            : widget.percent
            ? (start > 0 ? (value - start) / start * 100 : 0.0)
            : value;
        points.add(_ChartPoint(time, converted, value));
      }
      if (points.isNotEmpty) {
        result.add(
          _ChartSeries(
            account['label'].toString(),
            colors['${account['label']}']!,
            points,
          ),
        );
      }
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final series = _series();
    if (series.isEmpty) {
      return _EmptyChart(
        text:
            widget.accounts.isNotEmpty &&
                widget.accounts.every(
                  (account) => widget.hiddenLabels.contains(
                    account['label']?.toString(),
                  ),
                )
            ? 'All portfolio lines are hidden. Select a legend item to show a line.'
            : 'Equity lines appear as live portfolio marks are recorded.',
      );
    }
    final scheme = Theme.of(context).colorScheme;
    _EquityPainter painter(Offset? hover) => _EquityPainter(
      series: series,
      percent: widget.percent,
      drawdown: widget.drawdown,
      byGeneration: widget.byGeneration,
      hover: hover,
      color: scheme.onSurface,
      gridColor: scheme.outlineVariant,
      startingCashLevels: widget.showStartingCash && !widget.drawdown
          ? {
              for (final account in widget.accounts)
                if (!widget.hiddenLabels.contains(account['label']) &&
                    account['startingCash'] is num)
                  widget.percent
                      ? 0.0
                      : (account['startingCash'] as num).toDouble(),
            }.toList()
          : const [],
    );
    return _ChartHoverSurface(
      tooltipLines: (size, pointer) =>
          painter(pointer).tooltipLines(size, pointer),
      chartBuilder: (hover) =>
          CustomPaint(painter: painter(hover), child: const SizedBox.expand()),
    );
  }
}

class _EquityPainter extends CustomPainter {
  _EquityPainter({
    required this.series,
    required this.percent,
    required this.drawdown,
    required this.byGeneration,
    required this.hover,
    required this.color,
    required this.gridColor,
    this.startingCashLevels = const [],
  });

  final List<_ChartSeries> series;
  final bool percent;
  final bool drawdown;
  final bool byGeneration;
  final Offset? hover;
  final Color color;
  final Color gridColor;
  final List<double> startingCashLevels;

  static const colors = [
    Color(0xff3d80c6),
    Color(0xff19a579),
    Color(0xffe7a63c),
    Color(0xff9563c8),
    Color(0xffe5655f),
    Color(0xff5d9caa),
    Color(0xffb95784),
    Color(0xff8a9d3e),
  ];

  String _format(double value) =>
      drawdown || percent ? '${value.toStringAsFixed(2)}%' : _money(value);

  String _axisLabel(DateTime point, {bool includeSeconds = false}) =>
      byGeneration
      ? 'Generation ${point.millisecondsSinceEpoch ~/ 1000}'
      : _chartTime(point, includeSeconds: includeSeconds);

  DateTime _pointAtX(Rect rect, double pointerX, DateTime start, int spanMs) {
    final x = pointerX.clamp(rect.left, rect.right);
    final offset = (x - rect.left) / rect.width * spanMs;
    return start.add(
      Duration(
        milliseconds: byGeneration
            ? (offset / 1000).round() * 1000
            : offset.round(),
      ),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(56, 8, size.width - 68, size.height - 30);
    final grid = Paint()
      ..color = gridColor.withValues(alpha: .4)
      ..strokeWidth = 1;
    for (var index = 0; index <= 4; index++) {
      final y = rect.top + rect.height * index / 4;
      canvas.drawLine(Offset(rect.left, y), Offset(rect.right, y), grid);
    }
    final all = series.expand((line) => line.points).toList();
    var minimum = all.map((p) => p.value).reduce(math.min);
    var maximum = all.map((p) => p.value).reduce(math.max);
    for (final level in startingCashLevels) {
      minimum = math.min(minimum, level);
      maximum = math.max(maximum, level);
    }
    if (drawdown) maximum = 0;
    if (minimum == maximum) {
      minimum -= 1;
      maximum += 1;
    }
    final firstTime = all
        .map((p) => p.time)
        .reduce((a, b) => a.isBefore(b) ? a : b);
    final lastTime = all
        .map((p) => p.time)
        .reduce((a, b) => a.isAfter(b) ? a : b);
    final spanMs = math.max(1, lastTime.difference(firstTime).inMilliseconds);
    double xOf(DateTime time) =>
        rect.left +
        rect.width * time.difference(firstTime).inMilliseconds / spanMs;
    double yOf(double value) =>
        rect.bottom - (value - minimum) / (maximum - minimum) * rect.height;

    final referencePaint = Paint()
      ..color = color.withValues(alpha: .65)
      ..strokeWidth = 1.2;
    for (final level in startingCashLevels) {
      final y = yOf(level);
      for (var x = rect.left; x < rect.right; x += 8) {
        canvas.drawLine(
          Offset(x, y),
          Offset(math.min(x + 3, rect.right), y),
          referencePaint,
        );
      }
      _drawLabel(
        canvas,
        'Starting cash ${_format(level)}',
        Offset(rect.left + 4, y - 14),
      );
    }

    for (final line in series) {
      final path = Path();
      for (var point = 0; point < line.points.length; point++) {
        final offset = Offset(
          xOf(line.points[point].time),
          yOf(line.points[point].value),
        );
        point == 0
            ? path.moveTo(offset.dx, offset.dy)
            : path.lineTo(offset.dx, offset.dy);
      }
      final paint = Paint()
        ..color = line.color
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round;
      if (line.points.length == 1) {
        canvas.drawCircle(
          Offset(xOf(line.points.first.time), yOf(line.points.first.value)),
          3,
          paint..style = PaintingStyle.fill,
        );
      } else {
        canvas.drawPath(path, paint);
        if (byGeneration) {
          paint.style = PaintingStyle.fill;
          for (final point in line.points) {
            canvas.drawCircle(
              Offset(xOf(point.time), yOf(point.value)),
              3,
              paint,
            );
          }
        }
      }
    }
    _drawLabel(
      canvas,
      drawdown ? '${minimum.toStringAsFixed(1)}%' : _format(minimum),
      Offset(0, rect.bottom - 8),
    );
    _drawLabel(
      canvas,
      drawdown ? '0.0%' : _format(maximum),
      Offset(0, rect.top - 5),
    );
    final startLabel = _textPainter(
      _axisLabel(firstTime),
      10,
      color.withValues(alpha: .7),
    );
    final endLabel = _textPainter(
      _axisLabel(lastTime),
      10,
      color.withValues(alpha: .7),
    );
    startLabel.paint(canvas, Offset(rect.left, rect.bottom + 6));
    if (lastTime != firstTime &&
        startLabel.width + endLabel.width + 8 <= rect.width) {
      endLabel.paint(
        canvas,
        Offset(rect.right - endLabel.width, rect.bottom + 6),
      );
    }

    final pointer = hover;
    if (pointer == null || !rect.inflate(6).contains(pointer)) return;
    final time = _pointAtX(rect, pointer.dx, firstTime, spanMs);
    final x = xOf(time);
    canvas.drawLine(
      Offset(x, rect.top),
      Offset(x, rect.bottom),
      Paint()
        ..color = color.withValues(alpha: .45)
        ..strokeWidth = 1,
    );
    for (final line in series) {
      final point = line.valueAt(time);
      if (point == null) continue;
      canvas.drawCircle(
        Offset(x, yOf(point.value)),
        4,
        Paint()..color = line.color,
      );
    }
  }

  List<(String, Color)> tooltipLines(Size size, Offset pointer) {
    final rect = Rect.fromLTWH(56, 8, size.width - 68, size.height - 30);
    if (!rect.inflate(6).contains(pointer)) return [];
    final all = series.expand((line) => line.points);
    final firstTime = all
        .map((point) => point.time)
        .reduce((a, b) => a.isBefore(b) ? a : b);
    final lastTime = all
        .map((point) => point.time)
        .reduce((a, b) => a.isAfter(b) ? a : b);
    final spanMs = math.max(1, lastTime.difference(firstTime).inMilliseconds);
    final time = _pointAtX(rect, pointer.dx, firstTime, spanMs);
    final rows = [
      for (final line in series)
        if (line.valueAt(time) case final _ChartPoint point) (line, point),
    ]..sort((a, b) => b.$2.value.compareTo(a.$2.value));
    return [
      (_axisLabel(time, includeSeconds: true), color),
      for (final level in startingCashLevels)
        ('Starting cash: ${_format(level)}', color.withValues(alpha: .7)),
      for (final (line, point) in rows)
        (
          '${line.label}: ${_format(point.value)}'
              '${percent || drawdown ? '  (${_money(point.equity)})' : ''}',
          line.color,
        ),
    ];
  }

  TextPainter _textPainter(
    String text,
    double fontSize,
    Color textColor, {
    bool bold = false,
  }) => TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        color: textColor,
        fontSize: fontSize,
        fontWeight: bold ? FontWeight.w600 : FontWeight.normal,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();

  void _drawLabel(Canvas canvas, String text, Offset offset) {
    _textPainter(text, 10, color.withValues(alpha: .7)).paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant _EquityPainter oldDelegate) => true;
}

/// Live candle chart with fill markers. Hovering shows the candle's OHLCV
/// values plus any order/fill markers on that bar.
class CandleChart extends StatefulWidget {
  const CandleChart({required this.rows, required this.events, super.key});
  final List<dynamic> rows;
  final List<Map<String, dynamic>> events;

  @override
  State<CandleChart> createState() => _CandleChartState();
}

class _CandleChartState extends State<CandleChart> {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    _CandlePainter painter(Offset? hover) => _CandlePainter(
      rows: widget.rows,
      events: widget.events,
      hover: hover,
      up: const Color(0xff16844a),
      down: const Color(0xffcf4b45),
      grid: scheme.outlineVariant,
      text: scheme.onSurface,
    );
    return _ChartHoverSurface(
      tooltipLines: (size, pointer) =>
          painter(pointer).tooltipLines(size, pointer),
      chartBuilder: (hover) =>
          CustomPaint(painter: painter(hover), child: const SizedBox.expand()),
    );
  }
}

class _CandlePainter extends CustomPainter {
  _CandlePainter({
    required this.rows,
    required this.events,
    required this.hover,
    required this.up,
    required this.down,
    required this.grid,
    required this.text,
  });
  final List<dynamic> rows;
  final List<Map<String, dynamic>> events;
  final Offset? hover;
  final Color up;
  final Color down;
  final Color grid;
  final Color text;

  /// Index of the first bar whose close time is after [time], i.e. the bar
  /// during which the event happened.
  int _barIndexFor(List<Map<String, dynamic>> bars, DateTime time) =>
      bars.indexWhere(
        (bar) =>
            DateTime.tryParse(bar['time'].toString())?.isAfter(time) ?? false,
      );

  @override
  void paint(Canvas canvas, Size size) {
    if (rows.isEmpty) return;
    final bars = rows.cast<Map<String, dynamic>>();
    final highs = bars.map((bar) => (bar['high'] as num).toDouble()).toList();
    final lows = bars.map((bar) => (bar['low'] as num).toDouble()).toList();
    final maxPrice = highs.reduce((a, b) => a > b ? a : b);
    final minPrice = lows.reduce((a, b) => a < b ? a : b);
    final span = (maxPrice - minPrice).abs() < .000001
        ? 1
        : maxPrice - minPrice;
    double y(double value) => (maxPrice - value) / span * size.height;
    for (var i = 0; i <= 4; i++) {
      final gridY = size.height * i / 4;
      canvas.drawLine(
        Offset(0, gridY),
        Offset(size.width, gridY),
        Paint()..color = grid.withValues(alpha: .4),
      );
    }
    final slot = size.width / bars.length;
    final candleWidth = slot * .55;
    for (var index = 0; index < bars.length; index++) {
      final bar = bars[index];
      final x = (index + .5) * slot;
      final open = (bar['open'] as num).toDouble();
      final close = (bar['close'] as num).toDouble();
      final positive = close >= open;
      final paint = Paint()
        ..color = positive ? up : down
        ..strokeWidth = 1.2;
      canvas.drawLine(
        Offset(x, y((bar['high'] as num).toDouble())),
        Offset(x, y((bar['low'] as num).toDouble())),
        paint,
      );
      final top = y(positive ? close : open);
      final bottom = y(positive ? open : close);
      canvas.drawRect(
        Rect.fromLTRB(
          x - candleWidth / 2,
          top,
          x + candleWidth / 2,
          bottom == top ? bottom + 1 : bottom,
        ),
        paint..style = PaintingStyle.fill,
      );
    }
    for (final event in events) {
      final price = (event['price'] as num?)?.toDouble();
      final time = DateTime.tryParse(event['time']?.toString() ?? '');
      if (price == null || time == null) continue;
      final nearest = _barIndexFor(bars, time);
      if (nearest < 0) continue;
      final color = event['action'] == 'buy' ? up : down;
      canvas.drawCircle(
        Offset((nearest + .5) * slot, y(price)),
        5,
        Paint()..color = color,
      );
    }

    final pointer = hover;
    if (pointer == null) return;
    final index = (pointer.dx / slot).floor().clamp(0, bars.length - 1);
    final x = (index + .5) * slot;
    canvas.drawLine(
      Offset(x, 0),
      Offset(x, size.height),
      Paint()..color = text.withValues(alpha: .35),
    );
    canvas.drawLine(
      Offset(0, pointer.dy),
      Offset(size.width, pointer.dy),
      Paint()..color = text.withValues(alpha: .2),
    );
  }

  List<(String, Color)> tooltipLines(Size size, Offset pointer) {
    if (rows.isEmpty) return [];
    final bars = rows.cast<Map<String, dynamic>>();
    final maxPrice = bars
        .map((bar) => (bar['high'] as num).toDouble())
        .reduce(math.max);
    final minPrice = bars
        .map((bar) => (bar['low'] as num).toDouble())
        .reduce(math.min);
    final span = (maxPrice - minPrice).abs() < .000001
        ? 1
        : maxPrice - minPrice;
    final index = (pointer.dx / (size.width / bars.length)).floor().clamp(
      0,
      bars.length - 1,
    );
    final bar = bars[index];
    String price(String key) => (bar[key] as num?)?.toStringAsFixed(2) ?? '?';
    final time = DateTime.tryParse(bar['time']?.toString() ?? '');
    return [
      (time == null ? 'Candle' : 'Close ${_chartTime(time)}', text),
      ('Open ${price('open')}   High ${price('high')}', text),
      ('Low ${price('low')}   Close ${price('close')}', text),
      ('Volume ${(bar['volume'] as num?)?.round() ?? '?'}', text),
      (
        'Cursor price ${(maxPrice - pointer.dy / size.height * span).toStringAsFixed(2)}',
        text.withValues(alpha: .7),
      ),
      for (final event in events.where((event) {
        final time = DateTime.tryParse(event['time']?.toString() ?? '');
        return event['price'] is num &&
            time != null &&
            _barIndexFor(bars, time) == index;
      }))
        (
          '${event['action'].toString().toUpperCase()} ${event['kind'] ?? ''} ${(event['measurements'] as Map?)?['quantity'] ?? ''} @ '
              '${(event['price'] as num).toStringAsFixed(2)}'
              '${event['strategy'] != null ? ' ? ${event['strategy']}' : ''}',
          event['action'] == 'buy' ? up : down,
        ),
    ];
  }

  @override
  bool shouldRepaint(covariant _CandlePainter oldDelegate) => true;
}

Map<String, Color> _portfolioColors(List<Map<String, dynamic>> accounts) {
  final colors = <String, Color>{};
  final used = <int>{};
  var generatedIndex = 0;
  for (final account in accounts) {
    final label = '${account['label']}';
    if (colors.containsKey(label)) continue;
    Color color;
    if (colors.length < _EquityPainter.colors.length) {
      color = _EquityPainter.colors[colors.length];
    } else {
      do {
        final index = generatedIndex++;
        color = HSLColor.fromAHSL(
          1,
          (index * 137.507764 + 23) % 360,
          .72,
          .40 + (index % 3) * .11,
        ).toColor();
      } while (used.contains(color.toARGB32()));
    }
    colors[label] = color;
    used.add(color.toARGB32());
  }
  return colors;
}

class _Legend extends StatelessWidget {
  const _Legend({
    required this.accounts,
    required this.status,
    required this.hiddenLabels,
    required this.onToggle,
  });

  final List<Map<String, dynamic>> accounts;
  final Map<String, dynamic> status;
  final Set<String> hiddenLabels;
  final ValueChanged<String> onToggle;

  @override
  Widget build(BuildContext context) {
    final colors = _portfolioColors(accounts);
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (var index = 0; index < accounts.length; index++)
          _item(
            context,
            accounts[index]['label'].toString(),
            colors['${accounts[index]['label']}']!,
          ),
      ],
    );
  }

  Widget _item(BuildContext context, String label, Color lineColor) {
    final information = _portfolioInformation(label, status);
    final visible = !hiddenLabels.contains(label);
    return Tooltip(
      message: information == null
          ? '$label\nClick to toggle this line in both charts.'
          : '${information.name}\n${information.description}\n'
                'Click to toggle this line in both charts.',
      waitDuration: const Duration(milliseconds: 400),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: math.min(360, MediaQuery.sizeOf(context).width - 72),
        ),
        child: FilterChip(
          selected: visible,
          showCheckmark: false,
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          padding: EdgeInsets.zero,
          labelPadding: const EdgeInsets.symmetric(horizontal: 5),
          selectedColor: lineColor,
          backgroundColor: Theme.of(context).colorScheme.surface,
          side: BorderSide(color: lineColor, width: visible ? 1 : 2),
          labelStyle: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: visible
                ? (ThemeData.estimateBrightnessForColor(lineColor) ==
                          Brightness.dark
                      ? Colors.white
                      : Colors.black)
                : Theme.of(context).colorScheme.onSurface,
            decoration: visible ? null : TextDecoration.lineThrough,
          ),
          label: Text(label, overflow: TextOverflow.ellipsis),
          onSelected: (_) => onToggle(label),
        ),
      ),
    );
  }
}

typedef _StrategyInformation = ({
  String name,
  String description,
  int? warmupBars,
});

_StrategyInformation _informationForStrategy(TradingStrategy strategy) => (
  name: strategy.name,
  description: strategy.description,
  warmupBars: strategy.warmupBars,
);

_StrategyInformation? _informationForStrategyId(Object? id) {
  final strategy = StrategyRegistry.all
      .where((strategy) => strategy.id == id)
      .firstOrNull;
  return strategy == null ? null : _informationForStrategy(strategy);
}

_StrategyInformation? _portfolioInformation(
  String label,
  Map<String, dynamic> status,
) {
  if (label == 'Buy & Hold') {
    return (
      name: label,
      description:
          'Use the available cash to buy the first eligible watchlist symbol '
          'and hold it. Simulated execution costs still apply.',
      warmupBars: null,
    );
  }
  if (label == 'Equal Weight') {
    return (
      name: label,
      description:
          'Make approximately equal initial allocations to eligible watchlist '
          'symbols and hold them. Unspent money stays in cash.',
      warmupBars: null,
    );
  }
  final matches = (status['strategies'] as List<dynamic>? ?? [])
      .whereType<Map<String, dynamic>>()
      .where((strategy) => strategy['label'] == label)
      .toList();
  if (matches.length != 1) return null;
  return _informationForStrategyId(matches.single['strategyId']);
}

void _showStrategyInformation(
  BuildContext context,
  _StrategyInformation info,
  String portfolioLabel,
) {
  showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(info.name),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (portfolioLabel != info.name) ...[
              Text('Portfolio: $portfolioLabel'),
              const SizedBox(height: 12),
            ],
            Text(info.description),
            if (info.warmupBars != null) ...[
              const SizedBox(height: 12),
              Text('Minimum warm-up: ${info.warmupBars} bars.'),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

class _StrategyLabel extends StatelessWidget {
  const _StrategyLabel({
    required this.label,
    required this.info,
    this.portfolioLabel,
    this.style,
  });

  final String label;
  final _StrategyInformation? info;
  final String? portfolioLabel;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final information = info;
    if (information == null) return Text(label, style: style);
    return Tooltip(
      message: '${information.name}\n${information.description}',
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        mouseCursor: SystemMouseCursors.click,
        onTap: () => _showStrategyInformation(
          context,
          information,
          portfolioLabel ?? label,
        ),
        child: Text(
          label,
          style: (style ?? DefaultTextStyle.of(context).style).copyWith(
            decoration: TextDecoration.underline,
            decorationStyle: TextDecorationStyle.dotted,
          ),
        ),
      ),
    );
  }
}

class _EmptyChart extends StatelessWidget {
  const _EmptyChart({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.show_chart,
          size: 40,
          color: Theme.of(context).colorScheme.outline,
        ),
        const SizedBox(height: 8),
        Text(text, textAlign: TextAlign.center),
      ],
    ),
  );
}

class _FeedPill extends StatelessWidget {
  const _FeedPill({required this.status});
  final Map<String, dynamic> status;

  @override
  Widget build(BuildContext context) {
    final feed = status['feed']?.toString() ?? 'disconnected';
    final color = feed == 'live'
        ? const Color(0xff16844a)
        : Colors.orange.shade800;
    return Tooltip(
      message:
          status['feedReason']?.toString() ?? 'Waiting for the local backend',
      child: Chip(
        avatar: Icon(
          feed == 'live' ? Icons.circle : Icons.sync,
          size: 13,
          color: color,
        ),
        label: Text(feed == 'live' ? 'Schwab live' : _readable(feed)),
        side: BorderSide.none,
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

class _ModePill extends StatelessWidget {
  const _ModePill({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: const Color(0xff16844a).withValues(alpha: .12),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      label,
      style: const TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w700,
        color: Color(0xff16844a),
      ),
    ),
  );
}

class _BackendNotice extends StatelessWidget {
  const _BackendNotice({
    required this.message,
    required this.onRetry,
    this.onStart,
    this.starting = false,
  });
  final String message;
  final VoidCallback? onRetry;
  final VoidCallback? onStart;
  final bool starting;

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.errorContainer,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          const Icon(Icons.info_outline),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  starting
                      ? 'Starting local backend...'
                      : 'Local backend unavailable: $message',
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    if (onStart != null)
                      TextButton.icon(
                        onPressed: starting ? null : onStart,
                        icon: starting
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.power_settings_new),
                        label: Text(
                          starting ? 'Starting backend...' : 'Start backend',
                        ),
                      ),
                    TextButton(onPressed: onRetry, child: const Text('Retry')),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

List<Map<String, dynamic>> _accounts(Map<String, dynamic> snapshot) =>
    (snapshot['accounts'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .toList();

String _money(double value) => '\$${value.abs().toStringAsFixed(2)}'
    .replaceFirst('\$', value < 0 ? '-\$' : '\$');

String _formatTime(DateTime? time) =>
    time == null ? '—' : MountainTime.format(time);

Color _signedValueColor(BuildContext context, num value) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  if (value > 0) {
    return dark ? const Color(0xff4ade80) : const Color(0xff15803d);
  }
  if (value < 0) {
    return dark ? const Color(0xfff87171) : const Color(0xffc2413b);
  }
  return dark ? const Color(0xfffacc15) : const Color(0xffa66c00);
}

String _trainingValue(Object? value, String key) {
  if (value == null) return '—';
  if (value is Map) {
    return '{${value.entries.map((entry) => '${entry.key}: ${_trainingValue(entry.value, '${entry.key}')}').join(', ')}}';
  }
  if (value is List) {
    return '[${value.map((item) => _trainingValue(item, key)).join(', ')}]';
  }
  if (value is String && (key.endsWith('At') || key.endsWith('Time'))) {
    final time = DateTime.tryParse(value);
    if (time != null) return MountainTime.format(time);
  }
  return value.toString();
}

String _readable(String value) => value
    .replaceAllMapped(
      RegExp(r'([a-z])([A-Z])'),
      (match) => '${match[1]} ${match[2]}',
    )
    .replaceAll('_', ' ')
    .split(' ')
    .map(
      (word) =>
          word.isEmpty ? word : '${word[0].toUpperCase()}${word.substring(1)}',
    )
    .join(' ');

String _measurements(Map<String, dynamic> values) => values.entries
    .take(3)
    .map((entry) => '${_readable(entry.key)} ${entry.value}')
    .join(' · ');
