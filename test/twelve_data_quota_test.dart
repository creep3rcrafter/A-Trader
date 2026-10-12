import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:a_trade/market_data/alpaca_market_data_client.dart';
import 'package:a_trade/market_data/twelve_data_market_data_client.dart';

void main() {
  late Directory tempDirectory;
  late File ledgerFile;
  var now = DateTime.utc(2026, 10, 9, 20);

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp('twelve-quota-test-');
    ledgerFile = File(
      '${tempDirectory.path}${Platform.pathSeparator}quota.json',
    );
    now = DateTime.utc(2026, 10, 9, 20);
  });

  tearDown(() async {
    await tempDirectory.delete(recursive: true);
  });

  TwelveDataQuotaLedger ledger() =>
      TwelveDataQuotaLedger(ledgerFile: ledgerFile, clock: () => now);

  test(
    'enforces seven credits per rolling minute before writing each reserve',
    () async {
      final quota = ledger();
      for (var index = 0; index < 7; index++) {
        await quota.reserveCredit(maximumPerMinute: 7, maximumPerDay: 750);
      }
      await expectLater(
        quota.reserveCredit(maximumPerMinute: 7, maximumPerDay: 750),
        throwsA(
          isA<MarketDataException>().having(
            (error) => error.statusCode,
            'statusCode',
            HttpStatus.tooManyRequests,
          ),
        ),
      );
      final saved = jsonDecode(await ledgerFile.readAsString());
      expect(saved['dailyCredits'], 7);
      expect(saved['minuteCredits'], hasLength(7));

      now = now.add(const Duration(minutes: 1));
      await quota.reserveCredit(maximumPerMinute: 7, maximumPerDay: 750);
      expect(jsonDecode(await ledgerFile.readAsString())['dailyCredits'], 8);
    },
  );

  test(
    'serializes concurrent credit reservations against one ledger',
    () async {
      final results = await Future.wait(
        List.generate(10, (_) async {
          try {
            await ledger().reserveCredit(
              maximumPerMinute: 7,
              maximumPerDay: 750,
            );
            return true;
          } on MarketDataException {
            return false;
          }
        }),
      );
      expect(results.where((reserved) => reserved), hasLength(7));
      expect(jsonDecode(await ledgerFile.readAsString())['dailyCredits'], 7);
    },
  );

  test(
    'enforces the 750-credit daily cap independently of minute limit',
    () async {
      final quota = ledger();
      for (var index = 0; index < 750; index++) {
        await quota.reserveCredit(maximumPerMinute: 1000, maximumPerDay: 750);
      }
      await expectLater(
        quota.reserveCredit(maximumPerMinute: 1000, maximumPerDay: 750),
        throwsA(
          isA<MarketDataException>().having(
            (error) => error.message,
            'daily limit',
            contains('750 credits'),
          ),
        ),
      );
      expect(jsonDecode(await ledgerFile.readAsString())['dailyCredits'], 750);
    },
  );

  test('persists counts across instances and resets at UTC midnight', () async {
    await ledger().reserveCredit(maximumPerMinute: 7, maximumPerDay: 750);
    now = now.add(const Duration(seconds: 2));
    await ledger().reserveCredit(maximumPerMinute: 7, maximumPerDay: 750);
    expect(jsonDecode(await ledgerFile.readAsString())['dailyCredits'], 2);

    now = DateTime.utc(2026, 10, 10, 0);
    await ledger().reserveCredit(maximumPerMinute: 7, maximumPerDay: 750);
    final saved = jsonDecode(await ledgerFile.readAsString());
    expect(saved['utcDate'], '2026-10-10');
    expect(saved['dailyCredits'], 1);
  });

  test(
    'provider 429 halts requests through next UTC midnight and then resets',
    () async {
      now = DateTime.utc(2026, 10, 9, 23, 59, 59);
      final quota = ledger();
      await quota.reserveCredit(maximumPerMinute: 7, maximumPerDay: 750);
      await quota.haltUntilNextUtcDay();
      await expectLater(
        quota.reserveCredit(maximumPerMinute: 7, maximumPerDay: 750),
        throwsA(isA<MarketDataException>()),
      );
      now = now.add(const Duration(seconds: 61));
      await quota.reserveCredit(maximumPerMinute: 7, maximumPerDay: 750);
      expect(jsonDecode(await ledgerFile.readAsString())['dailyCredits'], 1);
    },
  );

  test(
    'fails closed on corrupt ledgers without replacing their contents',
    () async {
      await ledgerFile.writeAsString('not-json');
      await expectLater(
        ledger().reserveCredit(maximumPerMinute: 7, maximumPerDay: 750),
        throwsA(isA<MarketDataException>()),
      );
      expect(await ledgerFile.readAsString(), 'not-json');
    },
  );
}
