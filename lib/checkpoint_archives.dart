import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

/// Completed generation/session snapshots are immutable. Store each once, and
/// keep small references in state.json instead of rewriting every replay.
class CheckpointArchives {
  CheckpointArchives(this.directory);
  final Directory directory;
  final _files = Expando<String>();
  int _sequence = 0;

  Future<Map<String, dynamic>> packRun(Map<String, dynamic> run) async {
    final packed = Map<String, dynamic>.from(run);
    for (final key in ['generationResults', 'trainingArchive']) {
      final entries = (run[key] as List?)?.toList();
      if (entries == null || entries.isEmpty) continue;
      final files = <String>[];
      for (final entry in entries) {
        var name = _files[entry as Object];
        if (name == null) {
          name =
              '${DateTime.now().microsecondsSinceEpoch}-${++_sequence}.json.gz';
          final snapshot = entry;
          final bytes = await Isolate.run(
            () => gzip.encode(utf8.encode(jsonEncode(snapshot))),
          );
          await directory.create(recursive: true);
          final file = File('${directory.path}/$name');
          final temporary = File('${file.path}.tmp');
          await temporary.writeAsBytes(bytes, flush: true);
          await temporary.rename(file.path);
          _files[entry] = name;
        }
        files.add(name);
      }
      packed.remove(key);
      packed['${key}Files'] = files;
    }
    return packed;
  }

  Future<Map<String, dynamic>> unpackRun(Map<String, dynamic> run) async {
    final restored = Map<String, dynamic>.from(run);
    for (final key in ['generationResults', 'trainingArchive']) {
      final files = run['${key}Files'] as List?;
      if (files == null) continue;
      final entries = <Map<String, dynamic>>[];
      for (final raw in files) {
        if (raw is! String || !RegExp(r'^\d+-\d+\.json\.gz$').hasMatch(raw)) {
          throw const FormatException(
            'Invalid saved generation archive reference.',
          );
        }
        final bytes = await File('${directory.path}/$raw').readAsBytes();
        final snapshot = await Isolate.run(
          () =>
              jsonDecode(utf8.decode(gzip.decode(bytes)))
                  as Map<String, dynamic>,
        );
        _files[snapshot] = raw;
        entries.add(snapshot);
      }
      restored.remove('${key}Files');
      restored[key] = entries;
    }
    return restored;
  }

  Future<Map<String, dynamic>> unpackState(
    Map<String, dynamic> state,
  ) async => {
    ...state,
    if (state['runs'] is List)
      'runs': [
        for (final run in (state['runs'] as List).cast<Map<String, dynamic>>())
          await unpackRun(run),
      ],
  };
}
