import 'dart:async';
import 'dart:io';

import 'package:atrader/local_backend.dart';

Future<void> main(List<String> arguments) async {
  final background = arguments.contains('--background');
  final positional = arguments
      .where((value) => value != '--background')
      .toList();
  final port = positional.isEmpty ? 8787 : int.parse(positional.single);
  final backend = LocalBackend(autoCollectCandles: true);
  try {
    await backend.start(port: port);
  } catch (error) {
    if (!background) rethrow;
    final directory = Directory(
      '${Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path}'
      r'\ATrader',
    );
    await directory.create(recursive: true);
    await File('${directory.path}\\backend-startup.log').writeAsString(
      '${DateTime.now().toUtc().toIso8601String()} '
      'Backend startup failed (${error.runtimeType}) on port $port. '
      'Check for an existing service and Windows credential-store access.\n',
      mode: FileMode.append,
      flush: true,
    );
    exit(1);
  }
  // Detached launches have no console handles or console signal source.
  if (background) return;
  stdout.writeln('A-Trader backend listening on http://127.0.0.1:$port');
  final stopped = Completer<void>();
  void requestStop(ProcessSignal _) {
    if (!stopped.isCompleted) stopped.complete();
  }

  ProcessSignal.sigint.watch().listen(requestStop);
  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen(requestStop);
  }
  await stopped.future;
  await backend.stop();
}
