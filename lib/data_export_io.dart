/// Writes a simulator export as one JSON file in Downloads.
library;

import 'dart:convert';
import 'dart:io';

import 'mountain_time.dart';
import 'run_data_export.dart';

final bool canExportRunData = Platform.isWindows;

String get _dataDirectoryPath =>
    '${Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path}'
    r'\ATrader';

/// Writes one JSON file using the backend export or newest saved checkpoint.
/// The backend atomically rotates state.json through state.json.bak; candidates
/// are read-only and the highest savedAt timestamp wins.
Future<String> exportRunData({
  String? stateDirectoryPath,
  String? exportDirectoryPath,
  Map<String, dynamic>? data,
}) async {
  if (!Platform.isWindows &&
      (stateDirectoryPath == null || exportDirectoryPath == null)) {
    throw UnsupportedError(
      'Run-data export is currently supported on Windows.',
    );
  }
  final sourceDirectory = Directory(stateDirectoryPath ?? _dataDirectoryPath);
  final state = data == null
      ? await _readNewestCheckpoint(sourceDirectory)
      : null;
  final downloads = Directory(
    exportDirectoryPath ??
        '${Platform.environment['USERPROFILE'] ?? Directory.systemTemp.path}'
            r'\Downloads',
  );
  await downloads.create(recursive: true);

  final now = DateTime.now().toUtc();
  final mountainNow = MountainTime.at(now);
  String two(int value) => value.toString().padLeft(2, '0');
  final hour = mountainNow.hour % 12 == 0 ? 12 : mountainNow.hour % 12;
  final period = mountainNow.hour < 12 ? 'AM' : 'PM';
  final name =
      'ATrader Export ${mountainNow.year}${two(mountainNow.month)}${two(mountainNow.day)}-'
      '${two(hour)}${two(mountainNow.minute)}${two(mountainNow.second)}'
      '$period-${mountainNow.timeZoneName}-'
      '${mountainNow.millisecond.toString().padLeft(3, '0')}';
  final file = File(_join(downloads.path, '$name.json'));
  await file.writeAsString(
    const JsonEncoder.withIndent('  ').convert(
      data ??
          buildRunDataExport(
            state!,
            exportedAt: now,
            source: 'saved checkpoint',
          ),
    ),
    flush: true,
  );
  return file.path;
}

Future<void> openRunDataExportFolder(String path) async {
  if (!Platform.isWindows) return;
  final result = await Process.run('explorer.exe', ['/select,', path]);
  if (result.exitCode != 0) {
    throw ProcessException(
      'explorer.exe',
      [path],
      'Could not show the exported file.',
      result.exitCode,
    );
  }
}

Future<Map<String, dynamic>> _readNewestCheckpoint(Directory directory) async {
  final primary = File(_join(directory.path, 'state.json'));
  final backup = File('${primary.path}.bak');
  Object? lastError;
  for (var attempt = 0; attempt < 15; attempt++) {
    final candidates = <Map<String, dynamic>>[];
    for (final file in [primary, backup]) {
      try {
        if (!await file.exists()) continue;
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map<String, dynamic>) candidates.add(decoded);
      } catch (error) {
        lastError = error;
      }
    }
    if (candidates.isNotEmpty) {
      candidates.sort((left, right) {
        final leftTime = DateTime.tryParse(left['savedAt']?.toString() ?? '');
        final rightTime = DateTime.tryParse(right['savedAt']?.toString() ?? '');
        return (rightTime ?? DateTime.fromMillisecondsSinceEpoch(0)).compareTo(
          leftTime ?? DateTime.fromMillisecondsSinceEpoch(0),
        );
      });
      return candidates.first;
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  throw StateError(
    'No complete saved run data was found at ${directory.path}'
    '${lastError == null ? '.' : ': $lastError'}',
  );
}

String _join(String directory, String file) =>
    '$directory${Platform.pathSeparator}$file';
