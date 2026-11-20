/// Starts the bundled Windows service without tying its lifetime to Flutter.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

typedef BackendProcessStarter =
    Future<void> Function(
      String executable,
      List<String> arguments,
      String workingDirectory,
    );

class WindowsBackendLauncher {
  WindowsBackendLauncher({
    required this.baseUrl,
    String? applicationExecutable,
    BackendProcessStarter? startProcess,
    this.startupTimeout = const Duration(seconds: 20),
    this.pollInterval = const Duration(milliseconds: 250),
  }) : _applicationExecutable =
           applicationExecutable ?? Platform.resolvedExecutable,
       _startProcess = startProcess ?? _startDetached;

  final String baseUrl;
  final String _applicationExecutable;
  final BackendProcessStarter _startProcess;
  final Duration startupTimeout;
  final Duration pollInterval;
  Future<void>? _starting;

  /// Reuses a healthy service and reports conflicts instead of replacing it.
  Future<void> start() => _starting ??= _start().whenComplete(() {
    _starting = null;
  });

  Future<void> _start() async {
    if (!Platform.isWindows) {
      throw UnsupportedError('Starting the backend is supported on Windows.');
    }
    final uri = Uri.parse(baseUrl);
    if (uri.scheme != 'http' ||
        !const {'127.0.0.1', 'localhost'}.contains(uri.host) ||
        uri.userInfo.isNotEmpty ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.port < 1 ||
        uri.port > 65535) {
      throw ArgumentError('The Windows backend must use a local HTTP address.');
    }
    final healthUri = uri.replace(path: '/api/health');
    if (await _isReady(healthUri)) return;

    final directory = File(_applicationExecutable).parent;
    final executable = File('${directory.path}\\atrader_backend.exe');
    if (!await executable.exists()) {
      throw StateError(
        'The bundled atrader_backend.exe is missing. Rebuild with '
        '"flutter build windows" and keep the complete Windows bundle together.',
      );
    }
    await _startProcess(executable.path, [
      '${uri.port}',
      '--background',
    ], directory.path);

    final elapsed = Stopwatch()..start();
    while (elapsed.elapsed < startupTimeout) {
      if (await _isReady(healthUri)) return;
      await Future<void>.delayed(pollInterval);
    }
    throw TimeoutException(
      'The backend did not become ready at $baseUrl. Check '
      r'%LOCALAPPDATA%\ATrader\backend-startup.log and retry.',
      startupTimeout,
    );
  }

  Future<bool> _isReady(Uri uri) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 1);
    try {
      final HttpClientRequest request;
      try {
        request = await client.getUrl(uri).timeout(const Duration(seconds: 1));
      } on TimeoutException {
        // Windows can time out a closed port before reporting refusal.
        return false;
      }
      request.followRedirects = false;
      final response = await request.close().timeout(
        const Duration(seconds: 1),
      );
      final text = await utf8.decoder
          .bind(response)
          .join()
          .timeout(const Duration(seconds: 1));
      if (response.statusCode != HttpStatus.ok) {
        throw StateError(
          'Port ${uri.port} is occupied by a service that is not a compatible '
          'A-Trader backend. Close that service or an older backend first.',
        );
      }
      final value = jsonDecode(text);
      if (value is! Map<String, dynamic> ||
          value['service'] != 'atrader-backend' ||
          value['apiVersion'] != 1) {
        throw StateError(
          'Port ${uri.port} is not serving a compatible A-Trader backend.',
        );
      }
      return true;
    } on SocketException {
      return false;
    } on FormatException {
      throw StateError(
        'Port ${uri.port} returned an invalid backend health response.',
      );
    } on TimeoutException {
      throw StateError(
        'The service on port ${uri.port} is not responding. Check the existing '
        'service before starting another backend.',
      );
    } finally {
      client.close(force: true);
    }
  }

  static Future<void> _startDetached(
    String executable,
    List<String> arguments,
    String workingDirectory,
  ) async {
    await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      mode: ProcessStartMode.detached,
    );
  }
}
