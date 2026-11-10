import 'dart:convert';
import 'dart:io';

import 'package:a_trade/providers/backend_process.dart';

// Invoked only by test_desktop_backend.ps1 with its isolated fixture checkout.
Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) throw ArgumentError('Fixture root required.');
  Directory.current = arguments.single;
  if (!File('fixture.only').existsSync()) {
    throw StateError('Refusing to launch outside the fixture checkout.');
  }
  final controller = createBackendProcessController();
  try {
    await controller.start(Uri.parse('http://127.0.0.1:8765'));
    if (!controller.ownsBackend) throw StateError('Missing backend ownership.');
    stdout.writeln('STARTED');
    final command = await stdin
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first;
    if (command != 'stop') throw StateError('Unknown fixture command.');
    stdout.writeln('STOPPING');
    await controller.stop();
    stdout.writeln('STOPPED');
    if (controller.ownsBackend) throw StateError('Ownership survived Stop.');
  } finally {
    controller.dispose();
  }
}
