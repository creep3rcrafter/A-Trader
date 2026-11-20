// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:async';
import 'dart:html' as html;

import 'algorithm_file.dart';

Future<AlgorithmSourceFile?> pickAlgorithmFile() async {
  final input = html.FileUploadInputElement()..accept = '.json,.dart';
  final selected = Completer<html.File?>();
  final change = input.onChange.listen((_) {
    if (!selected.isCompleted) selected.complete(input.files?.firstOrNull);
  });
  final cancel = input.on['cancel'].listen((_) {
    if (!selected.isCompleted) selected.complete(null);
  });
  input.click();
  try {
    final file = await selected.future;
    if (file == null) return null;
    if (file.size > 1024 * 1024) {
      throw const FormatException('Algorithm files must be smaller than 1 MB.');
    }
    final reader = html.FileReader()..readAsText(file);
    await reader.onLoadEnd.first;
    if (reader.error != null) {
      throw StateError('The selected file could not be read.');
    }
    return AlgorithmSourceFile(
      name: file.name,
      source: reader.result as String,
    );
  } finally {
    await change.cancel();
    await cancel.cancel();
    input.remove();
  }
}
