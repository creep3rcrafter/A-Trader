import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:atrader/historical_replay.dart';
import 'package:atrader/live_runtime.dart';
import 'package:atrader/local_backend.dart';
import 'package:atrader/mountain_time.dart';
import 'package:atrader/schwab_api.dart';
import 'package:atrader/secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _FixtureStorage extends SecureStorage {
  @override
  Future<Map<String, String>> load() async => {
    'appKey': 'fixture',
    'appSecret': 'fixture',
    'refreshToken': 'fixture',
  };
}

class _HistoryFixture extends SchwabApi {
  _HistoryFixture({
    required super.storage,
    required super.onQuote,
    required super.onState,
    required this.releaseHistory,
  });

  final Future<void> releaseHistory;
  int historyRequests = 0;

  @override
  Future<void> startStreaming(List<String> symbols) async =>
      onState(FeedState.live, 'Fixture market data');

  @override
  Future<void> updateStreamingSymbols(List<String> symbols) async {}

  @override
  Future<List<MinuteBar>> fetchMinuteBars({
    required String symbol,
    required DateTime startUtc,
    required DateTime endUtc,
  }) async {
    historyRequests++;
    await releaseHistory;
    return [
      for (var index = 0; index < 240; index++)
        MinuteBar(
          symbol: symbol,
          openTime: DateTime.utc(2026, 5, 4, 13, 30 + index),
          open: 100 + 5 * sin(index / 4),
          high: 101 + 5 * sin(index / 4),
          low: 99 + 5 * sin(index / 4),
          close: 100 + 5 * sin(index / 4),
          volume: 1000,
        ),
    ];
  }
}

Map<String, Object?> _configuration(double cash, int interval) => {
  'watchlist': ['SOXL'],
  'startingCash': cash,
  'risk': {'spreadBps': 0, 'slippageBps': 0, 'feePerShare': 0},
  'strategies': [
    {
      'strategyId': 'ma_crossover',
      'label': 'Fixture crossover',
      'intervalMinutes': interval,
      'enabled': true,
      'parameters': {'fastPeriod': 2, 'slowPeriod': 4},
    },
  ],
};

