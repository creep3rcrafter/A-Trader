import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:atrader/backend_launcher.dart';
import 'package:flutter_test/flutter_test.dart';

Future<int> _unusedPort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

Future<HttpServer> _serveHealth({
  int port = 0,
  String body = '{"service":"atrader-backend","apiVersion":1}',
  int statusCode = HttpStatus.ok,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  server.listen((request) async {
    expect(request.uri.path, '/api/health');
    request.response
      ..statusCode = statusCode
      ..headers.contentType = ContentType.json
      ..write(body);
    await request.response.close();
  });
  addTearDown(() => server.close(force: true));
  return server;
}

void main() {
  group('Windows backend launcher', skip: !Platform.isWindows, () {
    late Directory directory;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp(
        'atrader launcher test ',
      );
      addTearDown(() => directory.delete(recursive: true));
    });

    WindowsBackendLauncher launcher(
      int port, {
      required BackendProcessStarter startProcess,
      Duration startupTimeout = const Duration(seconds: 2),
    }) => WindowsBackendLauncher(
      baseUrl: 'http://127.0.0.1:$port',
      applicationExecutable: '${directory.path}\\atrader.exe',
      startProcess: startProcess,
      startupTimeout: startupTimeout,
      pollInterval: const Duration(milliseconds: 10),
    );

    test(
      'reuses an existing service without requiring a bundled file',
      () async {
        final server = await _serveHealth();
        var launches = 0;
        await launcher(
          server.port,
          startProcess: (_, _, _) async => launches++,
        ).start();

        expect(launches, 0);
      },
    );

    test(
      'restart waits for the old backend to close before launching',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final port = server.port;
        await File('${directory.path}\\atrader_backend.exe').create();
        var stopAcknowledged = false;
        server.listen((request) async {
          if (request.uri.path == '/api/backend/shutdown') {
            expect(request.method, 'POST');
            expect(request.headers.value('x-atrader-control'), 'restart');
            request.response.write('{"stopping":true}');
            await request.response.close();
            await Future<void>.delayed(const Duration(milliseconds: 50));
            stopAcknowledged = true;
            await server.close(force: true);
            return;
          }
          request.response.write(
            '{"service":"atrader-backend","apiVersion":1}',
          );
          await request.response.close();
        });
        final service = launcher(
          port,
          startProcess: (_, _, _) async {
            expect(stopAcknowledged, isTrue);
            await _serveHealth(port: port);
          },
        );
        await service.restart();
      },
    );

    test('waits for a backend that is already loading saved data', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var probes = 0;
      server.listen((request) async {
        request.response.write(
          jsonEncode({
            'service': 'atrader-backend',
            'apiVersion': 1,
            'ready': ++probes >= 3,
          }),
        );
        await request.response.close();
      });
      var launches = 0;
      await launcher(
        server.port,
        startProcess: (_, _, _) async {
          launches++;
        },
      ).start();
      expect(probes, 3);
      expect(launches, 0);
    });

    test('reports a missing bundled executable without spawning', () async {
      final port = await _unusedPort();
      var launches = 0;
      await expectLater(
        launcher(port, startProcess: (_, _, _) async => launches++).start(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('atrader_backend.exe is missing'),
          ),
        ),
      );
      expect(launches, 0);
    });

    test(
      'starts the sibling executable and waits for HTTP readiness',
      () async {
        final port = await _unusedPort();
        final executable = await File(
          '${directory.path}\\atrader_backend.exe',
        ).create();
        final processStarted = Completer<void>();
        var launches = 0;
        final service = launcher(
          port,
          startProcess: (path, arguments, workingDirectory) async {
            expect(path, executable.path);
            expect(arguments, ['$port', '--background']);
            expect(workingDirectory, directory.path);
            launches++;
            processStarted.complete();
          },
        );
        var ready = false;
        final startup = service.start().then((_) => ready = true);
        await processStarted.future;
        expect(ready, isFalse);
        await _serveHealth(port: port);
        await startup;
        await service.start();

        expect(ready, isTrue);
        expect(launches, 1);
      },
    );

    test('coalesces overlapping starts', () async {
      final port = await _unusedPort();
      await File('${directory.path}\\atrader_backend.exe').create();
      final processStarted = Completer<void>();
      var launches = 0;
      final service = launcher(
        port,
        startProcess: (_, _, _) async {
          launches++;
          processStarted.complete();
        },
      );
      final first = service.start();
      final second = service.start();
      expect(identical(first, second), isTrue);
      await processStarted.future;
      await _serveHealth(port: port);
      await Future.wait([first, second]);
      expect(launches, 1);
    });

    for (final body in [
      jsonEncode({'service': 'unrelated-service', 'apiVersion': 1}),
      jsonEncode({'service': 'atrader-backend', 'apiVersion': 99}),
      'not JSON',
    ]) {
      test('rejects an incompatible service: $body', () async {
        final server = await _serveHealth(body: body);
        var launches = 0;
        await expectLater(
          launcher(
            server.port,
            startProcess: (_, _, _) async => launches++,
          ).start(),
          throwsA(isA<StateError>()),
        );
        expect(launches, 0);
      });
    }

    test(
      'reports an occupied HTTP port instead of launching over it',
      () async {
        final server = await _serveHealth(statusCode: HttpStatus.notFound);
        var launches = 0;
        await expectLater(
          launcher(
            server.port,
            startProcess: (_, _, _) async => launches++,
          ).start(),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('occupied'),
            ),
          ),
        );
        expect(launches, 0);
      },
    );

    test('does not spawn over a listener that never answers HTTP', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((_) {});
      addTearDown(() => server.close(force: true));
      var launches = 0;
      await expectLater(
        launcher(
          server.port,
          startProcess: (_, _, _) async => launches++,
        ).start(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('not responding'),
          ),
        ),
      );
      expect(launches, 0);
    });

    test('a spawned process alone is not considered a ready backend', () async {
      final port = await _unusedPort();
      await File('${directory.path}\\atrader_backend.exe').create();
      await expectLater(
        launcher(
          port,
          startProcess: (_, _, _) async {},
          startupTimeout: const Duration(milliseconds: 40),
        ).start(),
        throwsA(
          isA<TimeoutException>().having(
            (error) => error.message,
            'message',
            contains('backend-startup.log'),
          ),
        ),
      );
    });

    test('surfaces a process launch failure', () async {
      final port = await _unusedPort();
      await File('${directory.path}\\atrader_backend.exe').create();
      await expectLater(
        launcher(
          port,
          startProcess: (_, _, _) async {
            throw const ProcessException('atrader_backend.exe', [], 'Denied');
          },
        ).start(),
        throwsA(isA<ProcessException>()),
      );
    });

    test('does not launch a backend for a non-local address', () async {
      var launches = 0;
      final service = WindowsBackendLauncher(
        baseUrl: 'http://example.invalid:8787',
        startProcess: (_, _, _) async => launches++,
      );
      await expectLater(service.start(), throwsArgumentError);
      expect(launches, 0);
    });
  });
}
