import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:atrader/historical_replay.dart';
import 'package:atrader/live_runtime.dart';
import 'package:atrader/local_backend.dart';
import 'package:atrader/schwab_api.dart';
import 'package:atrader/secure_storage.dart';
import 'package:atrader/simulator.dart';
import 'package:flutter_test/flutter_test.dart';

final _sessionOpen = DateTime.utc(2025, 1, 6, 14, 30);

class _HistoryStorage extends SecureStorage {
  @override
  Future<Map<String, String>> load() async => {
    'appKey': 'fixture',
    'appSecret': 'fixture',
    'refreshToken': 'fixture',
  };
}

class _HistoryMarket extends SchwabApi {
  _HistoryMarket({
    required super.storage,
    required super.onQuote,
    required super.onState,
  });

  @override
  Future<void> startStreaming(List<String> symbols) async {
    onState(FeedState.live, 'Fixture market-data connection');
  }

  @override
  Future<List<MinuteBar>> fetchMinuteBars({
    required String symbol,
    required DateTime startUtc,
    required DateTime endUtc,
  }) async => [
    for (var index = 0; index < 25; index++)
      MinuteBar(
        symbol: symbol,
        openTime: _sessionOpen.add(Duration(minutes: index)),
        open: 100 + index * 2.0,
        high: 101.5 + index * 2.0,
        low: 99.5 + index * 2.0,
        close: 101 + index * 2.0,
        volume: 100,
      ),
  ];
}

class _ReplayHarness {
  final firstRequest = Completer<void>();
  final releaseResponse = Completer<void>();
  final snapshots = <Map<String, dynamic>>[];
  final client = HttpClient();
  late final Directory directory;
  late final HttpServer modelServer;
  late final StreamSubscription<HttpRequest> subscription;
  late final LocalBackend backend;
  late final _HistoryMarket market;
  late final int port;
  DateTime now = _sessionOpen;
  bool invalidResponse = false;
  bool closing = false;

  Future<void> start({
    bool historical = true,
    List<String> labels = const ['LM replay'],
  }) async {
    directory = await Directory.systemTemp.createTemp('atrader-replay-lm-');
    modelServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    subscription = modelServer.listen((request) async {
      final body =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>;
      final messages = body['messages'] as List<dynamic>;
      snapshots.add(
        jsonDecode(messages.last['content'] as String) as Map<String, dynamic>,
      );
      if (!firstRequest.isCompleted) firstRequest.complete();
      await releaseResponse.future;
      if (closing) return;
      request.response
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'tool_calls': [
                    {
                      'type': 'function',
                      'function': {
                        'name': invalidResponse
                            ? 'not_an_allowed_tool'
                            : 'inspect_donchian',
                        'arguments': jsonEncode({
                          'symbol': 'SOXL',
                          'lookback': 2,
                          'exitLookback': 2,
                          'reason': 'Fixture breakout.',
                        }),
                      },
                    },
                  ],
                },
              },
            ],
          }),
        );
      await request.response.close();
    });
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    port = probe.port;
    await probe.close();
    backend = LocalBackend(
      dataDirectory: directory,
      secureStorage: _HistoryStorage(),
      clock: () => now,
      schwabApiFactory: (storage, onQuote, onState) => market = _HistoryMarket(
        storage: storage,
        onQuote: onQuote,
        onState: onState,
      ),
    );
    await backend.start(port: port);
    await call('settings/run', {
      'watchlist': ['SOXL'],
      'startingCash': 10000,
      'risk': {'spreadBps': 0, 'slippageBps': 0, 'feePerShare': 0},
      'strategies': [
        for (final label in labels)
          {
            'strategyId': 'lm_selector',
            'label': label,
            'intervalMinutes': 1,
            'enabled': true,
            'parameters': <String, double>{},
          },
      ],
    });
    await call('lm/config', {
      'url': 'http://127.0.0.1:${modelServer.port}',
      'model': 'fixture-model',
    });
    if (historical) {
      await call('run/historical/start', {
        'startDate': '2025-01-06',
        'endDate': '2025-01-06',
      });
    } else {
      await call('schwab/connect', {});
      await call('run/start', {});
      for (var index = 0; index < 26; index++) {
        now = _sessionOpen.add(Duration(minutes: index));
        market.onQuote(
          LiveQuote(
            symbol: 'SOXL',
            time: now,
            bid: 100 + index * 2.0,
            ask: 100 + index * 2.0,
            last: 100 + index * 2.0,
            volume: index * 100,
            realTime: true,
          ),
        );
      }
    }
    await firstRequest.future.timeout(const Duration(seconds: 5));
  }

  Future<Map<String, dynamic>> call(
    String endpoint, [
    Map<String, Object?>? body,
  ]) async {
    final request = await client.openUrl(
      body == null ? 'GET' : 'POST',
      Uri.parse('http://127.0.0.1:$port/api/$endpoint'),
    );
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close();
    final result =
        jsonDecode(await utf8.decoder.bind(response).join())
            as Map<String, dynamic>;
    expect(response.statusCode, HttpStatus.ok, reason: result.toString());
    return result;
  }

  Future<Map<String, dynamic>> waitForCompletion() async {
    for (var attempt = 0; attempt < 100; attempt++) {
      final status = await call('status');
      if (status['running'] == false) return status;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    throw StateError('Fixture replay did not finish.');
  }

  Future<void> close() async {
    closing = true;
    await backend.stop();
    if (!releaseResponse.isCompleted) releaseResponse.complete();
    client.close(force: true);
    await modelServer.close(force: true);
    await subscription.cancel();
    await directory.delete(recursive: true);
  }
}