void main() {
  test('research preview refreshes independently of the source run', () async {
    final directory = await Directory.systemTemp.createTemp('atrader-preview-');
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();
    final releaseHistory = Completer<void>();
    var backend = LocalBackend(
      dataDirectory: directory,
      secureStorage: _FixtureStorage(),
      clock: () => DateTime.utc(2026, 5, 5, 15),
      schwabApiFactory: (storage, onQuote, onState) => _HistoryFixture(
        storage: storage,
        onQuote: onQuote,
        onState: onState,
        releaseHistory: releaseHistory.future,
      ),
    );
    final client = HttpClient();
    var stopped = false;
    addTearDown(() async {
      if (!releaseHistory.isCompleted) releaseHistory.complete();
      client.close(force: true);
      if (!stopped) await backend.stop();
      await directory.delete(recursive: true);
    });

    Future<Map<String, dynamic>> call(
      String endpoint, [
      Map<String, Object?>? body,
      int expectedStatus = HttpStatus.ok,
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
      final payload = await utf8.decoder.bind(response).join();
      expect(response.statusCode, expectedStatus, reason: payload);
      return jsonDecode(payload) as Map<String, dynamic>;
    }

    Future<Map<String, dynamic>> waitForCycle(int cycle) async {
      final clock = Stopwatch()..start();
      while (clock.elapsed < const Duration(seconds: 10)) {
        final research =
            (await call('status'))['research'] as Map<String, dynamic>;
        if ((research['cycles'] as int) >= cycle &&
            research['previewRunId'] is String) {
          return research;
        }
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      throw StateError('Research did not publish preview cycle $cycle.');
    }

    await backend.start(port: port);
    await call('settings/run', {
      ..._configuration(7000, 5),
      'benchmarks': {'buyAndHold': true, 'equalWeight': false},
    });
    await call('schwab/connect', {});
    await call('run/start', {});
    final source = await call('status');
    final sourceId = source['runId'] as String;
    expect(source['running'], isTrue);
    await call('research/start', {
      'runId': sourceId,
      'configuration': {
        ..._configuration(12000, 30),
        'benchmarks': {'buyAndHold': false, 'equalWeight': true},
      },
      'evolutions': 2,
      'evolution': {
        'mutationAmount': .5,
        'additionalMutationProbability': .4,
        'candidatesPerGeneration': 6,
      },
      'historicalRange': {
        'startDate': '2026-05-04',
        'endDate': '2026-05-04',
        'startTime': '08:15',
        'endTime': '12:00',
        'timeZone': MountainTime.zoneId,
      },
    });

    final downloading = (await call('status'))['research'] as Map;
    expect(downloading['phase'], 'downloading');
    expect(downloading['progress'], 0);
    expect(downloading['detail'], contains('SOXL'));
    releaseHistory.complete();

    final first = await waitForCycle(1);
    final previewId = first['previewRunId'] as String;
    expect(previewId, isNot(sourceId));
    final selected = await call('status');
    expect(selected['runId'], previewId);
    expect(selected['researchPreview'], isTrue);
    final snapshot = await call('snapshot?runId=$previewId');
    expect(
      (snapshot['accounts'] as List).cast<Map>().map((row) => row['label']),
      unorderedEquals(['Fixture crossover', 'Equal Weight']),
    );
    final account = (snapshot['accounts'] as List).cast<Map>().singleWhere(
      (row) => row['label'] == 'Fixture crossover',
    );
    expect(account['startingCash'], 12000);
    expect(account['history'], hasLength(greaterThan(150)));
    expect(account['closedTradeCount'], greaterThan(0));
    expect(account['closedPnl'], isNotEmpty);
    expect(account['equity'], isA<num>());

    final candles = (snapshot['candles'] as Map)['SOXL:1'] as List;
    expect(candles, hasLength(195));
    expect(
      DateTime.parse((candles.first as Map)['time'] as String),
      DateTime.utc(2026, 5, 4, 14, 16),
    );
    final previewEvents = (snapshot['previewEvents'] as List).cast<Map>();
    expect(previewEvents, isNotEmpty);
    expect(previewEvents.any((event) => event['kind'] == 'fill'), isTrue);
    expect((await call('log?runId=$previewId'))['events'], isNotEmpty);
    await call('settings/run', _configuration(123, 1), HttpStatus.badRequest);
    await call('run/reset', {}, HttpStatus.badRequest);

    final second = await waitForCycle(2);
    expect(second['previewRunId'], previewId);
    expect(second['phase'], 'complete');
    expect(second['running'], isFalse);
    expect(second['cycles'], 2);
    final changes = await call(
      'runs/variable-changes?runId=$sourceId&generation=1',
    );
    expect(changes['generation'], 1);
    expect(changes['latestGeneration'], 2);
    expect(changes['strategies'], isNotEmpty);
    expect(changes['strategies'][0]['currentParameters'], isA<Map>());
    expect(changes['strategies'][0]['candidateParameters'], isA<Map>());
    final refreshed = await call('snapshot');
    expect(refreshed['status']['research']['cycles'], greaterThanOrEqualTo(2));
    expect(refreshed['accounts'], isNotEmpty);
    final equityByPortfolio = {
      for (final account in (refreshed['accounts'] as List).cast<Map>())
        account['label']: account['equity'],
    };
    final generations = (refreshed['generationEquity'] as List).cast<Map>();
    expect(generations.map((row) => row['label']), equityByPortfolio.keys);
    for (final portfolio in generations) {
      final history = (portfolio['history'] as List).cast<Map>();
      expect(history.map((point) => point['generation']), [1, 2]);
      expect(history.last['value'], equityByPortfolio[portfolio['label']]);
    }
    final tested = (second['lastResults'] as List).cast<Map>().single;
    final strategy = generations.singleWhere(
      (row) => row['label'] == tested['label'],
    );
    expect(
      (strategy['history'] as List).last['trialValue'],
      tested['tunedValidation']['endingEquity'],
    );
    final original = await call('status?runId=$sourceId');
    expect(original['running'], isTrue);
    expect(original['startingCash'], 7000);
    final originalSnapshot = await call('snapshot?runId=$sourceId');
    expect(
      (originalSnapshot['accounts'] as List).cast<Map>().map(
        (row) => row['label'],
      ),
      unorderedEquals(['Fixture crossover', 'Buy & Hold']),
    );
    final originalSettings = original['configuration'] as Map;
    expect(
      ((originalSettings['strategies'] as List).single
          as Map)['intervalMinutes'],
      5,
    );
    final export = await call('export');
    expect(export['source'], 'running backend');
    final exportedRuns = (export['savedState']['runs'] as List).cast<Map>();
    expect(
      exportedRuns.map((run) => run['id']),
      containsAll([sourceId, previewId]),
    );
    final generationsExport = (export['generations'] as List).cast<Map>();
    expect(generationsExport.map((row) => row['generation']), [1, 2]);
    for (final generation in generationsExport) {
      final engine = generation['simulation']['runtime']['engines']['1'];
      expect(engine['bars']['SOXL'], hasLength(195));
      final performance = (generation['performance'] as List).cast<Map>();
      final strategy = performance.singleWhere(
        (row) => row['label'] == tested['label'],
      );
      final closedPnl =
          engine['accounts'][tested['label']]['closedPnl'] as List;
      expect(strategy['closedTrades'], closedPnl.length);
      expect(
        strategy['winRatePercent'],
        closedPnl.where((value) => value > 0).length / closedPnl.length * 100,
      );
      expect(generation['tuningResults'], isNotEmpty);
    }
    await call('research/stop', {});
    await backend.stop();
    stopped = true;
    final saved =
        jsonDecode(
              await File(
                '${directory.path}${Platform.pathSeparator}state.json',
              ).readAsString(),
            )
            as Map;
    expect(saved['selectedRunId'], sourceId);
    expect((saved['runs'] as List).cast<Map>().map((row) => row['id']), [
      sourceId,
    ]);
    final savedSource = (saved['runs'] as List).single as Map;
    expect(savedSource['researchSession']['cycles'], 2);
    expect(savedSource['generationResults'], hasLength(2));
    expect(savedSource['strategyBests'], isNotEmpty);
    final bestProfit =
        savedSource['strategyBests'][tested['label']]['profit'] as Map;
    final profits = generationsExport.map(
      (row) =>
          (row['performance'] as List).cast<Map>().singleWhere(
                (account) => account['label'] == tested['label'],
              )['netProfit']
              as num,
    );
    expect(
      bestProfit['performance']['netProfit'],
      greaterThanOrEqualTo(profits.reduce(max)),
    );
    expect(bestProfit['parameters'], isNotEmpty);
    expect(savedSource['researchSession']['history']['SOXL'], isNotEmpty);

    late _HistoryFixture resumedMarket;
    backend = LocalBackend(
      dataDirectory: directory,
      secureStorage: _FixtureStorage(),
      clock: () => DateTime.utc(2026, 5, 5, 15),
      schwabApiFactory: (storage, onQuote, onState) =>
          resumedMarket = _HistoryFixture(
            storage: storage,
            onQuote: onQuote,
            onState: onState,
            releaseHistory: Future<void>.value(),
          ),
    );
    stopped = false;
    await backend.start(port: port);
    final recovered = await call('status');
    expect(recovered['trainingSession']['cycles'], 2);
    final restoredChanges = await call(
      'runs/variable-changes?runId=$sourceId&generation=1',
    );
    expect(restoredChanges, changes);
    expect(recovered['strategyBests'][tested['label']]['profit'], bestProfit);
    await call('research/start', {
      'runId': sourceId,
      'evolutions': 21,
      'resume': true,
      'evolution': {
        'mutationAmount': .5,
        'additionalMutationProbability': .4,
        'candidatesPerGeneration': 6,
      },
    });
    await waitForCycle(3);
    await call('research/stop', {});
    await backend.stop();
    stopped = true;
    expect(resumedMarket.historyRequests, 0);
    final afterResume =
        jsonDecode(
              await File(
                '${directory.path}${Platform.pathSeparator}state.json',
              ).readAsString(),
            )
            as Map;
    final completed =
        (afterResume['runs'] as List).single['researchSession']['cycles']
            as int;
    expect(completed, greaterThanOrEqualTo(3));
    final allGenerations =
        (afterResume['runs'] as List).single['generationResults'] as List;
    expect(
      allGenerations.map((row) => row['generation']),
      List.generate(completed, (index) => index + 1),
    );
  });
}
