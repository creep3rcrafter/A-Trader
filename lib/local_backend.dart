/// Standalone local HTTP service. It owns OAuth secrets, Schwab streaming, and
/// simulation state so the backend continues after the Flutter window closes.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'auto_research.dart';
import 'run_data_export.dart';
import 'exchange_calendar.dart';
import 'historical_replay.dart';
import 'lm_studio.dart';
import 'live_runtime.dart';
import 'live_training.dart';
import 'mountain_time.dart';
import 'oauth_callback_server.dart';
import 'schwab_api.dart';
import 'secure_storage.dart';
import 'simulator.dart';
import 'strategy_tuning.dart';
import 'algorithms/algorithm_library.dart';
import 'checkpoint_archives.dart';
import 'candle_history_cache.dart';

typedef SchwabApiFactory =
    SchwabApi Function(
      SecureStorage storage,
      void Function(LiveQuote quote) onQuote,
      void Function(FeedState state, String reason) onState,
    );

/// Top-level so the isolate closure never captures backend sockets or timers.
Future<List<Map<String, Object?>>> _tuneInIsolate(
  StrategyTuner tuner,
  SendPort progress,
  List<Map<String, dynamic>> algorithms,
) => Isolate.run(() async {
  final library = AlgorithmLibrary(Directory.systemTemp);
  await library.restore(algorithms);
  try {
    return [
      for (final result in tuner.run(onProgress: progress.send))
        result.toJson(),
    ];
  } finally {
    await library.close();
  }
});

class LocalBackend {
  LocalBackend({
    SecureStorage? secureStorage,
    this.dataDirectory,
    this.schwabApiFactory,
    this.researchCycleDelay = Duration.zero,
    this.autoCollectCandles = false,
    this.requestShutdown,
    DateTime Function()? clock,
    DateTime Function()? historyClock,
  }) : _storage = secureStorage ?? SecureStorage(),
       _clock = clock ?? DateTime.now,
       _historyClock = historyClock ?? DateTime.now;

  static const defaultWatchlist = ['SOXL', 'OKLO', 'SMR'];

  /// Matches the callback commonly registered in the Schwab developer portal.
  static const defaultRedirectUri =
      'https://127.0.0.1:8766/oauth/schwab/callback';
  final SecureStorage _storage;
  final SchwabApiFactory? schwabApiFactory;
  final Duration researchCycleDelay;
  final bool autoCollectCandles;
  final void Function()? requestShutdown;
  final DateTime Function() _clock;
  final DateTime Function() _historyClock;
  final Directory? dataDirectory;
  late final _algorithms = AlgorithmLibrary(
    Directory('${_dataRoot.path}/algorithms'),
  );
  late final _checkpointArchives = CheckpointArchives(
    Directory('${_dataRoot.path}/state-archives'),
  );
  late final _historyCache = CandleHistoryCache(
    directory: Directory('${_dataRoot.path}/candles/1m'),
    // Download freshness uses wall time; a replay's simulated clock must not
    // discard historical candles that have not yet been replayed.
    clock: _historyClock,
    download: ({required symbol, required startUtc, required endUtc}) async {
      if (!_authorized) {
        throw StateError(
          'Connect Schwab in Settings to download missing candle days. Saved days can be replayed offline.',
        );
      }
      return _schwab!.fetchMinuteBars(
        symbol: symbol,
        startUtc: startUtc,
        endUtc: endUtc,
      );
    },
  );
  static Map<String, Object?> _defaultSettings() => {
    'watchlist': defaultWatchlist,
    'startingCash': 10000.0,
    'benchmarks': const BenchmarkSettings().toJson(),
    'evolution': const EvolutionSettings().toJson(),
    'trainingGenerations': 2,
    'mode': 'historical',
    'risk': {
      'positionSizeFraction': .2,
      'maxExposureFraction': .9,
      'dailyLossLimitFraction': .05,
      'riskFraction': .02,
      'defaultRiskPerShareFraction': .03,
      'defaultTargetFraction': 0.0,
      'spreadBps': 2.0,
      'slippageBps': 3.0,
      'feePerShare': .005,
      'allowOvernight': true,
      'enableShortSelling': false,
      'sessionClosePolicyEnabled': false,
    },
    'strategies': [
      for (final strategy in StrategyRegistry.all)
        {
          'strategyId': strategy.id,
          'label': strategy.name,
          'intervalMinutes': 1,
          'enabled': !const {
            'lm_selector',
            'neural_network',
            'logistic_regression',
          }.contains(strategy.id),
          'parameters': {
            for (final parameter in strategy.parameters)
              parameter.name: parameter.defaultValue,
          },
        },
    ],
  };
  final Map<String, String> _lmSettings = {
    'url': 'http://localhost:1234',
    'model': '',
  };
  final Map<String, _BackendRun> _runs = {};
  String _selectedRunId = 'run-1';
  static const _researchPreviewId = 'research-preview';
  _BackendRun? _researchPreview;
  final List<Object> _generationExports = [];
  String? _researchSourceId;
  bool _viewingResearchPreview = false;
  String? _followResearchSourceId;
  int _nextRunNumber = 2;
  _BackendRun get _selectedRun =>
      _viewingResearchPreview ? _researchPreview! : _selectedSavedRun;
  _BackendRun get _selectedSavedRun => _runs.putIfAbsent(
    _selectedRunId,
    () => _BackendRun(
      id: _selectedRunId,
      name: 'Simulation 1',
      settings: _defaultSettings(),
    ),
  );
  Map<String, Object?> get _settings => _selectedRun.settings;
  LiveSimulationRuntime? get _runtime => _selectedRun.runtime;
  set _runtime(LiveSimulationRuntime? value) => _selectedRun.runtime = value;
  set _replay(HistoricalReplay? value) => _selectedRun.replay = value;
  bool get _historicalMode => _selectedRun.historicalMode;
  set _historicalMode(bool value) => _selectedRun.historicalMode = value;
  bool get _resumeOnConnection => _selectedRun.resumeOnConnection;
  set _resumeOnConnection(bool value) =>
      _selectedRun.resumeOnConnection = value;
  Map<String, dynamic> get _savedEngineCheckpoints =>
      _selectedRun.savedEngineCheckpoints;

  HttpServer? _server;
  SchwabApi? _schwab;
  late final _research = AutoResearch(
    fetch: ({required symbol, required startUtc, required endUtc}) =>
        _historyCache.fetch(symbol: symbol, startUtc: startUtc, endUtc: endUtc),
    clock: _clock,
    cycleDelay: researchCycleDelay,
    onPreview: _publishResearchPreview,
    onCheckpoint: _saveResearchSession,
    algorithmDefinitions: () => List.of(_algorithms.definitions),
  );
  FeedState _feedState = FeedState.disconnected;
  String _feedReason = 'Connect Schwab in Settings to begin.';
  String? _lastError;
  Timer? _persistenceTimer;
  Timer? _freshnessTimer;
  Timer? _candleCollectionTimer;
  bool _collectingCandles = false;
  Future<bool>? _pendingPersistence;
  bool _persistenceRequested = false;
  bool _credentialsConfigured = false;
  bool _authorized = false;
  bool _persistenceBlocked = false;
  bool _importingAlgorithm = false;
  String? _legacyCheckpoint;
  LiveModelTraining _training = LiveModelTraining(autoTraining: false);
  final Map<String, SessionCandleBuilder> _trainingBuilders = {};
  int _port = 8787;
  String _redirectUri = '';
  String _oauthMessage = '';
  OAuthCallbackServer? _callbackServer;
  bool _shuttingDown = false;
  bool _ready = false;

