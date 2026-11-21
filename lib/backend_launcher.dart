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
typedef BundledBackendStopper =
    Future<void> Function(String executable, int port);

enum _BackendHealth { absent, loading, ready, stopping }

class WindowsBackendLauncher {
  WindowsBackendLauncher({
    required this.baseUrl,
    String? applicationExecutable,
    BackendProcessStarter? startProcess,
    BundledBackendStopper? stopBundledBackend,
    this.startupTimeout = const Duration(seconds: 30),
    this.pollInterval = const Duration(milliseconds: 250),
  }) : _applicationExecutable =
           applicationExecutable ?? Platform.resolvedExecutable,
       _startProcess = startProcess ?? _startDetached,
       _stopBundledBackend = stopBundledBackend ?? _stopMatchingWindowsProcess;

  final String baseUrl;
  final String _applicationExecutable;
  final BackendProcessStarter _startProcess;
  final BundledBackendStopper _stopBundledBackend;
  final Duration startupTimeout;
  final Duration pollInterval;
  Future<void>? _starting;

  /// Reuses a healthy service and reports conflicts instead of replacing it.
  Future<void> start() => _launch(restart: false);
  Future<void> restart() => _launch(restart: true);

  Future<void> _launch({required bool restart}) =>
      _starting ??= _start(restart: restart).whenComplete(() {
        _starting = null;
      });

  Future<void> _start({required bool restart}) async {
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
    final directory = File(_applicationExecutable).parent;
    final executable = File('${directory.path}\\atrader_backend.exe');
    final initialHealth = restart
        ? _BackendHealth.absent
        : await _health(healthUri);
    if (initialHealth == _BackendHealth.ready) return;
    final shouldLaunch =
        initialHealth == _BackendHealth.absent ||
        initialHealth == _BackendHealth.stopping;
    if (shouldLaunch && !await executable.exists()) {
      throw StateError(
        'The bundled atrader_backend.exe is missing. Rebuild with '
        '"flutter build windows" and keep the complete Windows bundle together.',
      );
    }
    if (restart || initialHealth == _BackendHealth.stopping) {
      await _stopExisting(uri, executable.path);
    }
    if (shouldLaunch) {
      await _startProcess(executable.path, [
        '${uri.port}',
        '--background',
      ], directory.path);
    }

    final elapsed = Stopwatch()..start();
    while (elapsed.elapsed < startupTimeout) {
      if (await _health(healthUri) == _BackendHealth.ready) return;
      await Future<void>.delayed(pollInterval);
    }
    throw TimeoutException(
      'The backend did not become ready at $baseUrl. Check '
      r'%LOCALAPPDATA%\ATrader\backend-startup.log and retry.',
      startupTimeout,
    );
  }

  Future<void> _stopExisting(Uri uri, String executable) async {
    if (!await _portInUse(uri)) return;
    _BackendHealth health;
    try {
      health = await _health(uri.replace(path: '/api/health'));
    } on StateError {
      // A stalled app-owned process can still be identified by its socket and
      // exact executable path. The fallback rejects other port owners.
      health = _BackendHealth.absent;
    }
    if (health != _BackendHealth.stopping &&
        (health != _BackendHealth.ready || !await _requestShutdown(uri))) {
      await _stopBundledBackend(executable, uri.port);
    }
    final clock = Stopwatch()..start();
    while (await _portInUse(uri)) {
      if (clock.elapsed >= startupTimeout) {
        await _stopBundledBackend(executable, uri.port);
        final forced = Stopwatch()..start();
        while (await _portInUse(uri)) {
          if (forced.elapsed >= const Duration(seconds: 3)) {
            throw StateError('The existing backend could not be stopped.');
          }
          await Future<void>.delayed(pollInterval);
        }
        return;
      }
      await Future<void>.delayed(pollInterval);
    }
  }

  Future<bool> _requestShutdown(Uri uri) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 1);
    try {
      final request = await client.postUrl(
        uri.replace(path: '/api/backend/shutdown'),
      );
      request.followRedirects = false;
      request.headers.set('x-atrader-control', 'restart');
      final response = await request.close().timeout(
        const Duration(seconds: 2),
      );
      if (response.statusCode == HttpStatus.notFound) return false;
      if (response.statusCode != HttpStatus.ok) {
        throw StateError('The backend refused the restart request.');
      }
      await response.drain<void>().timeout(const Duration(seconds: 2));
      return true;
    } finally {
      client.close(force: true);
    }
  }

  Future<bool> _portInUse(Uri uri) async {
    try {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        uri.port,
        timeout: const Duration(milliseconds: 300),
      );
      socket.destroy();
      return true;
    } on SocketException {
      return false;
    } on TimeoutException {
      return false;
    }
  }

  static Future<void> _stopMatchingWindowsProcess(
    String executable,
    int port,
  ) async {
    final result = await Process.run(
      'powershell.exe',
      [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        r'''
$ErrorActionPreference = 'Stop'
$port = [int]$env:ATRADER_RESTART_PORT
$owners = @(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue |
  Where-Object { $_.LocalAddress -in ('127.0.0.1', '0.0.0.0', '::', '::1') } |
  Select-Object -ExpandProperty OwningProcess -Unique)
if ($owners.Count -ne 1) { exit 2 }
$service = Get-Process -Id $owners[0] -ErrorAction Stop
if ($service.Path -ine $env:ATRADER_RESTART_EXECUTABLE) { exit 3 }
& taskkill.exe /PID $service.Id /T /F | Out-Null
exit $LASTEXITCODE
''',
      ],
      environment: {
        'ATRADER_RESTART_PORT': '$port',
        'ATRADER_RESTART_EXECUTABLE': executable,
      },
    ).timeout(const Duration(seconds: 10));
    if (result.exitCode != 0) {
      throw StateError(
        'Port $port is occupied, but its process could not be verified as this app’s backend.',
      );
    }
  }

  Future<_BackendHealth> _health(Uri uri) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 1);
    try {
      final HttpClientRequest request;
      try {
        request = await client.getUrl(uri).timeout(const Duration(seconds: 1));
      } on TimeoutException {
        // Windows can time out a closed port before reporting refusal.
        return _BackendHealth.absent;
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
      if (value['stopping'] == true) return _BackendHealth.stopping;
      return value['ready'] == false
          ? _BackendHealth.loading
          : _BackendHealth.ready;
    } on SocketException {
      return _BackendHealth.absent;
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
