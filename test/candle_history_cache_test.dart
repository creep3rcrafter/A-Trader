import 'dart:io';

import 'package:atrader/candle_history_cache.dart';
import 'package:atrader/historical_replay.dart';
import 'package:atrader/local_backend.dart';
import 'package:atrader/schwab_api.dart';
import 'package:atrader/secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

MinuteBar bar(int day, {String symbol = 'SOXL', int minute = 30}) => MinuteBar(
  symbol: symbol,
  openTime: DateTime.utc(2026, 11, day, 14, minute),
  open: 100,
  high: 101,
  low: 99,
  close: 100,
  volume: 1000,
);

class _CacheStorage extends SecureStorage {
  @override
  Future<Map<String, String>> load() async => {
    'appKey': 'fixture',
    'appSecret': 'fixture',
    'refreshToken': 'fixture',
  };
}

class _CacheMarket extends SchwabApi {
  _CacheMarket({
    required super.storage,
    required super.onQuote,
    required super.onState,
    required this.record,
  });
  final void Function() record;
  @override
  Future<List<MinuteBar>> fetchMinuteBars({
    required String symbol,
    required DateTime startUtc,
    required DateTime endUtc,
  }) async {
    record();
    return [bar(20, symbol: symbol)];
  }
}

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('candle-cache-');
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test(
    'authorized backend collects completed days and reuses them after restart',
    () async {
      var downloads = 0;
      LocalBackend? backend;
      Future<void> start() async {
        final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final port = socket.port;
        await socket.close();
        backend = LocalBackend(
          dataDirectory: directory,
          secureStorage: _CacheStorage(),
          autoCollectCandles: true,
          historyClock: () => DateTime.utc(2026, 11, 20, 22),
          schwabApiFactory: (storage, onQuote, onState) => _CacheMarket(
            storage: storage,
            onQuote: onQuote,
            onState: onState,
            record: () => downloads++,
          ),
        );
        await backend!.start(port: port);
      }

      try {
        await start();
        final timer = Stopwatch()..start();
        while (!await File(
          '${directory.path}/candles/1m/SMR/2026-11-20.json.gz',
        ).exists()) {
          if (timer.elapsed > const Duration(seconds: 10)) {
            fail('Daily collection did not finish.');
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(downloads, greaterThan(0));
        await backend!.stop();
        backend = null;
        final before = downloads;
        await start();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(downloads, before);
      } finally {
        await backend?.stop();
      }
    },
  );

  test(
    'completed daily candles survive restart and subranges need no download',
    () async {
      var requests = 0;
      final cache = CandleHistoryCache(
        directory: directory,
        clock: () => DateTime.utc(2026, 11, 20),
        download:
            ({required symbol, required startUtc, required endUtc}) async {
              requests++;
              expect(startUtc, DateTime.utc(2026, 11, 18));
              expect(endUtc, DateTime.utc(2026, 11, 19));
              return [bar(18), bar(18, minute: 31), bar(18, minute: 31)];
            },
      );
      final first = await cache.fetch(
        symbol: 'SOXL',
        startUtc: DateTime.utc(2026, 11, 18, 14, 30),
        endUtc: DateTime.utc(2026, 11, 18, 15),
      );
      expect(first, hasLength(2));
      expect(requests, 1);
      final reopened = CandleHistoryCache(
        directory: directory,
        clock: () => DateTime.utc(2026, 11, 20),
        download:
            ({required symbol, required startUtc, required endUtc}) async =>
                throw StateError('Offline'),
      );
      await reopened.initialize();
      final second = await reopened.fetch(
        symbol: 'SOXL',
        startUtc: DateTime.utc(2026, 11, 18, 14, 31),
        endUtc: DateTime.utc(2026, 11, 18, 15),
      );
      expect(second.single.openTime, DateTime.utc(2026, 11, 18, 14, 31));
      expect(reopened.status['storedDays'], 1);
      expect(
        await reopened.latestCompleteDay('SOXL'),
        DateTime.utc(2026, 11, 18),
      );
      expect(reopened.cacheHits, 1);
    },
  );

  test(
    'overlapping callers share downloads and request only missing days',
    () async {
      final requests = <({DateTime start, DateTime end})>[];
      final cache = CandleHistoryCache(
        directory: directory,
        clock: () => DateTime.utc(2026, 11, 20),
        download:
            ({required symbol, required startUtc, required endUtc}) async {
              requests.add((start: startUtc, end: endUtc));
              await Future<void>.delayed(const Duration(milliseconds: 10));
              return [bar(18), bar(19)];
            },
      );
      await Future.wait([
        for (var i = 0; i < 3; i++)
          cache.fetch(
            symbol: 'SOXL',
            startUtc: DateTime.utc(2026, 11, 18),
            endUtc: DateTime.utc(2026, 11, 19),
          ),
      ]);
      expect(requests, hasLength(1));
      await cache.fetch(
        symbol: 'SOXL',
        startUtc: DateTime.utc(2026, 11, 18),
        endUtc: DateTime.utc(2026, 11, 20),
      );
      expect(requests, hasLength(2));
      expect(requests.last.start, DateTime.utc(2026, 11, 19));
    },
  );

  test(
    'current days refresh and empty old responses do not become final',
    () async {
      var now = DateTime.utc(2026, 11, 20, 15), requests = 0;
      final cache = CandleHistoryCache(
        directory: directory,
        clock: () => now,
        download:
            ({required symbol, required startUtc, required endUtc}) async {
              requests++;
              return startUtc.day == 20 ? [bar(20)] : [];
            },
      );
      Future<List<MinuteBar>> fetch(int day) => cache.fetch(
        symbol: 'SOXL',
        startUtc: DateTime.utc(2026, 11, day),
        endUtc: DateTime.utc(2026, 11, day, 15),
      );
      await fetch(20);
      await fetch(20);
      expect(requests, 1);
      expect(await cache.latestCompleteDay('SOXL'), isNull);
      now = now.add(const Duration(minutes: 2));
      await fetch(20);
      expect(requests, 2);
      await fetch(18);
      await fetch(18);
      expect(requests, 4);
    },
  );

  test(
    'saved full-session history seeds the cache without a network call',
    () async {
      final cache = CandleHistoryCache(
        directory: directory,
        clock: () => DateTime.utc(2026, 11, 20),
        download:
            ({required symbol, required startUtc, required endUtc}) async =>
                throw StateError('Should use saved history'),
      );
      await cache.remember('SOXL', [
        bar(18),
        MinuteBar(
          symbol: 'SOXL',
          openTime: DateTime.utc(2026, 11, 18, 20, 59),
          open: 100,
          high: 101,
          low: 99,
          close: 100,
          volume: 1000,
        ),
      ]);
      expect(
        await cache.fetch(
          symbol: 'SOXL',
          startUtc: DateTime.utc(2026, 11, 18),
          endUtc: DateTime.utc(2026, 11, 19),
        ),
        hasLength(2),
      );
    },
  );
}
