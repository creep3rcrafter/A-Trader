import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:atrader/live_runtime.dart';
import 'package:atrader/schwab_api.dart';
import 'package:atrader/secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _FixtureStorage extends SecureStorage {
  @override
  Future<Map<String, String>> load() async => {
    'accessToken': 'fixture',
    'expiresAtMs':
        '${DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch}',
  };
}

class _LoopbackHttpClient implements HttpClient {
  _LoopbackHttpClient(this.base);
  final Uri base;
  final HttpClient _client = HttpClient();

  @override
  Future<HttpClientRequest> getUrl(Uri url) {
    expect(url.path, '/trader/v1/userPreference');
    return _client.getUrl(base.resolve(url.path));
  }

  @override
  void close({bool force = false}) => _client.close(force: force);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'subscription changes share the socket and rejected updates can retry',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final base = Uri.parse('http://127.0.0.1:${server.port}');
      final connected = Completer<void>();
      final subscriptions = <String>[];
      var sockets = 0;
      var rejectNext = false;
      server.listen((request) async {
        if (!WebSocketTransformer.isUpgradeRequest(request)) {
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'streamerInfo': [
                {
                  'streamerSocketUrl': 'ws://127.0.0.1:${server.port}/stream',
                  'schwabClientCustomerId': 'fixture-customer',
                  'schwabClientCorrelId': 'fixture-correlation',
                  'schwabClientChannel': 'fixture-channel',
                  'schwabClientFunctionId': 'fixture-function',
                },
              ],
            }),
          );
          await request.response.close();
          return;
        }
        sockets++;
        final socket = await WebSocketTransformer.upgrade(request);
        socket.listen((message) {
          final decoded = jsonDecode(message as String) as Map<String, dynamic>;
          final commands = decoded['requests'] as List<dynamic>;
          for (final value in commands) {
            final command = value as Map<String, dynamic>;
            var code = 0;
            if (command['service'] == 'LEVELONE_EQUITIES') {
              subscriptions.add(command['parameters']['keys'] as String);
              if (rejectNext) {
                code = 1;
                rejectNext = false;
              }
            }
            socket.add(
              jsonEncode({
                'response': [
                  {
                    'service': command['service'],
                    'requestid': command['requestid'],
                    'content': {'code': code},
                  },
                ],
              }),
            );
          }
        });
      });
      final api = SchwabApi(
        storage: _FixtureStorage(),
        httpClient: _LoopbackHttpClient(base),
        onQuote: (_) {},
        onState: (state, reason) {
          if (state == FeedState.live && !connected.isCompleted) {
            connected.complete();
          }
        },
      );
      addTearDown(() async {
        await api.dispose();
        await server.close(force: true);
      });
      await api.startStreaming(['SOXL']);
      await connected.future.timeout(const Duration(seconds: 5));
      await api.updateStreamingSymbols(['SOXL', 'OKLO']);
      expect(sockets, 1);
      expect(subscriptions, ['SOXL', 'SOXL,OKLO']);
      await api.updateStreamingSymbols(['OKLO', 'SOXL']);
      expect(subscriptions, hasLength(2));
      rejectNext = true;
      await expectLater(
        api.updateStreamingSymbols(['SOXL', 'OKLO', 'SMR']),
        throwsStateError,
      );
      await api.updateStreamingSymbols(['SOXL', 'OKLO', 'SMR']);
      expect(sockets, 1);
      expect(subscriptions, [
        'SOXL',
        'SOXL,OKLO',
        'SOXL,OKLO,SMR',
        'SOXL,OKLO,SMR',
      ]);
    },
  );
}
