import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../strategy_api.dart';
import 'imported_definition.dart';

/// A compiled Dart algorithm runs in a persistent local worker. File messages
/// let the synchronous simulator retain its existing decision/fill ordering.
class NativeAlgorithm extends ImportedAlgorithmDefinition {
  NativeAlgorithm._(super.json, this._worker) : super.fromJson();
  final NativeAlgorithmWorker _worker;

  static Future<NativeAlgorithm> open(Map<String, dynamic> definition) async {
    final worker = await NativeAlgorithmWorker.start(
      definition['executable'] as String,
    );
    try {
      final algorithm = NativeAlgorithm._(worker.metadata, worker);
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
  StrategySignal evaluate(StrategyContext context) {
    try {
      final raw = _worker.evaluate({
        'candles': [for (final bar in context.candles) _candle(bar)],
        'watchlist': {
          for (final entry in context.watchlist.entries)
            entry.key: [for (final bar in entry.value) _candle(bar)],
        },
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
      });
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

  static Map<String, Object?> _candle(Candle bar) => {
    'symbol': bar.symbol,
    'time': bar.time.toUtc().toIso8601String(),
    'open': bar.open,
    'high': bar.high,
    'low': bar.low,
    'close': bar.close,
    'volume': bar.volume,
  };
}

class NativeAlgorithmWorker {
  NativeAlgorithmWorker._(this._directory, this._process);
  final Directory _directory;
  final Process _process;
  late final Map<String, dynamic> metadata;
  bool _closed = false;
  String _diagnostics = '';
  int _sequence = 0;

  static Future<NativeAlgorithmWorker> start(String executable) async {
    final directory = await Directory.systemTemp.createTemp(
      'atrader-algorithm-',
    );
    NativeAlgorithmWorker? worker;
    try {
      final process = await Process.start(executable, [
        directory.path,
      ], workingDirectory: File(executable).parent.path);
      worker = NativeAlgorithmWorker._(directory, process);
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
      final ready = File('${directory.path}/ready.json');
      final timer = Stopwatch()..start();
      while (!await ready.exists()) {
        if (timer.elapsed > const Duration(seconds: 10)) {
          throw StateError(
            'Dart algorithm did not start. ${worker._diagnostics}',
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final raw =
          jsonDecode(await ready.readAsString()) as Map<String, dynamic>;
      if (raw['error'] != null) throw StateError(raw['error'].toString());
      worker.metadata = raw;
      return worker;
    } catch (_) {
      if (worker != null) {
        await worker.close();
      } else {
        await directory.delete(recursive: true);
      }
      rethrow;
    }
  }

  Map<String, dynamic> evaluate(Map<String, Object?> context) {
    if (_closed) {
      throw StateError(
        'Worker stopped after an error. Reopen the backend to restart it.',
      );
    }
    final sequence = ++_sequence;
    final request = File('${_directory.path}/request.json');
    final temporary = File('${request.path}.tmp');
    final response = File('${_directory.path}/response.json');
    temporary.writeAsStringSync(
      jsonEncode({'sequence': sequence, 'context': context}),
      flush: true,
    );
    temporary.renameSync(request.path);
    final timer = Stopwatch()..start();
    while (!response.existsSync()) {
      if (timer.elapsed > const Duration(seconds: 5)) {
        _closed = true;
        _process.kill();
        throw StateError('Decision exceeded 5 seconds; worker stopped.');
      }
      sleep(const Duration(milliseconds: 1));
    }
    final result =
        jsonDecode(response.readAsStringSync()) as Map<String, dynamic>;
    response.deleteSync();
    if (result['sequence'] != sequence) {
      throw StateError('Worker returned an out-of-order decision.');
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

void main(List<String> arguments) {
  final directory = arguments.single;
  void write(String name, Object value) {
    final temporary = File('$directory/$name.tmp');
    temporary.writeAsStringSync(jsonEncode(value), flush: true);
    temporary.renameSync('$directory/$name');
  }
  try {
    final TradingStrategy algorithm = ALGORITHM_CLASS();
    write('ready.json', {
      'id': algorithm.id, 'name': algorithm.name,
      'description': algorithm.description, 'warmupBars': algorithm.warmupBars,
      'parameters': {for (final p in algorithm.parameters) p.name: {
        'label': p.label, 'unit': p.unit, 'default': p.defaultValue,
        'min': p.minimum, 'max': p.maximum,
      }},
    });
    final instances = <String, TradingStrategy>{};
    final request = File('$directory/request.json');
    while (true) {
      if (!request.existsSync()) { sleep(const Duration(milliseconds: 1)); continue; }
      final message = jsonDecode(request.readAsStringSync()) as Map<String, dynamic>;
      request.deleteSync();
      Map<String, Object?> result;
      try {
        final raw = message['context'] as Map<String, dynamic>;
        Candle candle(Map raw) => Candle(
          symbol: raw['symbol'] as String, time: DateTime.parse(raw['time'] as String),
          open: (raw['open'] as num).toDouble(), high: (raw['high'] as num).toDouble(),
          low: (raw['low'] as num).toDouble(), close: (raw['close'] as num).toDouble(),
          volume: (raw['volume'] as num).toDouble(),
        );
        List<Candle> bars(Object? raw) => (raw as List).map((bar) => candle(bar as Map)).toList();
        final instanceKey = '${raw['executionId']}|${raw['portfolioLabel']}';
        final instance = instances.putIfAbsent(instanceKey, () => ALGORITHM_CLASS());
        final signal = instance.evaluate(StrategyContext(
          candles: bars(raw['candles']),
          watchlist: (raw['watchlist'] as Map).map((key, value) => MapEntry(key as String, bars(value))),
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
        result = {
          'action': signal.action.name, 'reason': signal.reason,
          'side': signal.side.name, 'positionEffect': signal.positionEffect?.name,
          'stop': signal.stop, 'target': signal.target,
          'measurements': signal.measurements,
          'sourceStrategyId': signal.sourceStrategyId,
          'sourceStrategyParameters': signal.sourceStrategyParameters,
        };
        jsonEncode(result);
      } catch (error) { result = {'error': error.toString()}; }
      write('response.json', {'sequence': message['sequence'], 'signal': result});
    }
  } catch (error) { write('ready.json', {'error': error.toString()}); }
}
''';
