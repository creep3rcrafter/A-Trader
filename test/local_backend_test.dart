import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:atrader/local_backend.dart';
import 'package:atrader/mountain_time.dart';
import 'package:atrader/secure_storage.dart';
import 'package:atrader/simulator.dart';
import 'package:flutter_test/flutter_test.dart';

class _StalledStorage extends SecureStorage {
  _StalledStorage({super.directory});

  @override
  Future<Map<String, String>> load() => Completer<Map<String, String>>().future;
}

class _UnreadableStorage extends SecureStorage {
  _UnreadableStorage({super.directory});

  @override
  Future<Map<String, String>> load() async =>
      throw const SecureStorageException('Saved credentials are unreadable.');
}

class _FixtureStorage extends SecureStorage {
  int writes = 0;

  @override
  Future<Map<String, String>> load() async => {
    'appKey': 'fixture-client',
    'appSecret': 'fixture-secret',
  };

  @override
  Future<void> save(Map<String, String> secrets) async {
    writes++;
  }

  @override
  Future<void> remove() async {
    writes++;
  }
}

Future<int> _freePort() async {
  final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = probe.port;
  await probe.close();
  return port;
}

Future<({int status, String body})> _send(
  HttpClient client,
  String method,
  Uri uri, [
  Map<String, Object?>? json,
]) async {
  final request = await client.openUrl(method, uri);
  if (json != null) {
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(json));
  }
  final response = await request.close();
  return (
    status: response.statusCode,
    body: await utf8.decoder.bind(response).join(),
  );
}

