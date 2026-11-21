import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

class CheckpointArchiveReference {
  const CheckpointArchiveReference._(this.name, this.generation);
  final String name;
  final int? generation;
}

/// Completed generation/session snapshots are immutable. Store each once, and
/// keep small references in state.json instead of rewriting every replay.
class CheckpointArchives {
  CheckpointArchives(this.directory);
  final Directory directory;
  final _files = Expando<String>();
  final _recent = <String, Future<Map<String, dynamic>>>{};
  static final _fileName = RegExp(r'^\d+-\d+\.json\.gz$');
  int _sequence = 0;

  Future<Map<String, dynamic>> packRun(Map<String, dynamic> run) async {
    final packed = Map<String, dynamic>.from(run);
    for (final key in ['generationResults', 'trainingArchive']) {
      final entries = (run[key] as List?)?.toList();
      if (entries == null || entries.isEmpty) continue;
      final files = <String>[];
      for (final entry in entries) {
        if (entry is CheckpointArchiveReference) {
          files.add(entry.name);
          continue;
        }
        var name = _files[entry as Object];
        if (name == null) {
          name =
              '${DateTime.now().microsecondsSinceEpoch}-${++_sequence}.json.gz';
          final snapshot = key == 'trainingArchive'
              ? await _packSession(Map<String, dynamic>.from(entry as Map))
              : entry;
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
      if (key == 'generationResults') {
        packed['generationResultsNumbers'] = entries
            .map(generationNumber)
            .toList();
      }
    }
    return packed;
  }

  // Read just the manifest during startup. Older manifests only list paths.
  Map<String, dynamic> referenceRun(Map<String, dynamic> run) {
    final restored = Map<String, dynamic>.from(run);
    for (final key in ['generationResults', 'trainingArchive']) {
      final files = run['${key}Files'] as List?;
      if (files == null) continue;
      final numbers = key == 'generationResults'
          ? restored.remove('generationResultsNumbers') as List?
          : null;
      final entries = <CheckpointArchiveReference>[];
      for (final (index, raw) in files.indexed) {
        if (raw is! String || !_fileName.hasMatch(raw)) {
          throw const FormatException(
            'Invalid saved generation archive reference.',
          );
        }
        entries.add(
          CheckpointArchiveReference._(
            raw,
            numbers != null && index < numbers.length
                ? numbers[index] as int?
                : null,
          ),
        );
      }
      restored.remove('${key}Files');
      restored[key] = entries;
    }
    return restored;
  }

  static int? generationNumber(Object? entry) => switch (entry) {
    CheckpointArchiveReference(:final generation) => generation,
    Map() => entry['generation'] as int?,
    _ => null,
  };

  Future<Map<String, dynamic>> read(Object entry) async {
    if (entry is! CheckpointArchiveReference) {
      return Map<String, dynamic>.from(entry as Map);
    }
    final cached = _recent.remove(entry.name);
    final pending = cached ?? _readFile(entry.name);
    _recent[entry.name] = pending;
    if (_recent.length > 3) _recent.remove(_recent.keys.first);
    try {
      return await pending;
    } catch (_) {
      if (identical(_recent[entry.name], pending)) _recent.remove(entry.name);
      rethrow;
    }
  }

  // Release completed account histories once state.json is committed.
  Object compact(Object entry) {
    if (entry is CheckpointArchiveReference) return entry;
    final name = _files[entry];
    return name == null
        ? entry
        : CheckpointArchiveReference._(name, generationNumber(entry));
  }

  Future<Map<String, dynamic>> _readFile(String name) async {
    final bytes = await File('${directory.path}/$name').readAsBytes();
    final snapshot = await Isolate.run(
      () => jsonDecode(utf8.decode(gzip.decode(bytes))) as Map<String, dynamic>,
    );
    _files[snapshot] = name;
    return snapshot;
  }

  Future<Map<String, dynamic>> _packSession(
    Map<String, dynamic> session,
  ) async {
    if (session['simulation'] case final Map<String, dynamic> simulation) {
      session['simulation'] = await packRun(simulation);
    }
    if (session.containsKey('generations')) {
      final packed = await packRun({
        'generationResults': session.remove('generations'),
      });
      if (packed['generationResultsFiles'] case final List files) {
        session['generationResultsFiles'] = files;
        session['generationResultsNumbers'] =
            packed['generationResultsNumbers'];
      } else {
        session['generations'] = packed['generationResults'];
      }
    }
    return session;
  }

  Future<Map<String, dynamic>> _unpackSession(
    Map<String, dynamic> session,
  ) async {
    final restored = Map<String, dynamic>.of(session);
    if (session['simulation'] case final Map<String, dynamic> simulation) {
      restored['simulation'] = await unpackRun(simulation);
    }
    if (session.containsKey('generationResultsFiles')) {
      final nested = referenceRun({
        'generationResultsFiles': restored.remove('generationResultsFiles'),
        'generationResultsNumbers': restored.remove('generationResultsNumbers'),
      });
      restored['generations'] = [
        for (final entry in nested['generationResults'] as List)
          await read(entry as Object),
      ];
    }
    if (_files[session] case final String file) _files[restored] = file;
    return restored;
  }

  Future<Map<String, dynamic>> unpackRun(Map<String, dynamic> run) async {
    final restored = referenceRun(run);
    if (restored['generationResults'] case final List entries) {
      restored['generationResults'] = [
        for (final entry in entries.cast<Object>())
          if (entry is Map<String, dynamic>) entry else await read(entry),
      ];
    }
    if (restored['trainingArchive'] case final List sessions) {
      restored['trainingArchive'] = [
        for (final entry in sessions.cast<Object>())
          await _unpackSession(
            entry is Map<String, dynamic> ? entry : await read(entry),
          ),
      ];
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
