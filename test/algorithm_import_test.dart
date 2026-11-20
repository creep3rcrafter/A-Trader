import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:atrader/algorithms/algorithm_library.dart';
import 'package:atrader/algorithms/json_algorithm.dart';
import 'package:atrader/algorithms/registry.dart';
import 'package:atrader/auto_research.dart';
import 'package:atrader/historical_replay.dart';
import 'package:atrader/local_backend.dart';
import 'package:atrader/secure_storage.dart';
import 'package:atrader/strategy_api.dart';
import 'package:atrader/simulator.dart' show StrategySettings;
import 'package:atrader/strategy_tuning.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> example({String id = 'imported_sma'}) => {
  'format': 'atrader.algorithm',
  'version': 1,
  'kind': 'rules',
  'id': id,
  'name': 'Imported SMA',
  'description': 'Test imported rule strategy.',
  'warmupBars': 3,
  'intervalMinutes': 1,
  'parameters': {
    'period': {'default': 3, 'min': 2, 'max': 5, 'unit': 'bars', 'round': true},
    'threshold': {'default': 0.01, 'min': 0, 'max': 0.1, 'unit': 'fraction'},
  },
  'calculations': {
    'average': 'sma(close, period)',
    'distance': 'close / average - 1',
  },
  'rules': [
    {
      'when': "hasPosition && positionSide == 'long' && distance < 0",
      'action': 'sell',
      'side': 'long',
      'positionEffect': 'close',
      'reason': 'Below average.',
    },
    {
      'when': '!hasPosition && distance > threshold',
      'action': 'buy',
      'side': 'long',
      'positionEffect': 'open',
      'stop': 'close * 0.98',
      'reason': 'Above average.',
    },
  ],
};

StrategyContext context(
  List<double> closes, {
  bool held = false,
  Map<String, double> parameters = const {},
}) {
  final bars = [
    for (var i = 0; i < closes.length; i++)
      Candle(
        symbol: 'SOXL',
        time: DateTime.utc(2026, 5, 4, 13, 31 + i),
        open: closes[i],
        high: closes[i] + 1,
        low: closes[i] - 1,
        close: closes[i],
        volume: 1000,
      ),
  ];
  return StrategyContext(
    candles: bars,
    watchlist: {'SOXL': bars},
    hasPosition: held,
    entryPrice: held ? 100 : null,
    parameters: parameters,
  );
}

class _EmptyStorage extends SecureStorage {
  @override
  Future<Map<String, String>> load() async => {};
}