  Future<void> start({int port = 8787}) async {
    if (_server != null) return;
    _shuttingDown = false;
    _port = port;
    // Claim the port before loading state so multiple frontends wait for the
    // same process instead of starting more workers.
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    _server!.listen(_handleRequest);
    try {
      await _historyCache.initialize();
      await _algorithms.restore([]);
      await _loadSettings();
      _schwab =
          schwabApiFactory?.call(_storage, _handleQuote, _handleFeedState) ??
          SchwabApi(
            storage: _storage,
            onQuote: _handleQuote,
            onState: _handleFeedState,
          );
      for (final run in _runs.values) {
        if (run.savedEngineCheckpoints.isNotEmpty) _prepareRuntime(run);
      }
      _loadResearchSession(_selectedSavedRun);
    } catch (_) {
      await _server?.close(force: true);
      _server = null;
      await _algorithms.close();
      rethrow;
    }
    _persistenceTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      // Historical jobs save at generation boundaries. There is no new data
      // to save every five seconds while they tune or while runs are stopped.
      if (_runs.values.any(
        (run) => !run.historicalMode && run.runtime?.running == true,
      )) {
        unawaited(_persist());
      }
    });
    if (autoCollectCandles) {
      _candleCollectionTimer = Timer.periodic(
        const Duration(minutes: 5),
        (_) => unawaited(_collectCompletedCandleDays()),
      );
    }
    _freshnessTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      for (final run in _runs.values) {
        if (!run.historicalMode) run.runtime?.checkFreshness();
      }
    });
    _ready = true;
    unawaited(_loadCredentialStatus());
    if (_runs.values.any((run) => run.resumeOnConnection)) {
      try {
        await _schwab!.startStreaming(_subscriptionSymbols());
      } catch (error) {
        _lastError = 'Automatic Schwab reconnect could not start: $error';
      }
    }
  }

  Future<void> _collectCompletedCandleDays() async {
    if (!_authorized || _collectingCandles) return;
    _collectingCandles = true;
    try {
      final now = _historyClock().toUtc();
      final eastern = UsEquityCalendar.toEastern(now);
      var day = DateTime.utc(eastern.year, eastern.month, eastern.day);
      while (true) {
        final session = UsEquityCalendar.forDate(
          day.add(const Duration(hours: 16)),
        );
        final close = session == null
            ? null
            : UsEquityCalendar.easternToUtc(
                DateTime(
                  day.year,
                  day.month,
                  day.day,
                  session.closeMinute ~/ 60,
                  session.closeMinute % 60,
                ),
              );
        if (close != null &&
            !now.isBefore(close.add(const Duration(minutes: 15)))) {
          break;
        }
        day = day.subtract(const Duration(days: 1));
      }
      final symbols = {
        for (final run in _runs.values)
          ...(run.settings['watchlist'] as List).cast<String>(),
      };
      for (final symbol in symbols) {
        final previous = await _historyCache.latestCompleteDay(symbol);
        var start =
            previous?.add(const Duration(days: 1)) ??
            day.subtract(const Duration(days: 28));
        final oldestDownload = day.subtract(const Duration(days: 28));
        if (start.isBefore(oldestDownload)) start = oldestDownload;
        if (!start.isAfter(day)) {
          await _historyCache.fetch(
            symbol: symbol,
            startUtc: start,
            endUtc: day.add(const Duration(days: 1)),
          );
        }
      }
    } catch (error) {
      _historyCache.lastActivity = 'Daily candle collection will retry: $error';
    } finally {
      _collectingCandles = false;
    }
  }

  void _handleFeedState(FeedState state, String reason) {
    _feedState = state;
    _feedReason = reason;
    if (state != FeedState.live) {
      _training.invalidateAll();
      _trainingBuilders.clear();
    }
    for (final run in _runs.values) {
      final runtime = run.historicalMode ? null : run.runtime;
      if (state == FeedState.live) {
        runtime?.setConnected(true);
        if (run.resumeOnConnection && runtime != null) {
          runtime.begin();
          run.resumeOnConnection = false;
        }
      } else if (state == FeedState.reauthorizationRequired) {
        runtime?.requireReauthorization(reason);
      } else {
        runtime?.setConnected(false, reason: reason);
      }
    }
    _syncTrainingActivity();
  }

  Future<void> _loadCredentialStatus() async {
    try {
      final credentialStatus = await _schwab!.credentialStatus;
      _credentialsConfigured = credentialStatus.hasCredentials;
      _authorized = credentialStatus.authorized;
      _redirectUri = credentialStatus.redirectUri;
      if (autoCollectCandles) unawaited(_collectCompletedCandleDays());
    } catch (error) {
      _credentialsConfigured = false;
      _authorized = false;
      _lastError = error is SecureStorageException
          ? error.message
          : 'Schwab credentials could not be loaded from Windows protected '
                'storage (${error.runtimeType}). Enter the Client ID and '
                'Client Secret again to replace them.';
    }
  }

  Future<void> stop() async {
    _shuttingDown = true;
    _research.stop();
    await _research.stopped;
    _persistenceTimer?.cancel();
    _freshnessTimer?.cancel();
    _candleCollectionTimer?.cancel();
    for (final run in _runs.values) {
      if (run.historicalMode) run.runtime?.running = false;
      _cancelLmRequests(run);
    }
    await _callbackServer?.close();
    await _schwab?.dispose();
    await _persist();
    try {
      await _algorithms.close();
    } finally {
      await _server?.close(force: true);
      _server = null;
      _ready = false;
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final origin = request.headers.value('origin');
    final originUri = origin == null ? null : Uri.tryParse(origin);
    if (originUri != null &&
        const {'localhost', '127.0.0.1'}.contains(originUri.host)) {
      request.response.headers.set(
        HttpHeaders.accessControlAllowOriginHeader,
        origin!,
      );
    }
    request.response.headers
      ..set(HttpHeaders.accessControlAllowMethodsHeader, 'GET, POST, OPTIONS')
      ..set(HttpHeaders.accessControlAllowHeadersHeader, 'Content-Type')
      ..contentType = ContentType.json;
    if (request.method == 'OPTIONS') {
      request.response.statusCode = HttpStatus.noContent;
      await request.response.close();
      return;
    }
    if (_shuttingDown && request.method != 'GET') {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await _writeJson(request, {
        'error': 'The backend is saving and stopping.',
      });
      return;
    }
    try {
      final path = request.uri.path;
      if (request.method == 'GET' && path == '/api/health') {
        await _writeJson(request, {
          'service': 'atrader-backend',
          'apiVersion': 1,
          'ready': _ready && !_shuttingDown,
          if (_shuttingDown) 'stopping': true,
        });
      } else if (!_ready) {
        request.response.statusCode = HttpStatus.serviceUnavailable;
        await _writeJson(request, {
          'error': 'The backend is loading saved simulations.',
        });
      } else if (request.method == 'POST' &&
          path == '/api/backend/shutdown' &&
          requestShutdown != null) {
        if (origin != null ||
            request.headers.value('x-atrader-control') != 'restart') {
          request.response.statusCode = HttpStatus.forbidden;
          await _writeJson(request, {
            'error': 'Use the desktop Restart backend control.',
          });
          return;
        }
        await _writeJson(request, {'stopping': true});
        requestShutdown!();
      } else if (request.method == 'GET' && path == '/api/status') {
        await _writeJson(request, _status(_requestedRun(request)));
      } else if (request.method == 'GET' && path == '/api/algorithms') {
        await _writeJson(request, {'algorithms': _algorithms.catalogue});
      } else if (request.method == 'POST' && path == '/api/history/download') {
        final body = await _readBody(request);
        final symbols =
            (body['watchlist'] as List?)?.cast<String>() ?? const <String>[];
        if (symbols.isEmpty || symbols.length > 64) {
          throw ArgumentError('Choose 1 to 64 symbols.');
        }
        final range = _historicalRangeFromBody(body, nowUtc: _clock().toUtc());
        var count = 0;
        for (final symbol in symbols) {
          count += (await _historyCache.fetch(
            symbol: symbol,
            startUtc: range.startUtc,
            endUtc: range.endUtc,
          )).length;
        }
        await _writeJson(request, {'bars': count, ..._historyCache.status});
      } else if (request.method == 'POST' && path == '/api/algorithms/import') {
        if (_importingAlgorithm) {
          throw StateError('Another algorithm import is in progress.');
        }
        _importingAlgorithm = true;
        try {
          if (_persistenceBlocked) {
            throw StateError(
              'Restore access to saved simulation data before importing an algorithm.',
            );
          }
          final body = await _readBody(request);
          final filename = body['filename'], source = body['source'];
          if (filename is! String || source is! String) {
            throw ArgumentError('Choose a .json or .dart file.');
          }
          final imported = await _algorithms.importFile(filename, source);
          try {
            await _persist(
              requireSuccess: true,
              failureMessage:
                  'Algorithm could not be saved; import was rolled back.',
            );
          } catch (_) {
            await _algorithms.rollbackLastImport();
            rethrow;
          }
          await _writeJson(request, imported);
        } finally {
          _importingAlgorithm = false;
        }
      } else if (request.method == 'GET' && path == '/api/snapshot') {
        await _writeJson(request, await _snapshot(_requestedRun(request)));
      } else if (request.method == 'GET' &&
          path == '/api/evolution/population') {
        await _writeJson(
          request,
          await _populationResults(
            _requestedRun(request),
            request.uri.queryParameters,
          ),
        );
      } else if (request.method == 'GET' &&
          path == '/api/runs/variable-changes') {
        final text = request.uri.queryParameters['generation'];
        final generation = int.tryParse(text ?? '');
        if (text != null && generation == null) {
          throw ArgumentError('Choose a completed generation.');
        }
        await _writeJson(
          request,
          await _variableChanges(_requestedRun(request), generation),
        );
      } else if (request.method == 'GET' && path == '/api/export') {
        await _writeJson(request, await _exportData());
      } else if (request.method == 'GET' && path == '/api/runs') {
        await _writeJson(request, {
          'selectedRunId': _selectedRun.id,
          'runs': _runSummaries(),
        });
      } else if (request.method == 'POST' && path == '/api/runs/select') {
        final body = await _readBody(request);
        final id = body['runId'];
        if (id == _researchPreviewId && _researchPreview != null) {
          _viewingResearchPreview = true;
        } else if (id is String && _runs.containsKey(id)) {
          _selectedRunId = id;
          _viewingResearchPreview = false;
          _followResearchSourceId = null;
          if (_research.status['running'] != true &&
              _research.status['stopping'] != true) {
            _loadResearchSession(_runs[id]!);
          }
          await _persist(requireSuccess: true);
        } else {
          throw ArgumentError('Choose an existing simulation.');
        }
        await _writeJson(request, {'selectedRunId': id});
      } else if (request.method == 'POST' &&
          (path == '/api/runs/create' || path == '/api/workspace/settings')) {
        final body = await _readBody(request);
        final workspace = path == '/api/workspace/settings';
        final previous = _selectedSavedRun;
        if (workspace &&
            (_research.status['running'] == true ||
                _research.status['stopping'] == true ||
                previous.runtime?.running == true ||
                previous.resumeOnConnection)) {
          throw StateError('Stop the simulation before changing its setup.');
        }
        final number = workspace ? null : _nextRunNumber++;
        final id = workspace ? previous.id : 'run-$number';
        final name = body['name']?.toString().trim();
        final run = _BackendRun(
          id: id,
          name: workspace
              ? 'Simulation'
              : name == null || name.isEmpty
              ? 'Simulation $number'
              : name,
          settings: jsonDecode(jsonEncode(_settings)) as Map<String, dynamic>,
        );
        final configuration = body['configuration'];
        if (configuration != null) {
          if (configuration is! Map<String, dynamic>) {
            throw ArgumentError('Simulation configuration must be an object.');
          }
          _updateSettings(configuration, run: run);
        }
        if (body['historicalRange'] case final Map<String, dynamic> range) {
          run.historicalRange = _historicalRangeFromBody(
            range,
            nowUtc: _clock().toUtc(),
          );
        }
        if (workspace) {
          run.settings['_workspaceRevision'] =
              (previous.settings['_workspaceRevision'] as int? ?? 0) + 1;
          run.trainingArchive.addAll(previous.trainingArchive);
          if (previous.researchSession != null ||
              previous.runtime != null ||
              previous.savedEngineCheckpoints.isNotEmpty) {
            final archive = _exportRun(previous)..remove('trainingArchive');
            run.trainingArchive.add({
              'simulation': archive,
              'performance': performanceByRun({
                'runs': [archive],
              }),
            });
          }
        }
        _runs[id] = run;
        _selectedRunId = id;
        _viewingResearchPreview = false;
        _followResearchSourceId = null;
        if (path == '/api/workspace/settings') _loadResearchSession(run);
        await _persist(requireSuccess: true);
        if (_feedState == FeedState.live) {
          await _schwab!.updateStreamingSymbols(_subscriptionSymbols());
        }
        await _writeJson(request, {'runId': id, 'name': run.name});
      } else if (request.method == 'POST' &&
          (path == '/api/runs/rename' || path == '/api/runs/delete')) {
        final body = await _readBody(request);
        final run =
            _runs[body['runId']] ??
            (throw ArgumentError('Choose a saved simulation.'));
        if (path == '/api/runs/rename') {
          final name = body['name']?.toString().trim() ?? '';
          if (name.isEmpty) throw ArgumentError('Enter a simulation name.');
          run.name = name;
        } else {
          if (_researchSourceId == run.id &&
              (_research.status['running'] == true ||
                  _research.status['stopping'] == true)) {
            throw StateError('Stop training before deleting this simulation.');
          }
          if (run.runtime?.running == true || run.resumeOnConnection) {
            throw StateError('Stop the simulation before deleting it.');
          }
          _runs.remove(run.id);
          if (_selectedRunId == run.id) {
            if (_runs.isEmpty) {
              final number = _nextRunNumber++;
              final id = 'run-$number';
              _runs[id] = _BackendRun(
                id: id,
                name: 'Simulation $number',
                settings: _defaultSettings(),
              );
            }
            _selectedRunId = _runs.keys.first;
          }
        }
        await _persist(requireSuccess: true);
        if (path == '/api/runs/delete' && _feedState == FeedState.live) {
          await _schwab!.updateStreamingSymbols(_subscriptionSymbols());
        }
        await _writeJson(request, {'selectedRunId': _selectedRun.id});
      } else if (request.method == 'POST' && path == '/api/runs/tune') {
        final body = await _readBody(request);
        final id = body['runId']?.toString();
        if (id == _researchPreviewId ||
            (id == null && _viewingResearchPreview)) {
          _throwResearchPreviewReadOnly();
        }
        final run = id == null
            ? _selectedRun
            : _runs[id] ?? (throw ArgumentError('Unknown simulation: $id'));
        await _writeJson(
          request,
          await _tuneRun(
            run,
            enableShortSelling: body['enableShortSelling'] as bool?,
            requestId: body['requestId'] as String?,
            generations: body['generations'] as int? ?? 2,
          ),
        );
      } else if (request.method == 'POST' && path == '/api/research/start') {
        final body = await _readBody(request);
        final continuous = body['continuous'] == true;
        final generations = body['generations'] as int? ?? 2;
        final evolutions = body['evolutions'];
        if (evolutions != null &&
            (evolutions is! int ||
                evolutions < 1 ||
                evolutions > maxTuningGenerations)) {
          throw ArgumentError('Choose 1 to $maxTuningGenerations generations.');
        }
        if (generations < 0 || generations > maxTuningGenerations) {
          throw ArgumentError('Choose 0 to $maxTuningGenerations generations.');
        }
        final id = body['runId'];
        final selected =
            _runs[id] ??
            (throw ArgumentError('Choose an existing simulation.'));
        final resume = body['resume'] == true ? selected.researchSession : null;
        if (body['resume'] == true && resume == null) {
          throw StateError('This simulation has no saved training session.');
        }
        final configuration = body['configuration'];
        final requestedRange = resume != null ? null : body['historicalRange'];
        final researchRange = switch (requestedRange) {
          final Map<String, dynamic> fields => _historicalRangeFromBody(
            fields,
            nowUtc: _clock().toUtc(),
            preserveEndTime: continuous,
          ),
          null =>
            resume != null
                ? (
                    startUtc: DateTime.parse(
                      (resume['rangeStart'] ?? resume['start']) as String,
                    ),
                    endUtc: DateTime.parse(
                      (resume['rangeEnd'] ?? resume['end']) as String,
                    ),
                    label:
                        resume['rangeLabel'] as String? ??
                        'Saved training range',
                  )
                : configuration == null
                ? selected.historicalRange
                : null,
          _ => throw ArgumentError(
            'Historical research range must be an object.',
          ),
        };
        if ((evolutions != null || continuous) && researchRange == null) {
          throw ArgumentError('Choose a historical date range.');
        }
        final run = _BackendRun(
          id: selected.id,
          name: selected.name,
          settings: Map.of(selected.settings),
        );
        if (configuration != null) {
          if (configuration is! Map<String, dynamic>) {
            throw ArgumentError('Simulation configuration must be an object.');
          }
          _updateSettings(configuration, run: run);
        }
        final evolution = EvolutionSettings.fromJson(
          body['evolution'] as Map<String, dynamic>?,
        );
        if (resume != null) {
          run.settings
            ..clear()
            ..addAll(resume['source'] as Map<String, dynamic>);
        }
        _research.start(
          runName: run.name,
          configuration: run.settings,
          strategies: _buildStrategySettings(run),
          generations: evolutions == null ? generations : 1,
          evolutionLimit: evolutions as int?,
          continuous: continuous,
          historicalRange: researchRange,
          evolution: evolution,
          resume: resume,
        );
        _researchSourceId = selected.id;
        _generationExports
          ..clear()
          ..addAll(resume == null ? [] : selected.generationResults);
        if (selected.runtime == null &&
            selected.savedEngineCheckpoints.isEmpty) {
          selected.settings
            ..clear()
            ..addAll(run.settings);
          selected.historicalRange = researchRange;
        }
        if (resume == null) {
          if (selected.researchSession != null) {
            selected.trainingArchive.add({
              'session': selected.researchSession,
              'generations': List.of(selected.generationResults),
              'strategyBests': Map.of(selected.strategyBests),
            });
          }
          selected.generationResults.clear();
          selected.strategyBests.clear();
          selected.researchPreview = null;
        }
        _followResearchSourceId = evolutions != null || continuous
            ? selected.id
            : null;
        _saveResearchSession();
        await _persist(requireSuccess: true);
        await _writeJson(request, {'started': true});
      } else if (request.method == 'POST' && path == '/api/research/stop') {
        _research.stop();
        await _writeJson(request, {'stopped': true});
      } else if (request.method == 'POST' && path == '/api/settings/run') {
        final body = await _readBody(request);
        _requireSavedRun();
        _updateSettings(body);
        await _persist(requireSuccess: true);
        if (_feedState == FeedState.live) {
          await _schwab!.updateStreamingSymbols(_subscriptionSymbols());
        }
        await _writeJson(request, {'saved': true});
      } else if (request.method == 'POST' &&
          path == '/api/schwab/credentials') {
        final body = await _readBody(request);
        final redirectUri = _validatedRedirectUri(
          body['redirectUri']?.toString() ?? '',
        );
        await _schwab!.saveAppCredentials(
          appKey: body['appKey']?.toString() ?? '',
          appSecret: body['appSecret']?.toString() ?? '',
          redirectUri: redirectUri,
        );
        _credentialsConfigured = true;
        _redirectUri = redirectUri;
        _lastError = null;
        _authorized = await _schwab!.isAuthorized;
        await _writeJson(request, {'saved': true});
      } else if (request.method == 'POST' &&
          path == '/api/schwab/credentials/remove') {
        await _callbackServer?.close();
        await _schwab!.stopStreaming();
        await _schwab!.removeCredentials();
        _credentialsConfigured = false;
        _authorized = false;
        _redirectUri = '';
        _oauthMessage = '';
        _handleFeedState(
          FeedState.disconnected,
          'Schwab credentials and tokens were removed.',
        );
        await _writeJson(request, {'removed': true});
      } else if (request.method == 'POST' &&
          path == '/api/schwab/oauth/start') {
        await _writeJson(request, await _startAuthorization());
      } else if (request.method == 'POST' &&
          path == '/api/schwab/oauth/complete') {
        final body = await _readBody(request);
        final redirected = Uri.tryParse(
          body['redirectedUrl']?.toString().trim() ?? '',
        );
        if (redirected == null || !redirected.hasQuery) {
          throw ArgumentError(
            'Paste the full address from the browser after Schwab redirects '
            '(it contains code= and state=).',
          );
        }
        await _writeJson(request, {
          'authorized': true,
          'message': await _completeAuthorization(redirected),
        });
      } else if (request.method == 'GET' &&
          (path == '/oauth/callback' || _isBackendCallbackPath(path))) {
        await _handleOAuthCallback(request);
      } else if (request.method == 'POST' && path == '/api/schwab/connect') {
        if (!_authorized) {
          throw StateError('Complete Schwab OAuth authorization first.');
        }
        await _schwab!.startStreaming(_subscriptionSymbols());
        await _writeJson(request, {'connecting': true});
      } else if (request.method == 'POST' && path == '/api/schwab/disconnect') {
        await _schwab!.stopStreaming();
        _handleFeedState(FeedState.disconnected, 'Disconnected by the user.');
        await _writeJson(request, {'disconnected': true});
      } else if (request.method == 'POST' && path == '/api/run/start') {
        _requireSavedRun();
        _startRun();
        await _persist(requireSuccess: true);
        await _writeJson(request, {'started': true});
      } else if (request.method == 'POST' &&
          path == '/api/run/historical/start') {
        final body = await _readBody(request);
        _requireSavedRun();
        final range = _historicalRangeFromBody(
          body,
          nowUtc: DateTime.now().toUtc(),
        );
        _beginHistoricalRun(range);
        await _writeJson(request, {'started': true});
      } else if (request.method == 'POST' && path == '/api/run/stop') {
        _requireSavedRun();
        _resumeOnConnection = false;
        _runtime?.running = false;
        _cancelLmRequests(_selectedRun);
        if (!_historicalMode) _runtime?.runStatus = 'Stopped';
        _syncTrainingActivity();
        await _persist(requireSuccess: true);
        await _writeJson(request, {'stopped': true});
      } else if (request.method == 'POST' && path == '/api/run/reset') {
        _requireSavedRun();
        if (_runtime?.running == true || _resumeOnConnection) {
          throw StateError('Stop the current run before clearing its data.');
        }
        _runtime = null;
        _replay = null;
        _historicalMode = false;
        _selectedRun.historicalRange = null;
        _savedEngineCheckpoints.clear();
        _selectedRun.pinnedModels.clear();
        _selectedRun.startedAt = null;
        await _persist(
          requireSuccess: true,
          failureMessage:
              'Run data was cleared in memory but could not be saved. '
              'Previous data may return after a restart.',
        );
        await _writeJson(request, {'cleared': true});
      } else if (request.method == 'POST' && path == '/api/training/settings') {
        final body = await _readBody(request);
        final enabled = body['autoTrain'];
        if (enabled is! bool) {
          throw ArgumentError('Auto training must be enabled or disabled.');
        }
        _training.setAutoTraining(enabled);
        await _persist(requireSuccess: true);
        await _writeJson(request, {
          'saved': true,
          'training': _training.status,
        });
      } else if (request.method == 'POST' && path == '/api/training/train') {
        if ((_training.status['maturedExamples'] as int) <
            _training.minimumExamples) {
          throw StateError(_training.status['readiness'].toString());
        }
        unawaited(_trainAndPersist());
        await _writeJson(request, {
          'started': true,
          'training': _training.status,
        });
      } else if (request.method == 'POST' && path == '/api/lm/config') {
        final body = await _readBody(request);
        final uri = Uri.tryParse(body['url']?.toString() ?? '');
        if (uri == null ||
            !const {'http', 'https'}.contains(uri.scheme) ||
            uri.host.isEmpty) {
          throw ArgumentError('LM Studio URL must be a valid HTTP(S) URL.');
        }
        _lmSettings
          ..['url'] = uri.toString().replaceFirst(RegExp(r'/$'), '')
          ..['model'] = body['model']?.toString() ?? '';
        await _persist(requireSuccess: true);
        await _writeJson(request, {'saved': true});
      } else if (request.method == 'GET' && path == '/api/lm/models') {
        final client = _lmClient();
        try {
          await _writeJson(request, {'models': await client.discoverModels()});
        } finally {
          client.close();
        }
      } else if (request.method == 'POST' && path == '/api/lm/test') {
        final client = _lmClient();
        try {
          await client.testToolCalling();
          await _writeJson(request, {
            'tested': true,
            'model': _lmSettings['model'],
          });
        } finally {
          client.close();
        }
      } else if (request.method == 'GET' && path == '/api/log') {
        await _writeJson(request, {
          'events': _runEvents(_requestedRun(request)),
        });
      } else {
        request.response.statusCode = HttpStatus.notFound;
        await _writeJson(request, {'error': 'Endpoint not found.'});
      }
    } catch (error) {
      _lastError = switch (error) {
        SchwabAuthorizationException(:final message) => message,
        SecureStorageException(:final message) => message,
        StateError(:final message) => message,
        ArgumentError(:final message) => '$message',
        _ => error.toString(),
      };
      request.response.statusCode = HttpStatus.badRequest;
      await _writeJson(request, {'error': _lastError});
    }
  }

  Future<void> _handleOAuthCallback(HttpRequest request) async {
    String message;
    try {
      message = await _completeAuthorization(request.uri);
    } catch (error) {
      request.response.statusCode = HttpStatus.badRequest;
      message = 'Schwab authorization failed: ${describeOAuthError(error)}';
    }
    request.response.headers.contentType = ContentType.html;
    request.response.write(
      '<html><body>${const HtmlEscape().convert(message)}</body></html>',
    );
    await request.response.close();
  }

  /// Saves a fresh OAuth state, starts the loopback listener needed by the
  /// registered callback URL, and returns the Schwab login URL.
  Future<Map<String, Object?>> _startAuthorization() async {
    final authorizationUrl = await _schwab!.authorizationUrl();
    final redirect = Uri.parse(
      Uri.parse(authorizationUrl).queryParameters['redirect_uri'] ?? '',
    );
    _redirectUri = redirect.toString();
    var listening = false;
    if (OAuthCallbackServer.needsListener(redirect, _port)) {
      final server = _callbackServer ??= OAuthCallbackServer(
        dataDirectory: _dataRoot,
        onCallback: _completeAuthorization,
      );
      try {
        await server.listen(redirect);
        listening = true;
        _oauthMessage = redirect.scheme == 'https'
            ? 'Waiting for Schwab at $redirect. If the browser warns about '
                  'the local certificate, choose Advanced and continue; or '
                  'paste the final browser address into Settings.'
            : 'Waiting for Schwab at $redirect.';
      } catch (error) {
        _oauthMessage =
            'The local callback listener could not start ($error). After '
            'Schwab redirects, copy the full browser address and paste it '
            'into Settings.';
      }
    } else if (_isBackendCallbackPath(redirect.path) ||
        redirect.path == '/oauth/callback') {
      listening =
          const {'127.0.0.1', 'localhost'}.contains(redirect.host) &&
          redirect.port == _port;
      _oauthMessage = listening
          ? 'Waiting for Schwab at $redirect.'
          : 'After Schwab redirects, paste the full browser address into '
                'Settings.';
    } else {
      _oauthMessage =
          'After Schwab redirects, paste the full browser address into '
          'Settings.';
    }
    return {
      'authorizationUrl': authorizationUrl,
      'callbackListening': listening,
      'message': _oauthMessage,
    };
  }

  Future<String> _completeAuthorization(Uri callbackUri) async {
    try {
      await _schwab!.completeAuthorization(callbackUri);
    } catch (error) {
      _lastError = 'Schwab authorization failed: ${describeOAuthError(error)}';
      _oauthMessage = _lastError!;
      rethrow;
    }
    _authorized = true;
    _credentialsConfigured = true;
    _lastError = null;
    _oauthMessage = 'Schwab authorized. Connect the Schwab stream to begin.';
    _feedReason = 'Schwab authorized. Connect the stream in Settings.';
    final server = _callbackServer;
    if (server != null) {
      unawaited(Future<void>.delayed(const Duration(seconds: 2), server.close));
    }
    return 'Schwab connected. Return to A-Trader and choose Connect Schwab '
        'stream to start receiving live data.';
  }

  bool _isBackendCallbackPath(String path) {
    final redirect = Uri.tryParse(_redirectUri);
    return redirect != null &&
        redirect.scheme == 'http' &&
        redirect.port == _port &&
        redirect.path.isNotEmpty &&
        redirect.path == path &&
        !path.startsWith('/api/');
  }

  static String _validatedRedirectUri(String value) {
    final text = value.trim().isEmpty ? defaultRedirectUri : value.trim();
    final uri = Uri.tryParse(text);
    if (uri == null ||
        !const {'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw ArgumentError(
        'The callback URL must be a full address such as '
        '$defaultRedirectUri and must exactly match the Schwab app.',
      );
    }
    return text;
  }

  Future<Map<String, dynamic>> _readBody(HttpRequest request) async {
    final limit = request.uri.path == '/api/algorithms/import'
        ? 8 * 1024 * 1024
        : 64 * 1024;
    final bytes = <int>[];
    await for (final chunk in request) {
      if (bytes.length + chunk.length > limit) {
        throw const HttpException('Request body exceeds the allowed size.');
      }
      bytes.addAll(chunk);
    }
    final text = utf8.decode(bytes);
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Expected a JSON object.');
    }
    return decoded;
  }

  Future<void> _writeJson(
    HttpRequest request,
    Map<String, Object?> body,
  ) async {
    request.response.write(jsonEncode(body));
    await request.response.close();
  }

  List<Map<String, Object?>> _runSummaries() => [
    for (final run in [..._runs.values, ?_researchPreview])
      {
        'id': run.id,
        'name': run.name,
        'running': run.runtime?.running == true || run.resumeOnConnection,
        'runMode': run.historicalMode ? 'historical' : 'live',
        'watchlist': run.settings['watchlist'],
      },
  ];

  List<String> _subscriptionSymbols() => {
    for (final run in _runs.values)
      if (!run.historicalMode)
        ...(run.settings['watchlist'] as List<dynamic>).cast<String>(),
  }.toList();

  _BackendRun _requestedRun(HttpRequest request) {
    final id = request.uri.queryParameters['runId'];
    if (id == null) return _selectedRun;
    if (id == _researchPreviewId && _researchPreview != null) {
      return _researchPreview!;
    }
    return _runs[id] ?? (throw ArgumentError('Unknown simulation: $id'));
  }

  void _requireSavedRun() {
    if (_viewingResearchPreview) _throwResearchPreviewReadOnly();
  }

  Never _throwResearchPreviewReadOnly() => throw StateError(
    'Select a saved simulation to change its settings or run it.',
  );

  void _publishResearchPreview(
    Map<String, dynamic> configuration,
    SimulatorEngine engine,
    HistoricalRange range,
  ) {
    final run =
        _BackendRun(
            id: _researchPreviewId,
            name: 'Latest research simulation',
            settings: configuration,
          )
          ..historicalMode = true
          ..historicalRange = range;
    final runtime = _createRuntime(engine.strategies, run: run);
    runtime.engines[1] = engine;
    final research = _research.status;
    final limit = research['evolutionLimit'];
    final continuous = research['continuous'] == true;
    final generation = research['cycles'] as int;
    if (limit != null || continuous) {
      final trialEquity = <String, num>{};
      for (final result in (research['lastResults'] as List).cast<Map>()) {
        final metrics =
            ((result['populationSummary'] as Map?)?['candidatePerformance'] ??
                    result['tunedValidation'])
                as Map?;
        if (result['candidateParameters'] != null &&
            metrics?['endingEquity'] is num) {
          trialEquity[result['label'] as String] =
              metrics!['endingEquity'] as num;
        }
      }
      final previous = generation > 1
          ? _researchPreview?.generationEquity
          : null;
      run.generationEquity = {
        for (final account in engine.accounts.values)
          account.label: [
            ...?previous?[account.label],
            {
              'generation': generation,
              'value': engine.markToMarket(account),
              'trialValue': ?trialEquity[account.label],
            },
          ],
      };
    }
    runtime.runStatus = continuous
        ? 'Generation $generation · ${range.label}'
        : limit == null
        ? 'Research replay complete · ${range.label}'
        : 'Generation ${research['cycles']} of $limit · ${range.label}';
    run.runtime = runtime;
    if (limit != null || continuous) {
      final exported = _exportRun(run);
      _generationExports.add({
        'generation': generation,
        'simulation': exported,
        'performance': performanceByRun({
          'runs': [exported],
        }).single['portfolios'],
        'tuningResults': _research.latestResults,
      });
      final source = _runs[_researchSourceId];
      if (source != null) {
        source.generationResults = List.of(_generationExports);
        source.researchPreview = exported;
        _recordStrategyBests(source, range, generation);
      }
    }
    _researchPreview = run;
    if (_followResearchSourceId == _selectedRunId) {
      _viewingResearchPreview = true;
    }
  }

  void _saveResearchSession() {
    final source = _runs[_researchSourceId];
    if (source == null) return;
    source.researchSession =
        jsonDecode(jsonEncode(_research.checkpoint())) as Map<String, dynamic>;
    unawaited(_persist());
  }

  void _loadResearchSession(_BackendRun run) {
    _researchSourceId = run.id;
    final saved = run.researchSession;
    _generationExports
      ..clear()
      ..addAll(run.generationResults);
    _researchPreview = null;
    _research.restoreCheckpoint(saved ?? {});
    if (run.researchPreview case final preview?) {
      _researchPreview = _restoreRun(
        preview,
        _researchPreviewId,
        'Latest research simulation',
      );
      _prepareRuntime(_researchPreview!);
    }
  }

  void _recordStrategyBests(
    _BackendRun source,
    HistoricalRange range,
    int generation,
  ) {
    final results = (_research.status['lastResults'] as List).cast<Map>();
    for (final result in results) {
      final label = result['label'] as String;
      final best = source.strategyBests.putIfAbsent(label, () => {});
      for (final metric in ['profit', 'winRate']) {
        final candidate =
            result[metric == 'profit'
                    ? 'bestProfitCandidate'
                    : 'bestWinRateCandidate']
                as Map?;
        if (candidate == null) continue;
        final performance = candidate['performance'] as Map;
        final previous = best[metric] as Map?;
        final value =
            performance[metric == 'profit' ? 'netProfit' : 'winRatePercent']
                as num;
        final oldValue =
            (previous?['performance'] as Map?)?[metric == 'profit'
                    ? 'netProfit'
                    : 'winRatePercent']
                as num?;
        final higherProfitOnTie =
            value == oldValue &&
            (performance['netProfit'] as num) >
                ((previous!['performance'] as Map)['netProfit'] as num);
        if (oldValue == null || value > oldValue || higherProfitOnTie) {
          best[metric] = {
            'generation': generation,
            'strategyId': result['strategyId'],
            'parameters': candidate['parameters'],
            'performance': performance,
            'startUtc': range.startUtc.toIso8601String(),
            'endUtc': range.endUtc.toIso8601String(),
          };
        }
      }
    }
  }

  Map<String, dynamic> _exportRun(_BackendRun run) => {
    'id': run.id,
    'name': run.name,
    'settings': run.settings,
    'startedAt': run.startedAt?.toIso8601String(),
    'runMode': run.historicalMode ? 'historical' : 'live',
    'runStatus': run.runtime?.runStatus,
    if (run.historicalRange case final range?)
      'historicalRange': {
        'startUtc': range.startUtc.toIso8601String(),
        'endUtc': range.endUtc.toIso8601String(),
        'label': range.label,
      },
    'pinnedModels': {
      for (final entry in run.pinnedModels.entries)
        entry.key: entry.value.toJson(),
    },
    'runtime': {
      'running':
          !run.historicalMode &&
          (run.runtime?.running ?? run.resumeOnConnection),
      'engines': run.runtime == null
          ? (run.savedEngineCheckpoints.isEmpty
                ? null
                : run.savedEngineCheckpoints)
          : {
              for (final entry in run.runtime!.engines.entries)
                '${entry.key}': _exportEngine(entry.value),
            },
    },
    if (run.generationEquity != null) 'generationEquity': run.generationEquity,
    if (run.researchSession != null) 'researchSession': run.researchSession,
    if (run.generationResults.isNotEmpty)
      'generationResults': run.generationResults,
    if (run.researchPreview != null) 'researchPreviewData': run.researchPreview,
    'strategyBests': run.strategyBests,
    'trainingArchive': run.trainingArchive,
  };

  Map<String, Object?> _exportEngine(SimulatorEngine engine) {
    final checkpoint = engine.checkpoint();
    final accounts = checkpoint['accounts'] as Map;
    for (final account in engine.accounts.values) {
      (accounts[account.label] as Map)['equity'] = engine.markToMarket(account);
    }
    return checkpoint;
  }

  Future<Map<String, Object?>> _exportData() async {
    final sourceId = _researchSourceId;
    final research = _research.status;
    final state = await _checkpointArchives.unpackState({
      'schemaVersion': 2,
      'selectedRunId': _selectedRun.id,
      'savedAt': _clock().toUtc().toIso8601String(),
      'runs': [
        for (final run in [..._runs.values, ?_researchPreview]) _exportRun(run),
      ],
      'training': _training.checkpoint(),
      'lmStudio': _lmSettings,
      'algorithms': _algorithms.definitions,
    });
    final source = (state['runs'] as List)
        .cast<Map>()
        .where((run) => run['id'] == sourceId)
        .firstOrNull;
    return buildRunDataExport(
      state,
      exportedAt: _clock().toUtc(),
      source: 'running backend',
      research: research,
      generations: (source?['generationResults'] as List? ?? const [])
          .cast<Map<String, Object?>>(),
    );
  }

  Map<String, Object?> _status([_BackendRun? run]) {
    final selected = run ?? _selectedRun;
    final trainingRun = selected.id == _researchPreviewId
        ? _runs[_researchSourceId]
        : selected;
    final session = trainingRun?.researchSession;
    final runtime = selected.runtime;
    final settings = selected.settings;
    return {
      'runId': selected.id,
      'workspaceMode': true,
      'workspaceId': trainingRun?.id ?? _selectedSavedRun.id,
      'workspaceRevision': trainingRun?.settings['_workspaceRevision'] ?? 0,
      'algorithmImportsSupported': true,
      'historyCache': _historyCache.status,
      'algorithms': _algorithms.catalogue,
      'runName': selected.name,
      'trainingSession': session == null
          ? null
          : {
              'cycles': session['cycles'],
              'evolutionLimit': session['evolutionLimit'],
              'continuous': session['continuous'],
              'evolution': session['evolution'],
              'source': session['source'],
              'start': session['rangeStart'] ?? session['start'],
              'end': session['rangeEnd'] ?? session['end'],
            },
      'strategyBests': trainingRun?.strategyBests,
      if (selected.id == _researchPreviewId) ...{
        'researchPreview': true,
        'configurationLocked': true,
      },
      'runs': _runSummaries(),
      'risk': settings['risk'],
      'configuration': settings,
      if (selected.historicalRange case final range?)
        'historicalRange': {
          'start': range.startUtc.toIso8601String(),
          'end': range.endUtc.toIso8601String(),
        },
      'training': _training.status,
      'pinnedModels': {
        for (final entry in selected.pinnedModels.entries)
          entry.key: entry.value.model?.version,
      },
      'feed': _feedState.name,
      'feedReason': _feedReason,
      'schwabCredentialsSaved': _credentialsConfigured,
      'schwabAuthorized': _authorized,
      'schwabRedirectUri': _redirectUri,
      'oauthCallbackListening': _callbackServer?.isListening ?? false,
      'oauthMessage': _oauthMessage,
      'runStatus': selected.resumeOnConnection
          ? 'Reconnecting; fills paused'
          : runtime?.runStatus ?? 'Ready',
      'running': runtime?.running == true || selected.resumeOnConnection,
      'runMode': selected.historicalMode ? 'historical' : 'live',
      'replayProgress': selected.replay?.progress,
      'tuningProgress': _tuningProgress,
      'research': {..._research.status, 'previewRunId': _researchPreview?.id},
      'historicalTimeZones': [MountainTime.zoneId],
      'historicalLmAwaited': true,
      'watchlist': settings['watchlist'],
      'startingCash': settings['startingCash'],
      'lastError': _lastError,
      'symbols': {
        for (final symbol in (settings['watchlist'] as List<dynamic>))
          symbol.toString(): {
            'state':
                runtime?.healthFor(symbol.toString()).state.name ??
                _feedState.name,
            'reason':
                runtime?.healthFor(symbol.toString()).reason ?? _feedReason,
            'updatedAt': runtime
                ?.healthFor(symbol.toString())
                .updatedAt
                ?.toIso8601String(),
          },
      },
      'strategies': [
        for (final setting in settings['strategies'] as List<dynamic>)
          _strategyStatus(setting as Map<String, dynamic>, selected),
      ],
      'lmStudio': {'url': _lmSettings['url'], 'model': _lmSettings['model']},
      'lmSelector': {
        'pendingRequests': selected.pendingLmSelections.length,
        'instances': selected.lmSelectorStatus,
      },
    };
  }

  Map<String, Object?> _strategyStatus(
    Map<String, dynamic> setting,
    _BackendRun run,
  ) {
    final runtime = run.runtime;
    final interval = setting['intervalMinutes'] as int? ?? 1;
    final engine = runtime?.engines[interval];
    final strategy = StrategyRegistry.byId(setting['strategyId'] as String);
    final symbols = run.settings['watchlist'] as List<dynamic>;
    final modelMissing =
        const {'neural_network', 'logistic_regression'}.contains(strategy.id) &&
        run.pinnedModels[strategy.id]?.model == null;
    final lmMissing =
        strategy.id == 'lm_selector' && _lmSettings['model']!.isEmpty;
    return {
      'label': setting['label'],
      'strategyId': strategy.id,
      'intervalMinutes': interval,
      'enabled': setting['enabled'] == true,
      'warmupRequired': strategy.warmupBars,
      'warmupBySymbol': {
        for (final symbol in symbols)
          symbol.toString():
              engine?.candles[symbol.toString()]?.length.clamp(
                0,
                strategy.warmupBars,
              ) ??
              0,
      },
      'readyBySymbol': {
        for (final symbol in symbols)
          symbol.toString():
              !modelMissing &&
              !lmMissing &&
              (engine?.candles[symbol.toString()]?.length ?? 0) >=
                  strategy.warmupBars &&
              (strategy.id != 'lm_selector' ||
                  run.lmSelector?.hasSelection(
                        setting['label'] as String,
                        symbol.toString(),
                      ) ==
                      true),
      },
      'readinessReason': modelMissing
          ? 'No trained model was pinned for this run.'
          : lmMissing
          ? 'Configure an LM Studio model in Settings.'
          : null,
    };
  }

  Future<Map<String, Object?>> _snapshot([_BackendRun? run]) async {
    final selected = run ?? _selectedRun;
    final runtime = selected.runtime;
    final status = _status(selected);
    Map<String, Object?> changes;
    try {
      changes = await _variableChanges(selected);
    } on FileSystemException catch (error) {
      changes = {'error': 'Could not read archived generation results: $error'};
    } on FormatException catch (error) {
      changes = {
        'error': 'Could not decode archived generation results: $error',
      };
    }
    return {
      'status': status,
      'variableChanges': changes,
      if (selected.id == _researchPreviewId)
        'previewEvents': _runEvents(selected),
      if (selected.generationEquity case final history?)
        'generationEquity': [
          for (final account in runtime!.engines[1]!.accounts.values)
            {
              'label': account.label,
              'startingCash': account.startingCash,
              'history': history[account.label],
            },
        ],
      'accounts':
          runtime?.engines.values
              .expand((engine) => engine.accounts.values)
              .map(
                (account) => {
                  'label': account.label,
                  'cash': account.cash,
                  'equity': runtime.engines.values
                      .firstWhere(
                        (engine) => engine.accounts.containsKey(account.label),
                      )
                      .markToMarket(account),
                  'startingCash': account.startingCash,
                  'openLongCount': account.openLongCount,
                  'openShortCount': account.openShortCount,
                  'closedTradeCount': account.closedTradeCount,
                  'closedPnl': account.closedPnl,
                  'events': _compactEvents(account.events),
                  'history': _downsample(account.history)
                      .map(
                        (point) => {
                          'time': point.time.toIso8601String(),
                          'value': point.value,
                        },
                      )
                      .toList(),
                  'positions': account.positions.values
                      .map(
                        (position) => {
                          'symbol': position.symbol,
                          'quantity': position.quantity,
                          'entryPrice': position.entryPrice,
                          'entryTime': position.entryTime.toIso8601String(),
                          'stop': position.stop,
                          'target': position.target,
                          'positionSide': position.side.name,
                          'reservedCollateral':
                              position.side == PositionSide.short
                              ? position.collateral
                              : 0,
                        },
                      )
                      .toList(),
                },
              )
              .toList() ??
          [],
      'candles': {
        for (final engine in runtime?.engines.values ?? <SimulatorEngine>[])
          for (final entry in engine.candles.entries)
            '${entry.key}:${engine.strategies.firstOrNull?.intervalMinutes ?? 1}':
                entry.value
                    .takeLast(300)
                    .map(
                      (bar) => {
                        'time': bar.time.toIso8601String(),
                        'open': bar.open,
                        'high': bar.high,
                        'low': bar.low,
                        'close': bar.close,
                        'volume': bar.volume,
                      },
                    )
                    .toList(),
      },
    };
  }

  Future<Map<String, Object?>?> _generationAt(
    List<Object> history,
    int? generation,
  ) async {
    if (history.isEmpty) return null;
    if (generation == null) return _checkpointArchives.read(history.last);
    for (final entry in history) {
      if (CheckpointArchives.generationNumber(entry) == generation) {
        return _checkpointArchives.read(entry);
      }
    }
    // Older manifests contain paths only. The index usually matches the
    // generation, but verify it before returning a report.
    final index = generation - 1;
    if (index >= 0 &&
        index < history.length &&
        CheckpointArchives.generationNumber(history[index]) == null) {
      final row = await _checkpointArchives.read(history[index]);
      if (row['generation'] == generation) return row;
    }
    for (final (i, entry) in history.indexed) {
      if (i == index || CheckpointArchives.generationNumber(entry) != null) {
        continue;
      }
      final row = await _checkpointArchives.read(entry);
      if (row['generation'] == generation) return row;
    }
    throw ArgumentError('Choose a completed generation.');
  }

  Future<Map<String, Object?>> _variableChanges(
    _BackendRun run, [
    int? generation,
  ]) async {
    final source = run.id == _researchPreviewId
        ? _runs[_researchSourceId]
        : run;
    final history = source?.generationResults ?? const [];
    final latest = await _generationAt(history, null);
    final selected = generation == null || generation == latest?['generation']
        ? latest
        : await _generationAt(history, generation);
    if (generation != null && selected == null) {
      throw ArgumentError('Choose a completed generation.');
    }
    return {
      'sessionId': source?.researchSession?['sessionId'],
      'generation': selected?['generation'],
      'latestGeneration': latest?['generation'] ?? 0,
      'strategies': [
        for (final result
            in (selected?['tuningResults'] as List? ?? const []).cast<Map>())
          {
            for (final key in [
              'label',
              'strategyId',
              'status',
              'message',
              'currentParameters',
              'candidateParameters',
              'tunedParameters',
            ])
              key: result[key],
          },
      ],
    };
  }

  Future<Map<String, Object?>> _populationResults(
    _BackendRun run,
    Map<String, String> query,
  ) async {
    final source = run.id == _researchPreviewId
        ? _runs[_researchSourceId]
        : run;
    final history = source?.generationResults ?? const [];
    final text = query['generation'];
    final generation = text == null ? null : int.tryParse(text);
    if (text != null && generation == null) {
      throw ArgumentError('Invalid generation.');
    }
    final latest = await _generationAt(history, null);
    final selected = generation == null || generation == latest?['generation']
        ? latest
        : await _generationAt(history, generation);
    if (generation != null && selected == null) {
      throw ArgumentError('Choose a completed generation.');
    }
    final results = (selected?['tuningResults'] as List? ?? const [])
        .cast<Map>();
    final label = query['strategy'];
    final strategy =
        results.where((r) => r['label'] == label).firstOrNull ??
        results.firstOrNull;
    final members = (strategy?['individuals'] as List? ?? const []).cast<Map>();
    final id = query['individual'];
    final individual = id == null
        ? null
        : members.where((m) => m['id'] == id).firstOrNull;
    if (id != null && individual == null) {
      throw ArgumentError('Unknown individual.');
    }
    return {
      'sessionId': source?.researchSession?['sessionId'],
      'generation': selected?['generation'],
      'latestGeneration': latest?['generation'] ?? 0,
      'strategies': [for (final r in results) r['label']],
      'strategy': strategy?['label'],
      'championId': strategy?['championId'],
      'individuals': [
        for (final m in members)
          {
            for (final e in m.entries)
              if (e.key != 'account') e.key as String: e.value,
          },
      ],
      'individual': ?individual,
    };
  }

  List<Map<String, Object?>> _runEvents(_BackendRun run) =>
      (run.runtime?.engines.values.expand((engine) => engine.events).toList() ??
              <DecisionEvent>[])
          .sortedNewestFirst()
          .take(3000)
          .map(_eventJson)
          .toList();

  /// Keeps every order, risk, and fill event but only the newest signals so a
  /// long historical replay doesn't send hundreds of thousands of rows.
  List<Map<String, Object?>> _compactEvents(List<DecisionEvent> events) {
    final signals = events.where((event) => event.kind == 'signal').toList();
    final keptSignals = signals.skip(math.max(0, signals.length - 300));
    return [
      ...events.where((event) => event.kind != 'signal'),
      ...keptSignals,
    ].map(_eventJson).toList();
  }

  /// Evenly thins equity history to at most [limit] points, always keeping
  /// the newest mark.
  static List<EquityPoint> _downsample(
    List<EquityPoint> history, {
    int limit = 1500,
  }) {
    if (history.length <= limit) return history;
    final step = history.length / limit;
    return [
      for (var index = 0; index < limit - 1; index++)
        history[(index * step).floor()],
      history.last,
    ];
  }

  Map<String, Object?> _eventJson(DecisionEvent event) => {
    'strategy': event.strategy,
    'symbol': event.symbol,
    'time': event.time.toIso8601String(),
    'action': event.action.name,
    'kind': event.kind,
    'reason': event.reason,
    'price': event.price,
    'measurements': event.measurements,
    'positionSide': event.side?.name,
    'positionEffect': event.positionEffect,
    'entryPrice': event.entryPrice,
    'stop': event.stop,
    'target': event.target,
  };

  void _updateSettings(Map<String, dynamic> body, {_BackendRun? run}) {
    final selected = run ?? _selectedRun;
    final settings = selected.settings;
    if (selected.runtime != null ||
        selected.savedEngineCheckpoints.isNotEmpty) {
      throw StateError(
        'Create a new simulation to change a saved run configuration, '
        'or explicitly clear this stopped run first.',
      );
    }
    final symbols = body['watchlist'];
    if (symbols is! List ||
        symbols.isEmpty ||
        symbols.any((item) => item is! String || item.trim().isEmpty)) {
      throw ArgumentError('Watchlist must contain non-empty ticker symbols.');
    }
    final cash = (body['startingCash'] as num?)?.toDouble() ?? 10000;
    if (!cash.isFinite || cash <= 0) {
      throw ArgumentError('Starting cash must be greater than zero.');
    }
    final rows = body['strategies'];
    if (rows is! List) throw ArgumentError('Strategies must be a list.');
    final strategySettings = <Map<String, Object?>>[];
    final labels = <String>{};
    for (final row in rows) {
      if (row is! Map<String, dynamic>) {
        throw ArgumentError('Invalid strategy settings.');
      }
      final id = row['strategyId']?.toString() ?? '';
      final strategy = StrategyRegistry.byId(id);
      final label = row['label']?.toString().trim() ?? strategy.name;
      if (label.isEmpty || !labels.add(label)) {
        throw ArgumentError('Each enabled strategy needs a unique label.');
      }
      final interval = row['intervalMinutes'] as int? ?? 1;
      if (![1, 5, 15, 30].contains(interval)) {
        throw ArgumentError(
          'Strategy intervals must be 1, 5, 15, or 30 minutes.',
        );
      }
      if (const {'neural_network', 'logistic_regression'}.contains(id) &&
          interval != _training.intervalMinutes) {
        throw ArgumentError(
          'Live-trained models currently use ${_training.intervalMinutes}-minute '
          'decision candles. Other strategies can use any supported interval.',
        );
      }
      // Every strategy gets its own separate portfolio funded with the same
      // run-level starting cash so the equity lines are directly comparable.
      final strategyCash = cash;
      if (!strategyCash.isFinite || strategyCash <= 0) {
        throw ArgumentError(
          'Starting cash for $label must be greater than zero.',
        );
      }
      final parameters = <String, double>{};
      final rawParameters = row['parameters'];
      if (rawParameters is Map<String, dynamic>) {
        for (final definition in strategy.parameters) {
          final value =
              (rawParameters[definition.name] as num?)?.toDouble() ??
              definition.defaultValue;
          if (!value.isFinite ||
              value < definition.minimum ||
              value > definition.maximum) {
            throw ArgumentError(
              '${definition.name} must be ${definition.minimum}–${definition.maximum} ${definition.unit}.',
            );
          }
          parameters[definition.name] = value;
        }
      }
      strategySettings.add({
        'strategyId': id,
        'label': label,
        'intervalMinutes': interval,
        'enabled': row['enabled'] != false,
        'parameters': parameters,
        'startingCash': strategyCash,
      });
    }
    final incomingRisk = body['risk'] as Map<String, dynamic>? ?? {};
    final riskDefaults = settings['risk'] as Map<String, dynamic>;
    final risk = <String, Object?>{};
    for (final field in const [
      'positionSizeFraction',
      'maxExposureFraction',
      'dailyLossLimitFraction',
      'riskFraction',
      'defaultRiskPerShareFraction',
      'defaultTargetFraction',
      'spreadBps',
      'slippageBps',
      'feePerShare',
    ]) {
      final value =
          (incomingRisk[field] as num?)?.toDouble() ??
          (riskDefaults[field] as num).toDouble();
      final maximum = switch (field) {
        'defaultTargetFraction' => 5.0,
        'spreadBps' || 'slippageBps' => 100.0,
        'feePerShare' => 5.0,
        _ => 1.0,
      };
      final minimum =
          field == 'defaultTargetFraction' ||
              field == 'spreadBps' ||
              field == 'slippageBps' ||
              field == 'feePerShare'
          ? 0.0
          : .001;
      if (!value.isFinite || value < minimum || value > maximum) {
        throw ArgumentError('$field must be between $minimum and $maximum.');
      }
      risk[field] = value;
    }
    risk['allowOvernight'] =
        incomingRisk['allowOvernight'] as bool? ??
        riskDefaults['allowOvernight'] as bool;
    for (final field in ['enableShortSelling', 'sessionClosePolicyEnabled']) {
      final value = incomingRisk[field];
      if (value != null && value is! bool) {
        throw ArgumentError('$field must be enabled or disabled.');
      }
      risk[field] = value ?? riskDefaults[field] ?? false;
    }
    final incomingBenchmarks = body['benchmarks'] as Map<String, dynamic>?;
    final benchmarks = BenchmarkSettings.fromJson({
      ...?settings['benchmarks'] as Map<String, dynamic>?,
      ...?incomingBenchmarks,
    });
    final evolution = EvolutionSettings.fromJson(
      body['evolution'] as Map<String, dynamic>? ??
          settings['evolution'] as Map<String, dynamic>?,
    );
    final count =
        body['trainingGenerations'] as int? ??
        settings['trainingGenerations'] as int? ??
        2;
    if (count < 1 || count > maxTuningGenerations) {
      throw ArgumentError('Choose 1 to $maxTuningGenerations generations.');
    }
    final mode = body['mode'] ?? settings['mode'] ?? 'historical';
    if (mode != 'live' && mode != 'historical') {
      throw ArgumentError('Choose live or historical simulation mode.');
    }
    final setup = body['historicalSetup'] ?? settings['historicalSetup'];
    if (setup != null) {
      if (setup is! Map<String, dynamic>) {
        throw ArgumentError('Historical dates must be an object.');
      }
      _historicalRangeFromBody(setup, nowUtc: _clock().toUtc());
    }
    settings
      ..['watchlist'] = symbols
          .map((item) => item.toString().trim().toUpperCase())
          .toSet()
          .toList()
      ..['startingCash'] = cash
      ..['benchmarks'] = benchmarks.toJson()
      ..['evolution'] = evolution.toJson()
      ..['trainingGenerations'] = count
      ..['continuousResearch'] =
          body['continuousResearch'] as bool? ??
          settings['continuousResearch'] as bool? ??
          false
      ..['mode'] = mode
      ..['historicalSetup'] = setup
      ..['strategies'] = strategySettings
      ..['risk'] = risk;
  }

  /// Validates an inclusive calendar-date range and optional wall-clock times.
  /// Requests without [timeZone] retain the original Eastern-time API.
  static HistoricalRange _historicalRangeFromBody(
    Map<String, dynamic> body, {
    required DateTime nowUtc,
    bool preserveEndTime = false,
  }) => historicalRange(
    body['startDate']?.toString() ?? '',
    body['endDate']?.toString() ?? '',
    startTime: body['startTime']?.toString(),
    endTime: body['endTime']?.toString(),
    timeZone: body['timeZone']?.toString(),
    nowUtc: nowUtc,
    preserveEndTime: preserveEndTime,
  );

  static HistoricalRange historicalRange(
    String startDate,
    String endDate, {
    String? startTime,
    String? endTime,
    String? timeZone,
    required DateTime nowUtc,
    bool preserveEndTime = false,
  }) {
    if (timeZone != null && timeZone != MountainTime.zoneId) {
      throw ArgumentError(
        'Unsupported historical replay time zone: $timeZone.',
      );
    }
    final useMountain = timeZone == MountainTime.zoneId;

    ({int hour, int minute})? parseTime(String? value, String name) {
      if (value == null || value.trim().isEmpty) return null;
      final match = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(value.trim());
      final hour = match == null ? -1 : int.parse(match[1]!);
      final minute = match == null ? -1 : int.parse(match[2]!);
      if (hour < 0 || hour > 23 || minute < 0 || minute > 59) {
        throw ArgumentError('Choose a valid $name time.');
      }
      return (hour: hour, minute: minute);
    }

    DateTime parse(String value, String name) {
      final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value);
      if (match == null) {
        throw ArgumentError('Choose a $name date (YYYY-MM-DD).');
      }
      final date = DateTime.utc(
        int.parse(match[1]!),
        int.parse(match[2]!),
        int.parse(match[3]!),
      );
      if (date.year != int.parse(match[1]!) ||
          date.month != int.parse(match[2]!) ||
          date.day != int.parse(match[3]!)) {
        throw ArgumentError('Choose a valid $name date.');
      }
      return date;
    }

    final start = parse(startDate, 'start');
    final end = parse(endDate, 'end');
    final currentWall = useMountain
        ? MountainTime.at(nowUtc)
        : UsEquityCalendar.toEastern(nowUtc);
    final today = DateTime.utc(
      currentWall.year,
      currentWall.month,
      currentWall.day,
    );
    if (end.isBefore(start)) {
      throw ArgumentError('The end date must be on or after the start date.');
    }
    if (end.isAfter(today)) {
      throw ArgumentError('Historical replay cannot include future dates.');
    }
    if (end.difference(start).inDays > 60) {
      throw ArgumentError('Choose a range of 60 days or fewer.');
    }
    final fromTime = parseTime(startTime, 'start');
    final toTime = parseTime(endTime, 'end');
    DateTime asUtc(DateTime wall) => useMountain
        ? MountainTime.toUtc(wall)
        : UsEquityCalendar.easternToUtc(
            DateTime(wall.year, wall.month, wall.day, wall.hour, wall.minute),
          );
    final startUtc = asUtc(
      DateTime.utc(
        start.year,
        start.month,
        start.day,
        fromTime?.hour ?? 0,
        fromTime?.minute ?? 0,
      ),
    );
    final endOfRange = toTime == null
        ? asUtc(DateTime.utc(end.year, end.month, end.day + 1)).subtract(
            useMountain ? Duration.zero : const Duration(milliseconds: 1),
          )
        : asUtc(
            DateTime.utc(
              end.year,
              end.month,
              end.day,
              toTime.hour,
              toTime.minute,
            ),
          );
    if (!endOfRange.isAfter(startUtc)) {
      throw ArgumentError('The end time must be after the start time.');
    }
    if (!startUtc.isBefore(nowUtc)) {
      throw ArgumentError('Historical replay cannot start in the future.');
    }
    final endUtc = !preserveEndTime && endOfRange.isAfter(nowUtc)
        ? nowUtc
        : endOfRange;
    String withTime(
      String date,
      ({int hour, int minute})? time,
      DateTime instant,
    ) {
      if (time == null) return useMountain ? '$date MT' : date;
      if (useMountain) {
        return MountainTime.format(instant, includeSeconds: false);
      }
      return '$date ${time.hour.toString().padLeft(2, '0')}:'
          '${time.minute.toString().padLeft(2, '0')} ET';
    }

    return (
      startUtc: startUtc,
      endUtc: endUtc,
      label:
          '${withTime(startDate, fromTime, startUtc)} to '
          '${withTime(endDate, toTime, endOfRange)}',
    );
  }

  void _beginHistoricalRun(HistoricalRange range) {
    if (_runtime?.running == true) {
      throw StateError(
        'Stop the current simulation before starting a historical replay.',
      );
    }
    final clock = ReplayClock();
    if (_runtime != null || _savedEngineCheckpoints.isNotEmpty) {
      throw StateError('Create a new simulation to preserve this run first.');
    }
    final run = _selectedRun;
    final runtime =
        _createRuntime(_buildStrategySettings(run), run: run, clock: clock.call)
          ..running = true
          ..runStatus = 'Downloading Schwab history (${range.label})';
    _runtime = runtime;
    _replay = null;
    _historicalMode = true;
    run.historicalRange = range;
    _resumeOnConnection = false;
    unawaited(_runHistoricalReplay(run, runtime, clock, range));
  }

  Future<void> _runHistoricalReplay(
    _BackendRun run,
    LiveSimulationRuntime runtime,
    ReplayClock clock,
    HistoricalRange range,
  ) async {
    try {
      final bars = <String, List<MinuteBar>>{};
      for (final (index, symbol) in runtime.watchlist.indexed) {
        if (!runtime.running) break;
        runtime.runStatus =
            'Loading saved/downloaded 1m history · $symbol '
            '(${index + 1} of ${runtime.watchlist.length})';
        final fetched = await _historyCache.fetch(
          symbol: symbol,
          startUtc: range.startUtc,
          endUtc: range.endUtc,
        );
        bars[symbol] = [
          for (final bar in fetched)
            if (!bar.openTime.isBefore(range.startUtc) &&
                bar.openTime.isBefore(range.endUtc))
              bar,
        ];
      }
      if (!identical(run.runtime, runtime)) return;
      if (!runtime.running) {
        runtime.runStatus = 'Historical replay stopped';
        return;
      }
      final quotes = quotesFromMinuteBars(bars);
      if (quotes.isEmpty) {
        runtime
          ..running = false
          ..runStatus =
              'Schwab returned no regular-session minute bars for '
              '${range.label}. Schwab keeps only about the last month of '
              '1-minute history, and weekends and holidays have no data.';
        return;
      }
      final replay = HistoricalReplay(
        runtime: runtime,
        clock: clock,
        quotes: quotes,
        rangeLabel: range.label,
        beforeDecision:
            runtime.strategies.any(
              (setting) =>
                  setting.enabled && setting.strategyId == 'lm_selector',
            )
            ? (interval, engine, bar) async {
                runtime.runStatus =
                    'Historical replay waiting for LM Studio at '
                    '${MountainTime.format(bar.time)}; Stop cancels.';
                await _requestLmSelection(
                  run,
                  runtime,
                  interval,
                  engine,
                  bar,
                  beforeEvaluation: true,
                );
              }
            : null,
      );
      run.replay = replay;
      await replay.run();
    } catch (error) {
      if (!identical(run.runtime, runtime)) return;
      runtime
        ..running = false
        ..runStatus =
            'Historical replay failed: ${switch (error) {
              SchwabAuthorizationException(:final message) => message,
              StateError(:final message) => message,
              _ => error.toString(),
            }}';
      _lastError = runtime.runStatus;
    }
  }

  void _startRun() {
    if (_runtime != null || _savedEngineCheckpoints.isNotEmpty) {
      throw StateError(
        'This simulation already has run data. Create a new simulation '
        'instead of overwriting it.',
      );
    }
    if (_runtime?.running == true && _historicalMode) {
      throw StateError('Stop the historical replay before starting live.');
    }
    _replay = null;
    _historicalMode = false;
    if (_feedState != FeedState.live) {
      throw StateError(
        'Connect Schwab and verify the live stream before starting.',
      );
    }
    _selectedRun.historicalRange = null;
    final settings = (_settings['strategies'] as List<dynamic>).map((row) {
      final item = row as Map<String, dynamic>;
      return StrategySettings(
        strategyId: item['strategyId'] as String,
        label: item['label'] as String,
        enabled: item['enabled'] == true,
        intervalMinutes: item['intervalMinutes'] as int? ?? 1,
        startingCash: (item['startingCash'] as num?)?.toDouble(),
        parameters: (item['parameters'] as Map<String, dynamic>).map(
          (key, value) => MapEntry(key, (value as num).toDouble()),
        ),
      );
    }).toList();
    final run = _selectedRun;
    run.startedAt = _clock().toUtc();
    final candidates = _training.pinCandidates();
    for (final id in ['neural_network', 'logistic_regression']) {
      run.pinnedModels[id] = PinnedModelStrategy(
        id: id,
        model: candidates[id],
        parameters: StrategyRegistry.byId(id).parameters,
      );
    }
    _runtime = _createRuntime(settings, run: run)..setConnected(true);
    _runtime!.begin();
    _syncTrainingActivity();
  }

  void _prepareRuntime(_BackendRun run) {
    final settings = _buildStrategySettings(run);
    final runtime = _createRuntime(settings, run: run);
    if (run.savedEngineCheckpoints.isNotEmpty) {
      runtime.engines.clear();
      for (final entry in run.savedEngineCheckpoints.entries) {
        final interval = int.parse(entry.key);
        final strategySettings = settings
            .where((setting) => setting.intervalMinutes == interval)
            .toList();
        final checkpoint = entry.value as Map<String, dynamic>;
        final engine = SimulatorEngine.restore(
          watchlist: runtime.watchlist,
          strategies: strategySettings,
          startingCash: runtime.startingCash,
          checkpoint: checkpoint,
          strategyOverrides: _strategyOverrides(run),
        );
        if (run.resumeOnConnection) {
          for (final symbol in runtime.watchlist) {
            engine.resetSymbolWarmup(symbol);
          }
        }
        runtime.engines[interval] = engine;
      }
    }
    run.runtime = runtime;
  }

  Map<String, Object?>? _tuningProgress;

  /// Replays the run's collected candles through candidate parameters in a
  /// background isolate. Nothing is saved; the caller creates a new run.
  Future<Map<String, Object?>> _tuneRun(
    _BackendRun run, {
    bool? enableShortSelling,
    String? requestId,
    int generations = 2,
  }) async {
    if (generations < 0 || generations > maxTuningGenerations) {
      throw ArgumentError('Choose 0 to $maxTuningGenerations generations.');
    }
    if (_tuningProgress != null) {
      throw StateError('Strategy tuning is already in progress.');
    }
    final engines = run.runtime?.engines ?? const <int, SimulatorEngine>{};
    final candles = <int, Map<String, List<Candle>>>{
      for (final entry in engines.entries)
        entry.key: {
          for (final symbol in entry.value.candles.entries)
            symbol.key: List<Candle>.of(symbol.value),
        },
    };
    final barCounts = <String, int>{
      for (final entry in candles.entries)
        '${entry.key}': entry.value.values.fold<int>(
          0,
          (most, bars) => math.max(most, bars.length),
        ),
    };
    final settings =
        jsonDecode(jsonEncode(run.settings)) as Map<String, dynamic>;
    if (enableShortSelling != null) {
      (settings['risk'] as Map<String, dynamic>)['enableShortSelling'] =
          enableShortSelling;
    }
    final tuner = StrategyTuner(
      candlesByInterval: candles,
      watchlist: (settings['watchlist'] as List<dynamic>)
          .map((item) => item.toString())
          .toList(),
      strategies: _buildStrategySettings(run),
      risk: TuningRisk.fromSettings(settings),
      generations: generations,
    );
    final progress = <String, Object?>{'requestId': requestId};
    _tuningProgress = progress;
    final updates = ReceivePort();
    updates.listen((message) {
      final update = message as TuningProgress;
      progress['fraction'] = update.fraction;
      progress['remainingSeconds'] = update.remainingSeconds;
    });
    try {
      final results = await _tuneInIsolate(
        tuner,
        updates.sendPort,
        List.of(_algorithms.definitions),
      );
      return {
        'runId': run.id,
        'runName': run.name,
        'barsByInterval': barCounts,
        'enableShortSelling':
            (settings['risk'] as Map<String, dynamic>)['enableShortSelling'] ==
            true,
        'results': results,
        'note':
            'Tuning replays this run\'s collected candles with bar-based fills. '
            'A candidate must beat the current settings and close at least '
            'two trades in each of the three periods.',
      };
    } finally {
      updates.close();
      _tuningProgress = null;
    }
  }

  List<StrategySettings> _buildStrategySettings(_BackendRun run) =>
      (run.settings['strategies'] as List<dynamic>).map((row) {
        final item = row as Map<String, dynamic>;
        return StrategySettings(
          strategyId: item['strategyId'] as String,
          label: item['label'] as String,
          enabled: item['enabled'] == true,
          intervalMinutes: item['intervalMinutes'] as int? ?? 1,
          startingCash: (item['startingCash'] as num?)?.toDouble(),
          parameters: (item['parameters'] as Map<String, dynamic>).map(
            (key, value) => MapEntry(key, (value as num).toDouble()),
          ),
        );
      }).toList();

  LiveSimulationRuntime _createRuntime(
    List<StrategySettings> settings, {
    required _BackendRun run,
    DateTime Function()? clock,
  }) {
    _cancelLmRequests(run);
    run.lmCancellation = Completer<void>();
    run.lmSelectorStatus.clear();
    final risk = run.settings['risk'] as Map<String, dynamic>;
    final selector = LmStudioSelectorStrategy();
    run.lmSelector = selector;
    return LiveSimulationRuntime(
      clock: clock ?? _clock,
      watchlist: (run.settings['watchlist'] as List<dynamic>)
          .map((item) => item.toString())
          .toList(),
      strategies: settings,
      benchmarks: BenchmarkSettings.fromJson(
        run.settings['benchmarks'] as Map<String, dynamic>?,
      ),
      startingCash: (run.settings['startingCash'] as num).toDouble(),
      positionSizeFraction: (risk['positionSizeFraction'] as num).toDouble(),
      maxExposureFraction: (risk['maxExposureFraction'] as num).toDouble(),
      dailyLossLimitFraction: (risk['dailyLossLimitFraction'] as num)
          .toDouble(),
      riskFraction: (risk['riskFraction'] as num).toDouble(),
      defaultRiskPerShareFraction: (risk['defaultRiskPerShareFraction'] as num)
          .toDouble(),
      defaultTargetFraction: (risk['defaultTargetFraction'] as num).toDouble(),
      spreadBps: (risk['spreadBps'] as num).toDouble(),
      slippageBps: (risk['slippageBps'] as num).toDouble(),
      feePerShare: (risk['feePerShare'] as num).toDouble(),
      allowOvernight: risk['allowOvernight'] as bool,
      enableShortSelling: risk['enableShortSelling'] as bool? ?? false,
      sessionClosePolicyEnabled:
          risk['sessionClosePolicyEnabled'] as bool? ?? false,
      strategyOverrides: _strategyOverrides(run),
    );
  }

  Map<String, TradingStrategy> _strategyOverrides(_BackendRun run) => {
    if (run.lmSelector != null) 'lm_selector': run.lmSelector!,
    for (final id in ['neural_network', 'logistic_regression'])
      id:
          run.pinnedModels[id] ??
          PinnedModelStrategy(
            id: id,
            model: null,
            parameters: StrategyRegistry.byId(id).parameters,
          ),
  };

  void _syncTrainingActivity() {
    final active = _runs.values.any(
      (run) => !run.historicalMode && run.runtime?.running == true,
    );
    if (active && _training.status['active'] != true) {
      _training.startRun(_clock());
      _trainingBuilders.clear();
    } else if (!active && _training.status['active'] == true) {
      _training.stopRun();
      _trainingBuilders.clear();
    }
  }

  Future<void> _trainAndPersist() async {
    await _training.train();
    await _persist();
  }

  void _collectTrainingQuote(LiveQuote quote) {
    if (UsEquityCalendar.sessionAt(quote.time) == null) return;
    final builder = _trainingBuilders.putIfAbsent(
      quote.symbol,
      () => SessionCandleBuilder(
        symbol: quote.symbol,
        intervalMinutes: _training.intervalMinutes,
      ),
    );
    final candle = builder.add(quote);
    if (builder.gapDetected) _training.invalidateSymbol(quote.symbol);
    if (candle != null) _training.onCandle(candle);
  }

  void _handleQuote(LiveQuote quote) {
    var changed = false;
    for (final run in _runs.values) {
      final runtime = run.runtime;
      if (runtime == null || run.historicalMode) continue;
      final previousTimes = {
        for (final entry in runtime.engines.entries)
          entry.key: entry.value.candles[quote.symbol]?.lastOrNull?.time,
      };
      if (!runtime.onQuote(quote)) continue;
      changed = true;
      for (final entry in runtime.engines.entries) {
        final bars = entry.value.candles[quote.symbol];
        if (bars == null ||
            bars.isEmpty ||
            bars.last.time == previousTimes[entry.key]) {
          continue;
        }
        unawaited(
          _requestLmSelection(run, runtime, entry.key, entry.value, bars.last),
        );
      }
    }
    if (changed) {
      _collectTrainingQuote(quote);
      unawaited(_persist());
    }
  }

  Future<void> _requestLmSelection(
    _BackendRun run,
    LiveSimulationRuntime runtime,
    int interval,
    SimulatorEngine engine,
    Candle bar, {
    bool beforeEvaluation = false,
  }) {
    final requests = <Future<void>>[];
    final cancellation = run.lmCancellation;
    final selectorInstances = runtime.strategies.where(
      (setting) =>
          setting.enabled &&
          setting.strategyId == 'lm_selector' &&
          setting.intervalMinutes == interval,
    );
    for (final setting in selectorInstances) {
      final bars = [...?engine.candles[bar.symbol], if (beforeEvaluation) bar];
      if (bars.length < StrategyRegistry.byId('lm_selector').warmupBars) {
        continue;
      }
      final key = (setting.label, bar.symbol);
      if (run.pendingLmSelections.containsKey(key)) continue;
      final client = _lmClient(waitForResponse: run.historicalMode);
      run.pendingLmSelections[key] = client;
      final requestedAt = bar.time;
      final eligibleIds = StrategyRegistry.all
          .map((strategy) => strategy.id)
          .where(
            (id) => !const {
              'lm_selector',
              'neural_network',
              'logistic_regression',
            }.contains(id),
          )
          .toSet();
      final snapshot = <String, Object?>{
        'currentSymbol': bar.symbol,
        'intervalMinutes': interval,
        'candles': [
          for (final candle in bars.takeLast(30))
            {
              'time': candle.time.toIso8601String(),
              'open': candle.open,
              'high': candle.high,
              'low': candle.low,
              'close': candle.close,
              'volume': candle.volume,
            },
        ],
        'watchlist': engine.watchlist.take(20).toList(),
      };
      run.lmSelectorStatus[setting.label] = 'Selecting';
      requests.add(() async {
        final stopwatch = Stopwatch()..start();
        try {
          final selection = await client.selectStrategy(
            eligibleStrategyIds: eligibleIds,
            snapshot: snapshot,
          );
          stopwatch.stop();
          if (!identical(run.runtime, runtime) ||
              !runtime.running ||
              cancellation.isCompleted) {
            return;
          }
          final latestTime = engine.candles[bar.symbol]?.last.time;
          final tooLate =
              !run.historicalMode &&
              latestTime != null &&
              latestTime.isAfter(
                requestedAt.add(Duration(minutes: interval * 2)),
              );
          if (tooLate) {
            run.lmSelector?.clearSelection(setting.label, bar.symbol);
            _recordLmDecision(
              run,
              engine,
              setting.label,
              bar,
              'LM Studio response expired before the next decision candle.',
              stopwatch.elapsedMilliseconds,
              selection.toolName,
            );
            run.lmSelectorStatus[setting.label] =
                'Expired; waiting for next response';
            unawaited(_persist());
            return;
          }
          run.lmSelector?.setSelection(setting.label, bar.symbol, selection);
          final choice = selection.strategyId == null
              ? 'WAIT'
              : selection.strategyId!;
          _recordLmDecision(
            run,
            engine,
            setting.label,
            bar,
            'LM Studio model ${_lmSettings['model']} chose $choice via '
            '${selection.toolName}: ${selection.reason}',
            stopwatch.elapsedMilliseconds,
            selection.toolName,
          );
          run.lmSelectorStatus[setting.label] = choice;
          unawaited(_persist());
        } catch (error) {
          stopwatch.stop();
          if (!identical(run.runtime, runtime) ||
              !runtime.running ||
              cancellation.isCompleted) {
            return;
          }
          run.lmSelector?.clearSelection(setting.label, bar.symbol);
          _recordLmDecision(
            run,
            engine,
            setting.label,
            bar,
            'LM Studio unavailable or returned an invalid choice; WAIT. $error',
            stopwatch.elapsedMilliseconds,
            'error',
          );
          run.lmSelectorStatus[setting.label] = 'WAIT: ${error.runtimeType}';
          unawaited(_persist());
        } finally {
          client.close();
          if (identical(run.pendingLmSelections[key], client)) {
            run.pendingLmSelections.remove(key);
          }
        }
      }());
    }
    final completed = Future.wait(requests).then((_) {});
    if (!beforeEvaluation || requests.isEmpty) return completed;
    final cancelled = Completer<void>();
    run.pendingLmWait = cancelled;
    return Future.any<void>([completed, cancelled.future]).whenComplete(() {
      if (identical(run.pendingLmWait, cancelled)) run.pendingLmWait = null;
    });
  }

  void _cancelLmRequests(_BackendRun run) {
    if (!run.lmCancellation.isCompleted) run.lmCancellation.complete();
    final waiting = run.pendingLmWait;
    if (waiting != null && !waiting.isCompleted) waiting.complete();
    for (final client in run.pendingLmSelections.values) {
      client.close();
    }
    run.pendingLmSelections.clear();
  }

  void _recordLmDecision(
    _BackendRun run,
    SimulatorEngine engine,
    String label,
    Candle bar,
    String reason,
    int latencyMilliseconds,
    String toolName,
  ) {
    final account = engine.accounts[label];
    if (account == null) return;
    account.events.add(
      DecisionEvent(
        strategy: label,
        symbol: bar.symbol,
        time: run.historicalMode ? bar.time : _clock().toUtc(),
        action: TradeAction.wait,
        kind: 'model',
        reason: '$reason Tool call: $toolName.',
        price: bar.close,
        measurements: {'latencyMs': latencyMilliseconds.toDouble()},
      ),
    );
  }

  LmStudioClient _lmClient({bool waitForResponse = false}) => LmStudioClient(
    baseUrl: _lmSettings['url']!,
    model: _lmSettings['model']!,
    timeout: waitForResponse ? null : const Duration(seconds: 15),
  );

  Future<File> get _stateFile async {
    final root = _dataRoot;
    await root.create(recursive: true);
    return File('${root.path}\\state.json');
  }

  Directory get _dataRoot =>
      dataDirectory ??
      Directory(
        '${Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path}'
        r'\ATrader',
      );

  Future<void> _loadSettings() async {
    _selectedRun;
    try {
      final file = await _stateFile;
      final backup = File('${file.path}.bak');
      if (!await file.exists() && !await backup.exists()) return;
      Map<String, dynamic>? restored;
      Object? failure;
      for (final source in [file, backup]) {
        if (!await source.exists()) continue;
        try {
          final decoded = await Isolate.run(
            () => jsonDecode(source.readAsStringSync()),
          );
          if (decoded is! Map<String, dynamic> ||
              decoded['settings'] is! Map<String, dynamic>) {
            throw const FormatException('Saved state is not a run checkpoint.');
          }
          restored = decoded;
          break;
        } on FormatException catch (error) {
          failure = error;
        }
      }
      if (restored == null) {
        throw StateError('Cannot read saved state: $failure');
      }
      final savedRuns = restored['runs'];
      await _algorithms.restore(
        (restored['algorithms'] as List? ?? []).cast<Map<String, dynamic>>(),
      );
      final recovered = <String, _BackendRun>{};
      if (savedRuns is List) {
        for (final value in savedRuns) {
          final saved = _checkpointArchives.referenceRun(
            value as Map<String, dynamic>,
          );
          final id = saved['id'] as String;
          if (recovered.containsKey(id)) {
            throw const FormatException(
              'Saved simulations have duplicate IDs.',
            );
          }
          recovered[id] = _restoreRun(saved, id, saved['name'] as String);
          await _seedCandleCache(recovered[id]!.researchSession);
        }
      } else {
        recovered['run-1'] = _restoreRun(restored, 'run-1', 'Simulation 1');
        _legacyCheckpoint = jsonEncode(restored);
      }
      if (recovered.isEmpty) {
        throw const FormatException('No saved simulations.');
      }
      _runs
        ..clear()
        ..addAll(recovered);
      final selected = restored['selectedRunId']?.toString();
      _selectedRunId = recovered.containsKey(selected)
          ? selected!
          : recovered.keys.first;
      _nextRunNumber =
          (restored['nextRunNumber'] as num?)?.toInt() ??
          recovered.keys
                  .map((id) => int.tryParse(id.replaceFirst('run-', '')) ?? 1)
                  .fold(1, math.max) +
              1;
      final lm = restored['lmStudio'] as Map<String, dynamic>?;
      if (lm != null) {
        _lmSettings
          ..['url'] = lm['url']?.toString() ?? _lmSettings['url']!
          ..['model'] = lm['model']?.toString() ?? '';
      }
      final training = restored['training'] as Map<String, dynamic>?;
      if (training != null) {
        _training = LiveModelTraining.fromJson(training)..stopRun();
      }
    } catch (error) {
      _persistenceBlocked = true;
      _lastError = 'Saved run configuration could not be loaded: $error';
    }
  }

  _BackendRun _restoreRun(Map<String, dynamic> saved, String id, String name) {
    final settings = _defaultSettings();
    final configuration = saved['settings'] as Map<String, dynamic>;
    final savedRisk = configuration['risk'] as Map<String, dynamic>?;
    final mergedRisk = {
      ...settings['risk'] as Map<String, dynamic>,
      ...?savedRisk,
    };
    settings
      ..addAll(configuration)
      ..['risk'] = mergedRisk;
    final runtime = saved['runtime'] as Map<String, dynamic>?;
    final run = _BackendRun(id: id, name: name, settings: settings)
      ..savedEngineCheckpoints =
          runtime?['engines'] as Map<String, dynamic>? ?? {}
      ..resumeOnConnection = runtime?['running'] == true
      ..startedAt = DateTime.tryParse(saved['startedAt']?.toString() ?? '');
    run.historicalMode = saved['runMode'] == 'historical';
    if (run.historicalMode) run.resumeOnConnection = false;
    run.researchSession = saved['researchSession'] as Map<String, dynamic>?;
    run.researchPreview = saved['researchPreviewData'] as Map<String, dynamic>?;
    run.generationResults = List<Object>.of(
      (saved['generationResults'] as List? ?? []).cast<Object>(),
    );
    run.trainingArchive.addAll(
      (saved['trainingArchive'] as List? ?? []).cast<Object>(),
    );
    for (final entry in (saved['strategyBests'] as Map? ?? const {}).entries) {
      run.strategyBests[entry.key as String] = Map<String, dynamic>.from(
        entry.value as Map,
      );
    }
    if (saved['generationEquity'] case final Map history) {
      run.generationEquity = {
        for (final entry in history.entries)
          entry.key as String: [
            for (final point in (entry.value as List).cast<Map>())
              point.map((key, value) => MapEntry(key as String, value as num)),
          ],
      };
    }
    if (saved['historicalRange'] case {
      'startUtc': final String start,
      'endUtc': final String end,
      'label': final String label,
    }) {
      final startUtc = DateTime.tryParse(start)?.toUtc();
      final endUtc = DateTime.tryParse(end)?.toUtc();
      if (startUtc != null && endUtc != null && endUtc.isAfter(startUtc)) {
        run.historicalRange = (
          startUtc: startUtc,
          endUtc: endUtc,
          label: label,
        );
      }
    }
    final models = saved['pinnedModels'] as Map<String, dynamic>? ?? {};
    for (final entry in models.entries) {
      run.pinnedModels[entry.key] = PinnedModelStrategy.fromJson(
        entry.value as Map<String, dynamic>,
        parameters: StrategyRegistry.byId(entry.key).parameters,
      );
    }
    return run;
  }

  Future<void> _seedCandleCache(Map<String, dynamic>? session) async {
    final history = session?['history'] as Map?;
    if (history == null) return;
    for (final entry in history.entries) {
      final symbol = entry.key as String;
      final bars = [
        for (final raw in (entry.value as List).cast<Map>())
          MinuteBar(
            symbol: symbol,
            openTime: DateTime.parse(raw['time'] as String),
            open: (raw['open'] as num).toDouble(),
            high: (raw['high'] as num).toDouble(),
            low: (raw['low'] as num).toDouble(),
            close: (raw['close'] as num).toDouble(),
            volume: (raw['volume'] as num).toDouble(),
          ),
      ];
      await _historyCache.remember(symbol, bars);
    }
  }

  Future<void> _persist({
    bool requireSuccess = false,
    String failureMessage =
        'Changes are in memory but could not be saved. '
        'They may be lost after a restart.',
  }) {
    _persistenceRequested = true;
    final next = _pendingPersistence ??= _drainPersistence().whenComplete(() {
      _pendingPersistence = null;
    });
    return next.then((success) {
      if (requireSuccess && !success) {
        throw StateError('$failureMessage $_lastError');
      }
    });
  }

  Future<bool> _drainPersistence() async {
    var success = true;
    while (_persistenceRequested) {
      _persistenceRequested = false;
      success = await _writeState();
      if (!success) break;
    }
    return success;
  }

  Future<bool> _writeState() async {
    try {
      if (_persistenceBlocked) {
        throw StateError('Saving is blocked to protect unreadable saved data.');
      }
      final file = await _stateFile;
      final legacyCheckpoint = _legacyCheckpoint;
      if (legacyCheckpoint != null) {
        final legacyBackup = File(
          '${file.parent.path}${Platform.pathSeparator}state-before-multi-run.json',
        );
        if (!await legacyBackup.exists()) {
          await legacyBackup.writeAsString(legacyCheckpoint, flush: true);
        }
        _legacyCheckpoint = null;
      }
      final payload = {
        'schemaVersion': 2,
        'algorithms': _algorithms.definitions,
        'selectedRunId': _selectedRunId,
        'nextRunNumber': _nextRunNumber,
        'training': _training.checkpoint(),
        'runs': [
          for (final run in _runs.values.toList())
            await _checkpointArchives.packRun(_exportRun(run)),
        ],
        'settings': _selectedSavedRun.settings,
        'lmStudio': _lmSettings,
        'savedAt': DateTime.now().toUtc().toIso8601String(),
        'runtime': _runtimeCheckpoint(_selectedSavedRun),
      };
      final temporary = File('${file.path}.tmp');
      final backup = File('${file.path}.bak');
      final encoded = await Isolate.run(() => jsonEncode(payload));
      await temporary.writeAsString(encoded, flush: true);
      if (await file.exists()) {
        if (await backup.exists()) await backup.delete();
        await file.rename(backup.path);
      }
      try {
        await temporary.rename(file.path);
      } catch (_) {
        if (!await file.exists() && await backup.exists()) {
          await backup.rename(file.path);
        }
        rethrow;
      }
      if (await backup.exists()) await backup.delete();
      for (final run in _runs.values) {
        run.generationResults = run.generationResults
            .map(_checkpointArchives.compact)
            .toList();
        for (var i = 0; i < run.trainingArchive.length; i++) {
          run.trainingArchive[i] = _checkpointArchives.compact(
            run.trainingArchive[i],
          );
        }
      }
      for (var i = 0; i < _generationExports.length; i++) {
        _generationExports[i] = _checkpointArchives.compact(
          _generationExports[i],
        );
      }
      return true;
    } catch (error) {
      _lastError = 'Simulator state could not be persisted: $error';
      return false;
    }
  }

  Map<String, Object?> _runtimeCheckpoint(_BackendRun run) => {
    'running': run.historicalMode
        ? false
        : run.runtime?.running ?? run.resumeOnConnection,
    'feedState': _feedState.name,
    'engines':
        run.runtime?.engines.map(
          (interval, engine) => MapEntry('$interval', engine.checkpoint()),
        ) ??
        (run.savedEngineCheckpoints.isEmpty
            ? null
            : run.savedEngineCheckpoints),
  };
}

