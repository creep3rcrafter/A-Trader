import 'dart:io';

import 'package:a_trade/providers/backend_process.dart';
import 'package:a_trade/providers/backend_process_io.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('source checkout uses the root Flutter package configuration', () {
    final root = WindowsBackendProcessController.findSourceRoot();
    expect(root, isNotNull);
    expect(
      File('${root!.path}\\.dart_tool\\package_config.json').existsSync(),
      isTrue,
    );
    expect(File('${root.path}\\backend\\pubspec.yaml').existsSync(), isFalse);
  });

  test('native capability follows real OS, not Flutter target override', () {
    final controller = createBackendProcessController();
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      expect(controller.available, Platform.isWindows);
      expect(controller.ownsBackend, false);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      controller.dispose();
    }
  });

  test('desktop launch accepts only fixed HTTP IPv4 loopback service', () {
    for (final url in ['http://127.0.0.1:8765', 'http://localhost:8765/']) {
      expect(WindowsBackendProcessController.supportsUri(Uri.parse(url)), true);
    }
    for (final url in [
      'http://192.168.1.1:8765',
      'https://127.0.0.1:8765',
      'http://127.0.0.1:3000',
      'http://127.0.0.1:8765/path',
      'http://user@127.0.0.1:8765',
      'http://127.0.0.1:8765?port=3000',
      'http://127.0.0.1:8765#start',
      'http://[::1]:8765',
    ]) {
      expect(
        WindowsBackendProcessController.supportsUri(Uri.parse(url)),
        false,
        reason: url,
      );
    }
  });

  test('stop without ownership is a no-op; dispose prohibits start', () async {
    final controller = WindowsBackendProcessController();
    await controller.stop();
    controller.dispose();
    await expectLater(
      controller.start(Uri.parse('http://127.0.0.1:8765')),
      throwsA(isA<BackendProcessException>()),
    );
    expect(controller.ownsBackend, false);
  });
}