void main() {
  test(
    'historical backend waits beyond the live timeout before evaluating',
    () async {
      final harness = _ReplayHarness();
      addTearDown(harness.close);
      await harness.start();
      final waiting = await harness.call('status');
      expect(waiting['running'], isTrue);
      expect(waiting['runStatus'], contains('waiting for LM Studio'));
      expect(waiting['lmSelector']['pendingRequests'], 1);
      expect(waiting['strategies'].single['warmupBySymbol']['SOXL'], 21);
      final firstSnapshot = harness.snapshots.single;
      expect(firstSnapshot['candles'], hasLength(22));
      final decisionTime = _sessionOpen.add(const Duration(minutes: 22));
      expect(
        firstSnapshot['candles'].last['time'],
        decisionTime.toIso8601String(),
      );
      expect(firstSnapshot['candles'].last['close'], 143);

      await Future<void>.delayed(const Duration(seconds: 16));
      final stillWaiting = await harness.call('status');
      expect(stillWaiting['running'], isTrue);
      expect(stillWaiting['replayProgress'], waiting['replayProgress']);
      expect(stillWaiting['symbols'], waiting['symbols']);
      expect(harness.snapshots, hasLength(1));
      harness.releaseResponse.complete();
      final completed = await harness.waitForCompletion();
      expect(completed['runStatus'], contains('complete'));
      expect(completed['lmSelector']['pendingRequests'], 0);
      expect(completed['strategies'].single['readyBySymbol']['SOXL'], isTrue);
      expect(harness.snapshots, hasLength(3));
      final snapshot = await harness.call('snapshot');
      final account = (snapshot['accounts'] as List<dynamic>).singleWhere(
        (account) => account['label'] == 'LM replay',
      );
      final events = account['events'] as List<dynamic>;
      final modelEvents = events.where((event) => event['kind'] == 'model');
      expect(modelEvents, hasLength(3));
      expect(modelEvents.first['time'], decisionTime.toIso8601String());
      expect(
        modelEvents.every((event) => !event['reason'].contains('expired')),
        isTrue,
      );
      final fill = events.firstWhere((event) => event['kind'] == 'fill');
      expect(
        fill['time'],
        decisionTime.add(const Duration(milliseconds: 1)).toIso8601String(),
      );
      expect(fill['price'], 144);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'historical replay awaits every independent selector instance',
    () async {
      final harness = _ReplayHarness();
      addTearDown(harness.close);
      await harness.start(labels: ['First selector', 'Second selector']);
      for (
        var attempt = 0;
        harness.snapshots.length < 2 && attempt < 100;
        attempt++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final waiting = await harness.call('status');
      expect(waiting['lmSelector']['pendingRequests'], 2);
      expect(harness.snapshots, hasLength(2));
      expect(harness.snapshots.first, harness.snapshots.last);
      harness.releaseResponse.complete();
      await harness.waitForCompletion();
      expect(harness.snapshots, hasLength(6));
      final snapshot = await harness.call('snapshot');
      for (final label in ['First selector', 'Second selector']) {
        final account = (snapshot['accounts'] as List<dynamic>).singleWhere(
          (account) => account['label'] == label,
        );
        final events = account['events'] as List<dynamic>;
        expect(events.where((event) => event['kind'] == 'model'), hasLength(3));
        expect(
          events.firstWhere((event) => event['kind'] == 'fill')['price'],
          144,
        );
      }
    },
  );

  test('live quotes keep advancing and expire late model choices', () async {
    final harness = _ReplayHarness();
    addTearDown(harness.close);
    await harness.start(historical: false);
    final waiting = await harness.call('status');
    expect(waiting['running'], isTrue);
    expect(waiting['lmSelector']['pendingRequests'], 1);
    expect(
      waiting['symbols']['SOXL']['updatedAt'],
      harness.now.toIso8601String(),
    );
    final before = await harness.call('snapshot');
    final account = (before['accounts'] as List<dynamic>).singleWhere(
      (account) => account['label'] == 'LM replay',
    );
    expect(
      (account['events'] as List<dynamic>).last['time'],
      harness.now.toIso8601String(),
    );
    harness.releaseResponse.complete();
    Map<String, dynamic> status = waiting;
    for (var attempt = 0; attempt < 100; attempt++) {
      status = await harness.call('status');
      if (status['lmSelector']['pendingRequests'] == 0) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(status['lmSelector']['instances']['LM replay'], contains('Expired'));
    expect(status['strategies'].single['readyBySymbol']['SOXL'], isFalse);
    final after = await harness.call('snapshot');
    final updated = (after['accounts'] as List<dynamic>).singleWhere(
      (account) => account['label'] == 'LM replay',
    );
    final model = (updated['events'] as List<dynamic>).singleWhere(
      (event) => event['kind'] == 'model',
    );
    expect(model['reason'], contains('expired'));
  });

  test(
    'Stop cancels historical inference without a late decision or fill',
    () async {
      final harness = _ReplayHarness();
      addTearDown(harness.close);
      await harness.start();
      final waiting = await harness.call('status');
      await harness.call('run/stop', {}).timeout(const Duration(seconds: 2));
      final stopped = await harness.waitForCompletion();
      expect(stopped['running'], isFalse);
      expect(stopped['lmSelector']['pendingRequests'], 0);
      expect(stopped['replayProgress'], waiting['replayProgress']);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final snapshot = await harness.call('snapshot');
      final account = (snapshot['accounts'] as List<dynamic>).singleWhere(
        (account) => account['label'] == 'LM replay',
      );
      expect(
        (account['events'] as List<dynamic>).where(
          (event) => event['kind'] == 'model' || event['kind'] == 'fill',
        ),
        isEmpty,
      );
    },
  );

  test('invalid model choices explicitly WAIT and replay continues', () async {
    final harness = _ReplayHarness()..invalidResponse = true;
    addTearDown(harness.close);
    await harness.start();
    harness.releaseResponse.complete();
    final completed = await harness.waitForCompletion();
    expect(completed['runStatus'], contains('complete'));
    expect(completed['strategies'].single['readyBySymbol']['SOXL'], isFalse);
    final snapshot = await harness.call('snapshot');
    final account = (snapshot['accounts'] as List<dynamic>).singleWhere(
      (account) => account['label'] == 'LM replay',
    );
    final events = account['events'] as List<dynamic>;
    final modelEvents = events.where((event) => event['kind'] == 'model');
    expect(modelEvents, hasLength(3));
    expect(
      modelEvents.every((event) => event['reason'].contains('WAIT')),
      isTrue,
    );
    expect(events.where((event) => event['kind'] == 'fill'), isEmpty);
  });
}
