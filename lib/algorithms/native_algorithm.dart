import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../strategy_api.dart';
import 'imported_definition.dart';
import 'native_algorithm_protocol.dart';
import 'native_algorithm_events.dart';
import 'native_algorithm_progress.dart';

/// A compiled Dart algorithm runs in a persistent local worker. File messages
/// let the synchronous simulator retain its existing decision/fill ordering.
class NativeAlgorithm extends ImportedAlgorithmDefinition
    implements
        BatchTradingStrategy,
        StrategyExecutionHealth,
        CandidateReplayStrategy {
  NativeAlgorithm._(super.json, this._worker) : super.fromJson();
  final NativeAlgorithmWorker _worker;
  final _market = AlgorithmMarketEncoder();
  @override
  String? executionError;
  int get workerRequestCount => _worker.requestCount;

  static Future<NativeAlgorithm> open(Map<String, dynamic> definition) async {
    final worker = await NativeAlgorithmWorker.start(
      definition['executable'] as String,
    );
    try {
      final algorithm = NativeAlgorithm._(worker.metadata, worker);
      if (worker.metadata['protocolVersion'] !=
          nativeAlgorithmProtocolVersion) {
        throw StateError(
          'The Dart worker needs a protocol upgrade. Restart the backend to recompile it.',
        );
      }
      if (definition['metadata'] case final Map expected) {
        if (jsonEncode(algorithm.toJson()) !=
            jsonEncode(
              ImportedAlgorithmDefinition.fromJson(
                Map<String, dynamic>.from(expected),
              ).toJson(),
            )) {
          throw const FormatException(
            'Compiled Dart algorithm metadata changed. Import the edited file with a new id.',
          );
        }
      }
      return algorithm;
    } catch (_) {
      await worker.close();
      rethrow;
    }
  }

  Future<void> close() => _worker.close();

  @override
  Map<String, dynamic> replayCandidates({
    required Map<String, Object?> checkpoint,
    required List<Map<String, Object?>> strategies,
    required List<Candle> bars,
    required List<DateTime> cuts,
    bool retainEvents = false,
    bool retainFills = false,
    void Function(int)? onProgress,
  }) {
    try {
      final result = _worker.evaluate(
        {
          'operation': 'replay',
          'retainEvents': retainEvents,
          'retainFills': retainFills,
          'checkpoint': checkpoint,
          'strategies': strategies,
          'bars': bars.map(encodeAlgorithmCandle).toList(),
          'cuts': cuts.map((cut) => cut.toIso8601String()).toList(),
        },
        timeout: const Duration(minutes: 2),
        onProgress: onProgress,
      );
      if (result['error'] != null) {
        throw NativeAlgorithmWorkerFailure(result['error'].toString());
      }
      return result;
    } catch (error) {
      executionError ??= error.toString();
      throw StateError('$name replay failed: $error');
    }
  }

  @override
  StrategySignal evaluate(StrategyContext context) {
    return evaluateBatch([context]).single;
  }

  @override
  List<StrategySignal> evaluateBatch(List<StrategyContext> contexts) {
    if (contexts.isEmpty) return [];
    final first = contexts.first;
    if (contexts.any(
      (context) =>
          context.executionId != first.executionId ||
          context.current.key != first.current.key,
    )) {
      return [for (final context in contexts) evaluate(context)];
    }
    try {
      final raw = _worker.evaluate({
        'market': _market.encode(first),
        'contexts': [
          for (final context in contexts)
            {
              'hasPosition': context.hasPosition,
              'entryPrice': context.entryPrice,
              'positionStop': context.positionStop,
              'positionSide': context.positionSide.name,
              'parameters': context.parameters,
              'intervalMinutes': context.intervalMinutes,
              'sessionElapsedMinutes': context.sessionElapsedMinutes,
              'sessionLengthMinutes': context.sessionLengthMinutes,
              'barsHeld': context.barsHeld,
              'portfolioLabel': context.portfolioLabel,
              'executionId': context.executionId,
            },
        ],
      });
      if (raw['error'] != null) {
        throw NativeAlgorithmWorkerFailure(raw['error'].toString());
      }
      final signals = raw['signals'] as List;
      if (signals.length != contexts.length) {
        throw NativeAlgorithmWorkerFailure(
          'Dart worker returned an incomplete batch.',
        );
      }
      return [
        for (final signal in signals)
          _signal(Map<String, dynamic>.from(signal as Map)),
      ];
    } on Object catch (error) {
      if (error is NativeAlgorithmWorkerFailure) {
        executionError ??= error.toString();
      }
      return [
        for (final _ in contexts)
          StrategySignal(TradeAction.wait, 'Dart algorithm $id: $error'),
      ];
    }
  }

  StrategySignal _signal(Map<String, dynamic> raw) {
    try {
      if (raw['error'] != null) throw StateError(raw['error'].toString());
      double? price(String key) {
        final value = raw[key];
        if (value == null) return null;
        if (value is! num || !value.isFinite || value <= 0) {
          throw FormatException('Invalid $key price.');
        }
        return value.toDouble();
      }

      Map<String, double> numbers(Object? value) => {
        for (final entry in (value as Map? ?? {}).entries)
          entry.key as String: _finite(entry.value),
      };
      return StrategySignal(
        TradeAction.values.byName(raw['action'] as String),
        raw['reason'] as String,
        side: PositionSide.values.byName(raw['side'] as String),
        positionEffect: raw['positionEffect'] == null
            ? null
            : PositionEffect.values.byName(raw['positionEffect'] as String),
        stop: price('stop'),
        target: price('target'),
        measurements: numbers(raw['measurements']),
        sourceStrategyId: raw['sourceStrategyId'] as String?,
        sourceStrategyParameters: numbers(raw['sourceStrategyParameters']),
      );
    } on Object catch (error) {
      return StrategySignal(TradeAction.wait, 'Dart algorithm $id: $error');
    }
  }

  static double _finite(Object? value) {
    if (value is! num || !value.isFinite) {
      throw const FormatException('Algorithm returned a nonfinite number.');
    }
    return value.toDouble();
  }
}