/// Mutable state belonging to one simulation; market data and credentials are
/// shared, but execution, model selections, settings and checkpoints are not.
class _BackendRun {
  _BackendRun({required this.id, required this.name, required this.settings});
  final String id;
  String name;
  final Map<String, Object?> settings;
  LiveSimulationRuntime? runtime;
  HistoricalReplay? replay;
  Map<String, dynamic>? researchSession;
  Map<String, dynamic>? researchPreview;
  List<Object> generationResults = [];
  final strategyBests = <String, Map<String, dynamic>>{};
  final trainingArchive = <Object>[];
  Map<String, List<Map<String, num>>>? generationEquity;
  HistoricalRange? historicalRange;
  bool historicalMode = false;
  bool resumeOnConnection = false;
  Map<String, dynamic> savedEngineCheckpoints = {};
  final Map<(String, String), LmStudioClient> pendingLmSelections = {};
  Completer<void> lmCancellation = Completer<void>();
  Completer<void>? pendingLmWait;
  final Map<String, String> lmSelectorStatus = {};
  LmStudioSelectorStrategy? lmSelector;
  DateTime? startedAt;
  final Map<String, PinnedModelStrategy> pinnedModels = {};
}

extension on List<DecisionEvent> {
  List<DecisionEvent> sortedNewestFirst() =>
      this..sort((a, b) => b.time.compareTo(a.time));
}

extension<T> on Iterable<T> {
  Iterable<T> takeLast(int count) {
    final values = toList();
    return values.skip(values.length > count ? values.length - count : 0);
  }
}
