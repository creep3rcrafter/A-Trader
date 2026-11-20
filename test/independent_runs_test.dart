import 'dart:convert';
import 'dart:io';

import 'package:atrader/live_runtime.dart';
import 'package:atrader/local_backend.dart';
import 'package:atrader/schwab_api.dart';
import 'package:atrader/secure_storage.dart';
import 'package:atrader/simulator.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryStorage extends SecureStorage {
  @override
  Future<Map<String, String>> load() async => {
    'appKey': 'fixture',
    'appSecret': 'fixture',
    'refreshToken': 'fixture',
  };
}

class _MarketDataFixture extends SchwabApi {
  _MarketDataFixture(
    SecureStorage storage,
    void Function(LiveQuote) onQuote,
    void Function(FeedState, String) onState,
  ) : super(storage: storage, onQuote: onQuote, onState: onState);

  List<String> symbols = [];

  @override
  Future<void> startStreaming(List<String> symbols) async {
    this.symbols = symbols;
    onState(FeedState.live, 'Fixture market-data connection');
  }

  @override
  Future<void> updateStreamingSymbols(List<String> symbols) async {
    this.symbols = symbols;
  }
}

void main() {
  test(
    'simultaneous runs receive quotes independently and survive restart',
    () async {
      final directory = await Directory.systemTemp.createTemp('atrader-runs-');
      final storage = _MemoryStorage();
      var now = DateTime.utc(2026, 11, 16, 15);
      late _MarketDataFixture market;
      var backend = LocalBackend(
        dataDirectory: directory,
        secureStorage: storage,
        clock: () => now,
        schwabApiFactory: (storage, onQuote, onState) =>
            market = _MarketDataFixture(storage, onQuote, onState),
      );
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = probe.port;
      await probe.close();
      final client = HttpClient();
      addTearDown(() async {
        client.close(force: true);
        await backend.stop();
        await directory.delete(recursive: true);
      });
      final base = 'http://127.0.0.1:$port/api';
      Future<Map<String, dynamic>> call(
        String endpoint, [
        Map<String, Object?>? body,
        int expectedStatus = HttpStatus.ok,
      ]) async {
        final request = await client.openUrl(
          body == null ? 'GET' : 'POST',
          Uri.parse('$base/$endpoint'),
        );
        if (body != null) {
          request.headers.contentType = ContentType.json;
          request.write(jsonEncode(body));
        }
        final response = await request.close();
        final decoded =
            jsonDecode(await utf8.decoder.bind(response).join())
                as Map<String, dynamic>;
        expect(response.statusCode, expectedStatus, reason: decoded.toString());
        return decoded;
      }

      Map<String, Object?> configuration(double cash, String symbol) => {
        'watchlist': [symbol],
        'startingCash': cash,
        'strategies': [
          {
            'strategyId': 'ma_crossover',
            'label': 'Independent MA',
            'intervalMinutes': 1,
            'enabled': true,
            'parameters': <String, double>{},
          },
        ],
      };

      await backend.start(port: port);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await call('settings/run', configuration(10000, 'SOXL'));
      await call('schwab/connect', {});
      await call('run/start', {});
      await call('run/start', {}, HttpStatus.badRequest);
      await call(
        'settings/run',
        configuration(999, 'SMR'),
        HttpStatus.badRequest,
      );
      final firstId = (await call('status'))['runId'];
      final created = await call('runs/create', {
        'name': 'Second portfolio',
        'configuration': configuration(25000, 'OKLO'),
      });
      final secondId = created['runId'];
      expect(market.symbols, containsAll(['SOXL', 'OKLO']));
      await call('run/start', {});
      for (final symbol in ['SOXL', 'OKLO']) {
        market.onQuote(
          LiveQuote(
            symbol: symbol,
            time: now,
            bid: 100,
            ask: 101,
            last: 100.5,
            volume: 100,
            realTime: true,
          ),
        );
      }
      final first = await call('status?runId=$firstId');
      final second = await call('status?runId=$secondId');
      expect(first['running'], isTrue);
      expect(second['running'], isTrue);
      expect(first['startingCash'], 10000);
      expect(second['startingCash'], 25000);
      expect(first['symbols']['SOXL']['state'], 'live');
      expect(second['symbols']['OKLO']['state'], 'live');
      for (var minute = 1; minute <= 7; minute++) {
        now = now.add(const Duration(minutes: 1));
        for (final symbol in ['SOXL', 'OKLO']) {
          market.onQuote(
            LiveQuote(
              symbol: symbol,
              time: now,
              bid: 100 + minute * .1,
              ask: 101 + minute * .1,
              last: 100.5 + minute * .1,
              volume: 100.0 + minute * 100,
              realTime: true,
            ),
          );
        }
      }
      final collected = await call('status');
      expect(collected['training']['maturedExamples'], greaterThan(0));
      expect(collected['pinnedModels']['neural_network'], isNull);
      expect(collected['pinnedModels']['logistic_regression'], isNull);
      await call('run/stop', {});
      await call('run/reset', {});
      expect((await call('snapshot'))['accounts'], isEmpty);
      expect((await call('status?runId=$firstId'))['running'], isTrue);
      await call('runs/select', {'runId': firstId});
      await call('run/stop', {});
      final before = await call('snapshot');
      expect(before['accounts'], isNotEmpty);
      await backend.stop();
      backend = LocalBackend(
        dataDirectory: directory,
        secureStorage: storage,
        clock: () => now,
        schwabApiFactory: (storage, onQuote, onState) =>
            market = _MarketDataFixture(storage, onQuote, onState),
      );
      await backend.start(port: port);
      expect((await call('runs'))['runs'], hasLength(2));
      final restored = await call('snapshot?runId=$firstId');
      expect(restored['accounts'], before['accounts']);
      expect((await call('status?runId=$secondId'))['running'], isFalse);
    },
  );
}
