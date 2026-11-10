import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'backend_process.dart';

BackendProcessController createController() =>
    WindowsBackendProcessController();

class WindowsBackendProcessController implements BackendProcessController {
  Process? _supervisor;
  bool _busy = false;
  bool _disposed = false;
  String? _controlId;
  String? _scriptPath;
  String? _powershell;

  @override
  bool get available => Platform.isWindows;
  @override
  bool get ownsBackend => _supervisor != null;

  static bool supportsUri(Uri uri) =>
      uri.scheme == 'http' &&
      const {'127.0.0.1', 'localhost'}.contains(uri.host) &&
      uri.port == 8765 &&
      uri.userInfo.isEmpty &&
      (uri.path.isEmpty || uri.path == '/') &&
      !uri.hasQuery &&
      !uri.hasFragment;

  static Directory? findSourceRoot() {
    for (final start in [
      Directory(File(Platform.resolvedExecutable).parent.path),
      Directory.current,
    ]) {
      var directory = start;
      while (true) {
        if (File(
              '${directory.path}\\scripts\\desktop_backend.ps1',
            ).existsSync() &&
            File(
              '${directory.path}\\scripts\\private_config.ps1',
            ).existsSync() &&
            File(
              '${directory.path}\\backend\\bin\\market_data_server.dart',
            ).existsSync() &&
            File(
              '${directory.path}\\.dart_tool\\package_config.json',
            ).existsSync()) {
          return directory;
        }
        final parent = directory.parent;
        if (parent.path == directory.path) break;
        directory = parent;
      }
    }
    return null;
  }

  @override
  Future<void> start(Uri serviceUri) async {
    if (!available || _disposed || _busy || ownsBackend) {
      throw const BackendProcessException('Backend control is unavailable.');
    }
    if (!supportsUri(serviceUri)) {
      throw const BackendProcessException(
        'Desktop Start requires http://127.0.0.1:8765 (or localhost:8765).',
      );
    }
    final root = findSourceRoot();
    if (root == null) {
      throw const BackendProcessException(
        'Desktop Start requires the source checkout, restored root packages, '
        'and Flutter/Dart SDK. See docs/LOCAL_PROVIDER_SETUP.md.',
      );
    }
    _busy = true;
    Process? process;
    try {
      final windows = Platform.environment['SystemRoot'] ?? r'C:\Windows';
      _powershell =
          '$windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
      _scriptPath = '${root.path}\\scripts\\desktop_backend.ps1';
      _controlId = List.generate(
        24,
        (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      process = await Process.start(
        _powershell!,
        [
          '-NoProfile',
          '-NonInteractive',
          '-File',
          _scriptPath!,
          '-ParentProcessId',
          '$pid',
          '-ControlId',
          _controlId!,
        ],
        workingDirectory: root.path,
        runInShell: false,
        mode: ProcessStartMode.normal,
      );
      final launched = process;
      _supervisor = launched;
      unawaited(launched.stderr.drain<void>().catchError((Object _) {}));
      final ready = Completer<void>();
      launched.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            (line) {
              if (line == 'STARTED' && !ready.isCompleted) ready.complete();
            },
            onError: (Object error) {
              if (!ready.isCompleted) ready.completeError(error);
            },
            onDone: () {
              if (!ready.isCompleted) {
                ready.completeError(
                  const BackendProcessException('Backend did not start.'),
                );
              }
            },
          );
      unawaited(
        launched.exitCode.then((_) {
          if (identical(_supervisor, launched)) _supervisor = null;
        }),
      );
      await ready.future.timeout(const Duration(seconds: 15));
      if (_disposed) {
        await stop();
        throw const BackendProcessException('Backend control is closed.');
      }
    } on Object {
      if (process != null) {
        try {
          await _requestStop(process);
        } on Exception {
          // Startup errors remain sanitized; owner-exit cleanup is independent.
        }
      }
      throw const BackendProcessException(
        'Could not start backend. Check the Dart SDK, restored backend packages, '
        'PowerShell script policy, and private configuration. No tools were installed.',
      );
    } finally {
      _busy = false;
    }
  }

  @override
  Future<void> stop() async {
    final process = _supervisor;
    if (process == null) return;
    await _requestStop(process);
    try {
      await process.exitCode.timeout(const Duration(seconds: 10));
    } on TimeoutException {
      throw const BackendProcessException(
        'Backend shutdown is still pending. No unrelated process was stopped.',
      );
    }
    if (identical(_supervisor, process)) _supervisor = null;
  }

  Future<void> _requestStop(Process process) async {
    final controlId = _controlId;
    final scriptPath = _scriptPath;
    final powershell = _powershell;
    if (controlId == null || scriptPath == null || powershell == null) return;
    final result = await Process.run(powershell, [
      '-NoProfile',
      '-NonInteractive',
      '-File',
      scriptPath,
      '-Stop',
      '-ParentProcessId',
      '$pid',
      '-ControlId',
      controlId,
    ]);
    if (result.exitCode != 0 && identical(_supervisor, process)) {
      throw const BackendProcessException(
        'Could not signal the app-owned backend. Closing this app will clean it up.',
      );
    }
    unawaited(process.stdin.close().catchError((Object _) {}));
  }

  @override
  void dispose() {
    _disposed = true;
    final process = _supervisor;
    if (process != null) {
      unawaited(_requestStop(process).catchError((Object _) {}));
    }
  }
}