void main() {
  tearDown(() => StrategyRegistry.replaceImported([]));

  test(
    'JSON rules use math, tunable defaults, closed bars, and position exits',
    () {
      final algorithm = JsonAlgorithm(example());
      final entry = algorithm.evaluate(context([100, 100, 104]));
      expect(entry.action, TradeAction.buy);
      expect(entry.positionEffect, PositionEffect.open);
      expect(entry.stop, closeTo(101.92, 1e-9));
      expect(
        algorithm
            .evaluate(context([100, 100, 104], parameters: {'threshold': 0.1}))
            .action,
        TradeAction.wait,
      );
      expect(
        algorithm.evaluate(context([100, 100, 96], held: true)).action,
        TradeAction.sell,
      );
      expect(algorithm.evaluate(context([100])).action, TradeAction.wait);
      expect(
        algorithm
            .evaluate(context([100, 100, 104], parameters: {'period': 4.5}))
            .action,
        TradeAction.wait,
      );
    },
  );

  test(
    'expressions validate names, function arguments, and rule directions',
    () {
      for (final calculation in [
        'system(close)',
        'sma(close + 1, period)',
        'notDefined + 1',
        'sma(close)',
        'close; 42',
        'true +',
      ]) {
        expect(
          () => JsonAlgorithm({
            ...example(),
            'calculations': {'average': calculation},
          }),
          throwsFormatException,
        );
      }
      expect(
        () => JsonAlgorithm({...example(), 'kind': 'llm'}),
        throwsFormatException,
      );
      final reversed = example();
      ((reversed['rules'] as List).last as Map)['side'] = 'short';
      expect(() => JsonAlgorithm(reversed), throwsFormatException);
      expect(
        () => JsonAlgorithm({...example(), 'id': '../outside'}),
        throwsFormatException,
      );
    },
  );

  test('indicator values and history offsets never read future bars', () {
    final definition = example();
    definition['calculations'] = {
      'average': 'sma(close, period)',
      'distance': 'close / average - 1',
      'previous': 'close[1]',
      'range': 'atr(2)',
      'strength': 'rsi(close, 2)',
      'highestClose': 'highest(close, 3)',
      'deviation': 'std(close, 3)',
      'math': 'clamp(abs(-3) + pow(2, 2), 0, 10)',
    };
    final signal = JsonAlgorithm(definition).evaluate(context([100, 102, 104]));
    expect(signal.measurements['previous'], 102);
    expect(signal.measurements['range'], 3);
    expect(signal.measurements['strength'], 100);
    expect(signal.measurements['highestClose'], 104);
    expect(signal.measurements['deviation'], closeTo(math.sqrt(8 / 3), 1e-9));
    expect(signal.measurements['math'], 7);
    final invalid = example()
      ..['calculations'] = {'average': 'close / 0', 'distance': '0'};
    final waiting = JsonAlgorithm(invalid).evaluate(context([100, 100, 104]));
    expect(waiting.action, TradeAction.wait);
    expect(waiting.reason, contains('finite'));
    final future = example()
      ..['calculations'] = {'average': 'close[-1]', 'distance': '0'};
    expect(
      JsonAlgorithm(future).evaluate(context([100, 100, 104])).action,
      TradeAction.wait,
    );
  });

  test(
    'imported JSON survives a backend restart and is included in export',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'algorithm-backend-',
      );
      LocalBackend? backend;
      final client = HttpClient();
      Future<int> port() async {
        final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final result = socket.port;
        await socket.close();
        return result;
      }

      late int currentPort;
      Future<Map<String, dynamic>> request(
        String method,
        String path, [
        Map<String, Object?>? body,
      ]) async {
        final request = await client.openUrl(
          method,
          Uri.parse('http://127.0.0.1:$currentPort$path'),
        );
        if (body != null) {
          request.headers.contentType = ContentType.json;
          request.write(jsonEncode(body));
        }
        final response = await request.close();
        final decoded =
            jsonDecode(await utf8.decoder.bind(response).join())
                as Map<String, dynamic>;
        if (response.statusCode != 200) {
          throw StateError(decoded['error'].toString());
        }
        return decoded;
      }

      try {
        currentPort = await port();
        backend = LocalBackend(
          dataDirectory: directory,
          secureStorage: _EmptyStorage(),
        );
        await backend.start(port: currentPort);
        final body = {
          'filename': 'my algorithm.json',
          'source': jsonEncode(example()),
        };
        final result = await request('POST', '/api/algorithms/import', body);
        expect((result['metadata'] as Map)['id'], 'imported_sma');
        await expectLater(
          request('POST', '/api/algorithms/import', body),
          throwsStateError,
        );
        expect(
          (await request('GET', '/api/algorithms'))['algorithms'],
          hasLength(1),
        );
        final exported = await request('GET', '/api/export');
        expect(
          ((exported['savedState'] as Map)['algorithms'] as List)
              .single['source'],
          body['source'],
        );
        await backend.stop();
        backend = null;
        currentPort = await port();
        backend = LocalBackend(
          dataDirectory: directory,
          secureStorage: _EmptyStorage(),
        );
        await backend.start(port: currentPort);
        expect(
          (await request('GET', '/api/algorithms'))['algorithms'],
          hasLength(1),
        );
        expect(
          StrategyRegistry.byId(
            'imported_sma',
          ).evaluate(context([100, 100, 104])).action,
          TradeAction.buy,
        );
      } finally {
        client.close(force: true);
        await backend?.stop();
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'automatic evolution registers imported rules inside its worker isolate',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'algorithm-research-',
      );
      final library = AlgorithmLibrary(directory);
      AutoResearch? research;
      try {
        await library.importFile('strategy.json', jsonEncode(example()));
        final setting = StrategySettings(
          strategyId: 'imported_sma',
          label: 'Imported',
        );
        research = AutoResearch(
          clock: () => DateTime.utc(2026, 5, 6),
          algorithmDefinitions: () => List.of(library.definitions),
          fetch:
              ({required symbol, required startUtc, required endUtc}) async => [
                for (var i = 0; i < 210; i++)
                  MinuteBar(
                    symbol: symbol,
                    openTime: DateTime.utc(2026, 5, 4, 13, 30 + i),
                    open: 100 + math.sin(i / 4) * 5,
                    close: 100 + math.sin((i + 1) / 4) * 5,
                    high: 106,
                    low: 94,
                    volume: 1000,
                  ),
              ],
        );
        research.start(
          runName: 'Imported test',
          configuration: {
            'watchlist': ['SOXL'],
            'strategies': [
              {
                'strategyId': setting.strategyId,
                'label': setting.label,
                'enabled': true,
                'intervalMinutes': 1,
                'parameters': <String, double>{},
              },
            ],
          },
          strategies: [setting],
          generations: 0,
          evolutionLimit: 1,
          evolution: const EvolutionSettings(candidatesPerGeneration: 1),
          historicalRange: (
            startUtc: DateTime.utc(2026, 5, 4, 13, 30),
            endUtc: DateTime.utc(2026, 5, 4, 17),
            label: 'Test',
          ),
        );
        await research.stopped.timeout(const Duration(seconds: 20));
        expect(research.status['phase'], 'complete');
        final result = (research.status['lastResults'] as List).single as Map;
        expect(result['strategyId'], 'imported_sma');
        expect(result['status'], isNot('skipped'));
      } finally {
        research?.stop();
        await research?.stopped;
        await library.close();
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'Dart template compiles, evaluates in a fresh isolate, and restores cached code',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'algorithm-dart-',
      );
      var library = AlgorithmLibrary(directory);
      try {
        await library.importFile(
          'algorithm.dart',
          await File(
            'templates/algorithms/strategy_template.dart',
          ).readAsString(),
        );
        final saved = jsonDecode(jsonEncode(library.definitions)) as List;
        final result = await Isolate.run(() async {
          final isolated = AlgorithmLibrary(Directory.systemTemp);
          await isolated.restore(saved.cast<Map<String, dynamic>>());
          try {
            final signal = StrategyRegistry.byId('template_sma').evaluate(
              context([100, 100, 100, 104], parameters: {'lookback': 4}),
            );
            return (signal.action.name, signal.stop);
          } finally {
            await isolated.close();
          }
        });
        expect(result.$1, 'buy');
        expect(result.$2, closeTo(101.92, 1e-9));
        await library.close();
        library = AlgorithmLibrary(directory);
        await library.restore(saved.cast<Map<String, dynamic>>());
        expect(
          StrategyRegistry.byId('template_sma').name,
          'Template: SMA distance',
        );
      } finally {
        await library.close();
        await directory.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