void main() {
  late Directory directory;
  late HttpClient client;
  LocalBackend? backend;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('atrader-test-');
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await backend?.stop();
    backend = null;
    await directory.delete(recursive: true);
  });

  test('saved simulations can be named, renamed, and deleted', () async {
    final port = await _freePort();
    backend = LocalBackend(
      dataDirectory: directory,
      secureStorage: _FixtureStorage(),
    );
    await backend!.start(port: port);
    Future<Map<String, dynamic>> request(
      String path, [
      Map<String, Object?>? body,
    ]) async {
      final response = await _send(
        client,
        body == null ? 'GET' : 'POST',
        Uri.parse('http://127.0.0.1:$port/api/$path'),
        body,
      );
      expect(response.status, HttpStatus.ok, reason: response.body);
      return jsonDecode(response.body) as Map<String, dynamic>;
    }

    final source = (await request('status'))['runId'];
    final created = await request('runs/create', {'name': 'Test copy'});
    final copy = created['runId'];
    await request('runs/rename', {'runId': copy, 'name': 'Comparison'});
    expect((await request('status'))['runName'], 'Comparison');
    await request('runs/delete', {'runId': copy});
    expect((await request('status'))['runId'], source);
    expect((await request('runs'))['runs'], hasLength(1));
  });

  test('backend health stays available if credential loading stalls', () async {
    if (!Platform.isWindows) return;
    final port = await _freePort();
    backend = LocalBackend(
      dataDirectory: directory,
      secureStorage: _StalledStorage(directory: directory),
    );
    await backend!.start(port: port);

    final health = await _send(
      client,
      'GET',
      Uri.parse('http://127.0.0.1:$port/api/health'),
    );
    expect(health.status, HttpStatus.ok);
    expect(jsonDecode(health.body), {
      'service': 'atrader-backend',
      'apiVersion': 1,
    });
    final status = await _send(
      client,
      'GET',
      Uri.parse('http://127.0.0.1:$port/api/status'),
    );
    expect(
      (jsonDecode(status.body) as Map<String, dynamic>)['historicalTimeZones'],
      contains(MountainTime.zoneId),
    );
    final year = DateTime.now().toUtc().year - 1;
    final marchFirst = DateTime.utc(year, 3, 1);
    final secondSunday = 8 + (DateTime.sunday - marchFirst.weekday) % 7;
    final day = '$year-03-${secondSunday.toString().padLeft(2, '0')}';
    final missingHour = await _send(
      client,
      'POST',
      Uri.parse('http://127.0.0.1:$port/api/run/historical/start'),
      {
        'startDate': day,
        'endDate': day,
        'startTime': '02:30',
        'timeZone': MountainTime.zoneId,
      },
    );
    expect(missingHour.status, HttpStatus.badRequest);
    expect(missingHour.body, contains('does not exist in Mountain Time'));
  });

  test(
    'unreadable saved credentials are reported and can be replaced',
    () async {
      if (!Platform.isWindows) return;
      final port = await _freePort();
      backend = LocalBackend(
        dataDirectory: directory,
        secureStorage: _UnreadableStorage(directory: directory),
      );
      await backend!.start(port: port);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final status =
          jsonDecode(
                (await _send(
                  client,
                  'GET',
                  Uri.parse('http://127.0.0.1:$port/api/status'),
                )).body,
              )
              as Map<String, dynamic>;
      expect(status['lastError'], 'Saved credentials are unreadable.');
      expect(status['schwabCredentialsSaved'], isFalse);
    },
  );

  test(
    'saved credentials start OAuth with the registered callback listener',
    () async {
      if (!Platform.isWindows) return;
      final port = await _freePort();
      final callbackPort = await _freePort();
      final redirect = 'http://127.0.0.1:$callbackPort/oauth/schwab/callback';
      backend = LocalBackend(
        dataDirectory: directory,
        secureStorage: SecureStorage(directory: directory),
      );
      await backend!.start(port: port);
      final api = 'http://127.0.0.1:$port';

      final saved = await _send(
        client,
        'POST',
        Uri.parse('$api/api/schwab/credentials'),
        {
          'appKey': 'dummy-client-id',
          'appSecret': 'dummy-client-secret',
          'redirectUri': redirect,
        },
      );
      expect(saved.status, HttpStatus.ok, reason: saved.body);

      final started = await _send(
        client,
        'POST',
        Uri.parse('$api/api/schwab/oauth/start'),
        const {},
      );
      expect(started.status, HttpStatus.ok, reason: started.body);
      final startBody = jsonDecode(started.body) as Map<String, dynamic>;
      final authorization = Uri.parse(startBody['authorizationUrl'] as String);
      expect(authorization.host, 'api.schwabapi.com');
      expect(authorization.queryParameters['client_id'], 'dummy-client-id');
      expect(authorization.queryParameters['redirect_uri'], redirect);
      expect(startBody['callbackListening'], isTrue);
      expect(started.body, isNot(contains('dummy-client-secret')));

      final wrongState = await _send(
        client,
        'GET',
        Uri.parse('$redirect?code=dummy%40code&state=wrong'),
      );
      expect(wrongState.status, HttpStatus.badRequest);
      expect(wrongState.body, contains('OAuth state did not match'));

      final status =
          jsonDecode(
                (await _send(client, 'GET', Uri.parse('$api/api/status'))).body,
              )
              as Map<String, dynamic>;
      expect(status['schwabCredentialsSaved'], isTrue);
      expect(status['schwabAuthorized'], isFalse);
      expect(status['schwabRedirectUri'], redirect);
      expect(status['oauthCallbackListening'], isTrue);
    },
  );

  test(
    'pasted redirect addresses are validated before token exchange',
    () async {
      if (!Platform.isWindows) return;
      final port = await _freePort();
      backend = LocalBackend(
        dataDirectory: directory,
        secureStorage: SecureStorage(directory: directory),
      );
      await backend!.start(port: port);
      final api = 'http://127.0.0.1:$port';
      await _send(client, 'POST', Uri.parse('$api/api/schwab/credentials'), {
        'appKey': 'dummy-client-id',
        'appSecret': 'dummy-client-secret',
        'redirectUri': 'https://example.invalid/callback',
      });
      await _send(client, 'POST', Uri.parse('$api/api/schwab/oauth/start'), {});

      final missingCode = await _send(
        client,
        'POST',
        Uri.parse('$api/api/schwab/oauth/complete'),
        {'redirectedUrl': 'https://example.invalid/callback?state=x'},
      );
      expect(missingCode.status, HttpStatus.badRequest);
      expect(missingCode.body, contains('authorization code'));

      final denied = await _send(
        client,
        'POST',
        Uri.parse('$api/api/schwab/oauth/complete'),
        {
          'redirectedUrl':
              'https://example.invalid/callback?error=access_denied',
        },
      );
      expect(denied.status, HttpStatus.badRequest);
      expect(denied.body, contains('access_denied'));

      final wrongState = await _send(
        client,
        'POST',
        Uri.parse('$api/api/schwab/oauth/complete'),
        {
          'redirectedUrl':
              'https://example.invalid/callback?code=abc&state=bad',
        },
      );
      expect(wrongState.status, HttpStatus.badRequest);
      expect(wrongState.body, contains('OAuth state did not match'));
    },
  );

  test(
    'tune endpoint replays stored candles without changing the run',
    () async {
      final setting = StrategySettings(
        strategyId: 'ma_crossover_long_short',
        label: 'MA L/S',
        parameters: const {'fastPeriod': 3, 'slowPeriod': 8},
      );
      final engine = SimulatorEngine(
        watchlist: ['SOXL'],
        strategies: [setting],
        startingCash: 10000,
      );
      final start = DateTime.utc(2026, 5, 4, 13, 30);
      for (var index = 0; index < 160; index++) {
        final close =
            100 + 6 * ((index % 30) < 15 ? index % 15 : 15 - index % 15);
        engine.process(
          Candle(
            symbol: 'SOXL',
            time: start.add(Duration(minutes: index)),
            open: close.toDouble(),
            high: close + 1,
            low: close - 1,
            close: close.toDouble(),
            volume: 1000,
          ),
        );
      }
      final settings = {
        'watchlist': ['SOXL'],
        'startingCash': 10000.0,
        'strategies': [
          {
            'strategyId': setting.strategyId,
            'label': setting.label,
            'enabled': true,
            'intervalMinutes': 1,
            'parameters': setting.parameters,
          },
        ],
      };
      final stateFile = File('${directory.path}\\state.json');
      await stateFile.writeAsString(
        jsonEncode({
          'settings': settings,
          'runtime': {
            'running': false,
            'engines': {'1': engine.checkpoint()},
          },
        }),
      );
      final port = await _freePort();
      backend = LocalBackend(
        dataDirectory: directory,
        secureStorage: _FixtureStorage(),
      );
      await backend!.start(port: port);
      final response = await _send(
        client,
        'POST',
        Uri.parse('http://127.0.0.1:$port/api/runs/tune'),
        {'enableShortSelling': true},
      );
      expect(response.status, HttpStatus.ok, reason: response.body);
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      expect(body['enableShortSelling'], isTrue);
      expect(body['barsByInterval'], {'1': 160});
      final result = (body['results'] as List).single as Map<String, dynamic>;
      expect(result['label'], 'MA L/S');
      expect(result['status'], anyOf('improved', 'kept', 'insufficient'));
      final status =
          jsonDecode(
                (await _send(
                  client,
                  'GET',
                  Uri.parse('http://127.0.0.1:$port/api/status'),
                )).body,
              )
              as Map<String, dynamic>;
      final strategies =
          (status['configuration'] as Map<String, dynamic>)['strategies']
              as List;
      expect((strategies.single as Map)['parameters'], {
        'fastPeriod': 3.0,
        'slowPeriod': 8.0,
      });
    },
  );

  test('reset clears persisted run data but retains configuration', () async {
    final strategy = StrategyRegistry.all.first;
    final setting = StrategySettings(
      strategyId: strategy.id,
      label: 'Fixture portfolio',
    );
    final engine = SimulatorEngine(
      watchlist: ['SOXL'],
      strategies: [setting],
      startingCash: 12000,
    );
    final time = DateTime.utc(2026, 11, 16, 15);
    final account = engine.accounts[setting.label]!;
    account.cash = 11000;
    account.positions['SOXL'] = SimulatedPosition(
      symbol: 'SOXL',
      quantity: 10,
      entryPrice: 100,
      entryTime: time,
      stop: 95,
      target: 110,
    );
    account.pending.add(
      SimulatedOrder(
        symbol: 'SOXL',
        action: TradeAction.sell,
        quantity: 10,
        signalTime: time,
        stop: null,
        target: null,
        reason: 'Fixture order',
      ),
    );
    account.history.add(EquityPoint(time, 12000));
    account.events.add(
      DecisionEvent(
        strategy: setting.label,
        symbol: 'SOXL',
        time: time,
        action: TradeAction.buy,
        kind: 'fill',
        reason: 'Fixture fill',
      ),
    );
    final stateFile = File('${directory.path}\\state.json');
    await stateFile.writeAsString(
      jsonEncode({
        'settings': {
          'watchlist': ['SOXL'],
          'startingCash': 12000.0,
          'strategies': [
            {
              'strategyId': strategy.id,
              'label': setting.label,
              'enabled': true,
              'intervalMinutes': 1,
              'parameters': <String, double>{},
            },
          ],
        },
        'lmStudio': {'url': 'http://localhost:1234', 'model': 'fixture'},
        'runtime': {
          'running': true,
          'engines': {'1': engine.checkpoint()},
        },
      }),
    );
    final legacyState = jsonDecode(await stateFile.readAsString());
    final storage = _FixtureStorage();
    final port = await _freePort();
    backend = LocalBackend(dataDirectory: directory, secureStorage: storage);
    await backend!.start(port: port);
    final api = 'http://127.0.0.1:$port/api';

    final before =
        jsonDecode(
              (await _send(client, 'GET', Uri.parse('$api/snapshot'))).body,
            )
            as Map<String, dynamic>;
    expect(before['accounts'], isNotEmpty);
    expect((before['status'] as Map<String, dynamic>)['running'], isTrue);
    final rejected = await _send(
      client,
      'POST',
      Uri.parse('$api/run/reset'),
      {},
    );
    expect(rejected.status, HttpStatus.badRequest);
    expect(rejected.body, contains('Stop the current run'));
    final stillPresent =
        jsonDecode(
              (await _send(client, 'GET', Uri.parse('$api/snapshot'))).body,
            )
            as Map<String, dynamic>;
    expect(stillPresent['accounts'], isNotEmpty);

    final stopped = await _send(client, 'POST', Uri.parse('$api/run/stop'), {});
    expect(stopped.status, HttpStatus.ok);
    final reset = await _send(client, 'POST', Uri.parse('$api/run/reset'), {});
    expect(reset.status, HttpStatus.ok, reason: reset.body);
    expect(jsonDecode(reset.body), {'cleared': true});
    final snapshot =
        jsonDecode(
              (await _send(client, 'GET', Uri.parse('$api/snapshot'))).body,
            )
            as Map<String, dynamic>;
    expect(snapshot['accounts'], isEmpty);
    expect(snapshot['candles'], isEmpty);
    final log =
        jsonDecode((await _send(client, 'GET', Uri.parse('$api/log'))).body)
            as Map<String, dynamic>;
    expect(log['events'], isEmpty);
    final saved = jsonDecode(await stateFile.readAsString()) as Map;
    expect((saved['runtime'] as Map)['running'], isFalse);
    expect((saved['runtime'] as Map)['engines'], isNull);
    expect((saved['settings'] as Map)['startingCash'], 12000);
    expect((saved['lmStudio'] as Map)['model'], 'fixture');
    expect(await File('${stateFile.path}.bak').exists(), isFalse);
    final legacyBackup = File('${directory.path}\\state-before-multi-run.json');
    expect(jsonDecode(await legacyBackup.readAsString()), legacyState);
    expect(storage.writes, 0);

    await backend!.stop();
    backend = LocalBackend(dataDirectory: directory, secureStorage: storage);
    await backend!.start(port: port);
    final afterRestart =
        jsonDecode(
              (await _send(client, 'GET', Uri.parse('$api/snapshot'))).body,
            )
            as Map<String, dynamic>;
    expect(afterRestart['accounts'], isEmpty);
    expect((afterRestart['status'] as Map)['running'], isFalse);
    expect((afterRestart['status'] as Map)['watchlist'], ['SOXL']);
    expect((afterRestart['status'] as Map)['startingCash'], 12000);
    expect(storage.writes, 0);
  });

  test('reset reports a persistence failure instead of success', () async {
    final port = await _freePort();
    backend = LocalBackend(
      dataDirectory: directory,
      secureStorage: _FixtureStorage(),
    );
    await backend!.start(port: port);
    final temporaryPath = Directory('${directory.path}\\state.json.tmp');
    await temporaryPath.create();
    final result = await _send(
      client,
      'POST',
      Uri.parse('http://127.0.0.1:$port/api/run/reset'),
      {},
    );
    expect(result.status, HttpStatus.badRequest);
    expect(result.body, contains('cleared in memory but could not be saved'));
    await temporaryPath.delete();
  });
}