class NativeAlgorithmWorkerFailure implements Exception {
  NativeAlgorithmWorkerFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Wait for the worker's atomically published startup message. Windows can
/// briefly lock the file even after it has appeared in the directory.
Future<Map<String, dynamic>> readNativeAlgorithmReady(
  File ready, {
  Duration timeout = const Duration(seconds: 10),
  String Function()? diagnostics,
}) async {
  final timer = Stopwatch()..start();
  FileSystemException? lastLock;
  while (true) {
    try {
      return jsonDecode(await ready.readAsString()) as Map<String, dynamic>;
    } on PathNotFoundException {
      // The worker has not published its metadata yet.
    } on FileSystemException catch (error) {
      if (!Platform.isWindows ||
          !const {32, 33}.contains(error.osError?.errorCode)) {
        rethrow;
      }
      lastLock = error;
    }
    if (timer.elapsed >= timeout) {
      throw NativeAlgorithmWorkerFailure(
        [
          'Dart algorithm did not start.',
          if (lastLock != null) 'Startup file stayed locked: $lastLock',
          if (diagnostics?.call() case final String output
              when output.isNotEmpty)
            output,
        ].join(' '),
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class NativeAlgorithmWorker {
  NativeAlgorithmWorker._(this._directory, this._process, this._notifications);
  final Directory _directory;
  final Process _process;
  final NativeAlgorithmEvents _notifications;
  late final _progress = NativeAlgorithmProgress(_directory);
  late final Map<String, dynamic> metadata;
  bool _closed = false;
  String _diagnostics = '';
  int _sequence = 0;
  int get requestCount => _sequence;

  static Future<NativeAlgorithmWorker> start(String executable) async {
    final directory = await Directory.systemTemp.createTemp(
      'atrader-algorithm-',
    );
    NativeAlgorithmWorker? worker;
    final notifications = NativeAlgorithmEvents(directory.path);
    try {
      final process = await Process.start(executable, [
        directory.path,
      ], workingDirectory: File(executable).parent.path);
      worker = NativeAlgorithmWorker._(directory, process, notifications);
      void output(List<int> bytes) {
        worker!._diagnostics += utf8.decode(bytes, allowMalformed: true);
        if (worker._diagnostics.length > 4000) {
          worker._diagnostics = worker._diagnostics.substring(
            worker._diagnostics.length - 4000,
          );
        }
      }

      process.stdout.listen(output);
      process.stderr.listen(output);
      final raw = await readNativeAlgorithmReady(
        File('${directory.path}/ready.json'),
        diagnostics: () => worker!._diagnostics,
      );
      if (raw['error'] != null) throw StateError(raw['error'].toString());
      worker.metadata = raw;
      return worker;
    } catch (_) {
      if (worker != null) {
        await worker.close();
      } else {
        notifications.close();
        await directory.delete(recursive: true);
      }
      rethrow;
    }
  }

  Map<String, dynamic> evaluate(
    Map<String, Object?> context, {
    Duration timeout = const Duration(seconds: 5),
    void Function(int)? onProgress,
  }) {
    try {
      return _communicate(context, timeout, onProgress);
    } catch (error) {
      _closed = true;
      _process.kill();
      if (error is NativeAlgorithmWorkerFailure) rethrow;
      throw NativeAlgorithmWorkerFailure(
        'Dart worker communication failed: $error',
      );
    }
  }

  Map<String, dynamic> _communicate(
    Map<String, Object?> context,
    Duration timeout,
    void Function(int)? onProgress,
  ) {
    if (_closed) {
      throw NativeAlgorithmWorkerFailure(
        'Worker stopped after an error. Reopen the backend to restart it.',
      );
    }
    final sequence = ++_sequence;
    final request = File('${_directory.path}/request.json');
    final temporary = File('${request.path}.tmp');
    final response = File('${_directory.path}/response.json');
    temporary.writeAsStringSync(
      jsonEncode({'sequence': sequence, 'context': context}),
    );
    temporary.renameSync(request.path);
    _notifications.requestReady();
    final timer = Stopwatch()..start();
    while (!response.existsSync()) {
      if (timer.elapsed > timeout) {
        _closed = true;
        _process.kill();
        throw NativeAlgorithmWorkerFailure(
          'Dart worker request exceeded ${timeout.inSeconds} seconds; worker stopped. No generation results were accepted.',
        );
      }
      if (_notifications.enabled) {
        _notifications.waitForResponse(const Duration(milliseconds: 100));
      } else {
        sleep(const Duration(milliseconds: 1));
      }
      if (onProgress != null) {
        final completed = _progress.readLatest(sequence);
        if (completed != null) onProgress(completed);
      }
    }
    final result =
        jsonDecode(response.readAsStringSync()) as Map<String, dynamic>;
    response.deleteSync();
    if (result['sequence'] != sequence) {
      throw NativeAlgorithmWorkerFailure(
        'Worker returned an out-of-order decision.',
      );
    }
    return result['signal'] as Map<String, dynamic>;
  }

  Future<void> close() async {
    _closed = true;
    _process.kill();
    await _process.exitCode.timeout(
      const Duration(seconds: 2),
      onTimeout: () => -1,
    );
    _notifications.close();
    if (await _directory.exists()) await _directory.delete(recursive: true);
  }
}

/// Compile only the selected algorithm and its bundled simulator SDK.
Future<String> compileDartAlgorithm(String source, Directory workspace) async {
  final classes = RegExp(
    r'class\s+(\w+)\s+(?:extends\s+BuiltinStrategy|implements\s+TradingStrategy)\b',
  ).allMatches(source).toList();
  if (classes.length != 1) {
    throw const FormatException(
      'The Dart file must define one class implementing TradingStrategy or extending BuiltinStrategy, with a no-argument constructor. Start from the Dart template.',
    );
  }
  final sdk = _findAlgorithmSdk();
  await workspace.create(recursive: true);
  final lib = Directory('${workspace.path}/lib');
  await lib.create();
  for (final name in [
    'strategy_api.dart',
    'simulator.dart',
    'exchange_calendar.dart',
    'training.dart',
  ]) {
    await File('${sdk.path}/$name').copy('${lib.path}/$name');
  }
  final algorithmDir = Directory('${lib.path}/algorithms');
  await algorithmDir.create();
  await for (final entity in Directory('${sdk.path}/algorithms').list()) {
    // Native worker/library managers use dart:io and are not part of the SDK.
    if (entity is File &&
        entity.path.endsWith('.dart') &&
        !const {
          'native_algorithm.dart',
          'algorithm_library.dart',
        }.contains(entity.uri.pathSegments.last)) {
      await entity.copy('${algorithmDir.path}/${entity.uri.pathSegments.last}');
    }
  }
  await File('${algorithmDir.path}/user_algorithm.dart').writeAsString(source);
  final config = Directory('${workspace.path}/.dart_tool');
  await config.create();
  await File('${config.path}/package_config.json').writeAsString(
    jsonEncode({
      'configVersion': 2,
      'packages': [
        {
          'name': 'atrader',
          'rootUri': '../',
          'packageUri': 'lib/',
          'languageVersion': '3.12',
        },
      ],
    }),
  );
  final runner = File('${workspace.path}/runner.dart');
  await runner.writeAsString(
    _runnerSource.replaceAll('ALGORITHM_CLASS', classes.single.group(1)!),
  );
  final executable =
      '${workspace.path}/algorithm${Platform.isWindows ? '.exe' : ''}';
  final compiler = _findDart();
  final process = await Process.start(compiler, [
    'compile',
    'exe',
    runner.path,
    '-o',
    executable,
  ], workingDirectory: workspace.path);
  final output = process.stdout.transform(utf8.decoder).join();
  final errors = process.stderr.transform(utf8.decoder).join();
  final exit = await process.exitCode.timeout(
    const Duration(minutes: 2),
    onTimeout: () {
      process.kill();
      return -1;
    },
  );
  final diagnostic = '${await output}\n${await errors}'.trim();
  if (exit != 0) {
    throw FormatException(
      'Dart compilation failed:\n${diagnostic.length > 12000 ? diagnostic.substring(0, 12000) : diagnostic}',
    );
  }
  return executable;
}

Directory _findAlgorithmSdk() {
  for (final directory in [
    Directory(
      '${File(Platform.resolvedExecutable).parent.path}/algorithm_sdk/lib',
    ),
    Directory('${File.fromUri(Platform.script).parent.parent.path}/lib'),
    Directory('${Directory.current.path}/lib'),
  ]) {
    if (File('${directory.path}/strategy_api.dart').existsSync()) {
      return directory;
    }
  }
  throw StateError(
    'The algorithm SDK folder is missing. Keep algorithm_sdk beside the backend executable.',
  );
}

String _findDart() {
  final candidates = <String>[
    if (File(Platform.resolvedExecutable).uri.pathSegments.last.toLowerCase() ==
            'dart.exe' ||
        File(Platform.resolvedExecutable).uri.pathSegments.last == 'dart')
      Platform.resolvedExecutable,
    if (Platform.environment['DART_SDK'] case final String sdk)
      '$sdk/bin/dart${Platform.isWindows ? '.exe' : ''}',
    if (Platform.environment['FLUTTER_ROOT'] case final String root)
      '$root/bin/cache/dart-sdk/bin/dart${Platform.isWindows ? '.exe' : ''}',
    for (final path in (Platform.environment['PATH'] ?? '').split(
      Platform.isWindows ? ';' : ':',
    )) ...[
      '$path/dart${Platform.isWindows ? '.exe' : ''}',
      '$path/cache/dart-sdk/bin/dart${Platform.isWindows ? '.exe' : ''}',
    ],
  ];
  for (final path in candidates) {
    if (File(path).existsSync()) return path;
  }
  throw StateError(
    'Dart SDK not found. Install Flutter/Dart and put its bin folder on PATH, then restart the backend. JSON imports do not need a compiler.',
  );
}

const _runnerSource = r'''
import 'dart:convert';
import 'dart:io';
import 'package:atrader/strategy_api.dart';
import 'package:atrader/algorithms/user_algorithm.dart';
import 'package:atrader/algorithms/native_algorithm_protocol.dart';
import 'package:atrader/algorithms/native_algorithm_events.dart';
import 'package:atrader/algorithms/native_algorithm_progress.dart';
import 'package:atrader/simulator.dart';

class _CandidateAlgorithm implements TradingStrategy {
  final TradingStrategy prototype = ALGORITHM_CLASS();
  final instances = <String, TradingStrategy>{};
  String get id => prototype.id;
  String get name => prototype.name;
  String get description => prototype.description;
  int get warmupBars => prototype.warmupBars;
  List<StrategyParameter> get parameters => prototype.parameters;
  StrategySignal evaluate(StrategyContext context) =>
    instances.putIfAbsent(context.portfolioLabel, () => ALGORITHM_CLASS()).evaluate(context);
}

Map<String, Object?> replay(Map raw, void Function(int) progress) {
  final selected = _CandidateAlgorithm();
  StrategyRegistry.all.add(selected);
  try {
    final initial = Map<String, dynamic>.from(raw['checkpoint'] as Map);
    final watchlist = (initial['watchlist'] as List).cast<String>();
    final settings = [for (final item in (raw['strategies'] as List).cast<Map>()) StrategySettings(
      strategyId: item['strategyId'] as String, label: item['label'] as String,
      intervalMinutes: item['intervalMinutes'] as int,
      startingCash: (item['startingCash'] as num?)?.toDouble(),
      parameters: (item['parameters'] as Map).map((key,value) => MapEntry(key as String,(value as num).toDouble())),
    )];
    final engine = SimulatorEngine.restore(watchlist: watchlist, strategies: settings,
      startingCash: ((initial['execution'] as Map)['startingCash'] as num).toDouble(), checkpoint: initial);
    final cuts = (raw['cuts'] as List).map((time) => DateTime.parse(time as String)).toList();
    final counts = <Map<String, int>>[];
    final bars = raw['bars'] as List;
    final timer = Stopwatch()..start();
    var nextProgress = 0;
    for (var i = 0; i < bars.length; i++) {
      final item = bars[i] as Map;
      final time = DateTime.parse(item['time'] as String);
      if (counts.length < cuts.length && !time.isBefore(cuts[counts.length])) {
        counts.add({for (final account in engine.accounts.values) account.label: account.closedTradeCount});
      }
      engine.process(Candle(symbol:item['symbol'] as String,time:time,
        open:(item['open'] as num).toDouble(),high:(item['high'] as num).toDouble(),
        low:(item['low'] as num).toDouble(),close:(item['close'] as num).toDouble(),volume:(item['volume'] as num).toDouble()));
      if (raw['retainEvents'] != true) {
        for(final account in engine.accounts.values) {
          if(raw['retainFills'] == true) {
            account.events.removeWhere((event) => event.kind != 'fill');
          } else { account.events.clear(); }
        }
      }
      if(timer.elapsedMilliseconds >= nextProgress){progress(i+1);nextProgress=timer.elapsedMilliseconds+200;}
    }
    return {'checkpoint':engine.checkpoint(),'tradesAtCuts':counts};
  } finally { StrategyRegistry.all.remove(selected); }
}

void main(List<String> arguments) {
  final directory = arguments.single;
  void write(String name, Object value) {
    final temporary = File('$directory/$name.tmp');
    temporary.writeAsStringSync(jsonEncode(value));
    temporary.renameSync('$directory/$name');
  }
  try {
    final TradingStrategy algorithm = ALGORITHM_CLASS();
    write('ready.json', {
      'protocolVersion': nativeAlgorithmProtocolVersion,
      'id': algorithm.id, 'name': algorithm.name,
      'description': algorithm.description, 'warmupBars': algorithm.warmupBars,
      'parameters': {for (final p in algorithm.parameters) p.name: {
        'label': p.label, 'unit': p.unit, 'default': p.defaultValue,
        'min': p.minimum, 'max': p.maximum,
      }},
    });
    final instances = <String, TradingStrategy>{};
    final market = AlgorithmMarketDecoder();
    final notifications = NativeAlgorithmEvents(directory);
    final progress = NativeAlgorithmProgress(Directory(directory));
    final request = File('$directory/request.json');
    while (true) {
      if (notifications.enabled) { notifications.waitForRequest(); }
      if (!request.existsSync()) { sleep(const Duration(milliseconds: 1)); continue; }
      final message = jsonDecode(request.readAsStringSync()) as Map<String, dynamic>;
      request.deleteSync();
      Map<String, Object?> result;
      try {
        final payload = message['context'] as Map;
        if (payload['operation'] == 'replay') {
          final result = replay(payload, (completed) { progress.publish(message['sequence'] as int, completed); });
          write('response.json', {'sequence': message['sequence'], 'signal': result});
          notifications.responseReady();
          continue;
        }
        final data = market.apply(payload['market'] as Map);
        final signals = <Map<String, Object?>>[];
        for (final raw in (payload['contexts'] as List).cast<Map>()) {
        Map<String, Object?> decision;
        try {
        final instanceKey = '${raw['executionId']}|${raw['portfolioLabel']}';
        final instance = instances.putIfAbsent(instanceKey, () => ALGORITHM_CLASS());
        final signal = instance.evaluate(StrategyContext(
          candles: data.candles,
          watchlist: data.watchlist,
          hasPosition: raw['hasPosition'] as bool,
          entryPrice: (raw['entryPrice'] as num?)?.toDouble(),
          positionStop: (raw['positionStop'] as num?)?.toDouble(),
          positionSide: PositionSide.values.byName(raw['positionSide'] as String),
          parameters: (raw['parameters'] as Map).map((key, value) => MapEntry(key as String, (value as num).toDouble())),
          intervalMinutes: raw['intervalMinutes'] as int,
          sessionElapsedMinutes: raw['sessionElapsedMinutes'] as int?,
          sessionLengthMinutes: raw['sessionLengthMinutes'] as int?,
          barsHeld: raw['barsHeld'] as int, portfolioLabel: raw['portfolioLabel'] as String,
          executionId: raw['executionId'] as String? ?? '',
        ));
        decision = {
          'action': signal.action.name, 'reason': signal.reason,
          'side': signal.side.name, 'positionEffect': signal.positionEffect?.name,
          'stop': signal.stop, 'target': signal.target,
          'measurements': signal.measurements,
          'sourceStrategyId': signal.sourceStrategyId,
          'sourceStrategyParameters': signal.sourceStrategyParameters,
        };
        jsonEncode(decision);
        } catch (error) { decision = {'error': error.toString()}; }
        signals.add(decision);
        }
        result = {'signals': signals};
      } catch (error) { result = {'error': error.toString()}; }
      write('response.json', {'sequence': message['sequence'], 'signal': result});
      notifications.responseReady();
    }
  } catch (error) { write('ready.json', {'error': error.toString()}); }
}
''';
