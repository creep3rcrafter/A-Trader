import 'dart:convert';
import 'dart:io';

/// Progress is advisory. Publish immutable snapshots so Windows readers never
/// prevent a worker from replacing a shared destination file.
class NativeAlgorithmProgress {
  NativeAlgorithmProgress(this.directory);
  final Directory directory;
  int _lastSequence = -1, _lastCompleted = -1;

  bool publish(int sequence, int completed) {
    final file = File('${directory.path}/progress-$sequence-$completed.json');
    final temporary = File('${file.path}.tmp');
    try {
      temporary.writeAsStringSync(
        jsonEncode({'sequence': sequence, 'completed': completed}),
      );
      temporary.renameSync(file.path);
      return true;
    } on FileSystemException {
      // Missing an indicator update must never discard a valid replay.
      try {
        if (temporary.existsSync()) temporary.deleteSync();
      } on FileSystemException {
        /* Best effort. */
      }
      return false;
    }
  }

  int? readLatest(int sequence) {
    if (_lastSequence != sequence) {
      _lastSequence = sequence;
      _lastCompleted = -1;
    }
    final prefix = 'progress-$sequence-';
    final snapshots = <({File file, int completed})>[];
    try {
      for (final entity in directory.listSync(followLinks: false)) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (!name.startsWith(prefix) || !name.endsWith('.json')) continue;
        final completed = int.tryParse(
          name.substring(prefix.length, name.length - 5),
        );
        if (completed != null) {
          snapshots.add((file: entity, completed: completed));
        }
      }
    } on FileSystemException {
      return null;
    }
    snapshots.sort((a, b) => b.completed.compareTo(a.completed));
    int? latest;
    for (final snapshot in snapshots) {
      if (latest == null && snapshot.completed > _lastCompleted) {
        try {
          final raw = jsonDecode(snapshot.file.readAsStringSync());
          if (raw is Map &&
              raw['sequence'] == sequence &&
              raw['completed'] == snapshot.completed) {
            latest = snapshot.completed;
          }
        } on FileSystemException {
          /* Retry on the next poll. */
        } on FormatException {
          /* Ignore an invalid progress snapshot. */
        }
      }
      try {
        snapshot.file.deleteSync();
      } on FileSystemException {
        /* A reader can still hold an older snapshot. */
      }
    }
    if (latest != null) _lastCompleted = latest;
    return latest;
  }
}
