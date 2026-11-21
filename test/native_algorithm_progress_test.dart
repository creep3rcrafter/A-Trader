import 'dart:convert';
import 'dart:io';

import 'package:atrader/algorithms/native_algorithm_progress.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'progress publishes 100 updates while a Windows reader holds the first file open',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'algorithm-progress-',
      );
      RandomAccessFile? held;
      try {
        final progress = NativeAlgorithmProgress(directory);
        expect(progress.publish(1, 0), isTrue);
        final first = File('${directory.path}/progress-1-0.json');
        held = first.openSync();
        final replacement = File('${directory.path}/legacy-progress.tmp')
          ..writeAsStringSync('{}');
        expect(
          () => replacement.renameSync(first.path),
          throwsA(isA<FileSystemException>()),
          reason:
              'Reproduce the old shared-file rename failure before checking the fix.',
        );
        for (var completed = 1; completed <= 100; completed++) {
          expect(progress.publish(1, completed), isTrue);
          expect(progress.readLatest(1), completed);
        }
        held.setPositionSync(0);
        final contents = utf8.decode(held.readSync(held.lengthSync()));
        expect(jsonDecode(contents)['completed'], 0);
        expect(
          progress.readLatest(1),
          isNull,
          reason: 'An older locked snapshot must not move progress backwards.',
        );
        expect(progress.publish(2, 1), isTrue);
        expect(progress.readLatest(2), 1);
      } finally {
        held?.closeSync();
        await directory.delete(recursive: true);
      }
    },
    skip: !Platform.isWindows,
  );

  test('progress I/O failures and malformed snapshots are nonfatal', () async {
    final directory = await Directory.systemTemp.createTemp(
      'algorithm-progress-errors-',
    );
    try {
      final blocked = File('${directory.path}/not-a-directory')
        ..writeAsStringSync('blocked');
      final invalid = NativeAlgorithmProgress(Directory(blocked.path));
      expect(invalid.publish(1, 10), isFalse);
      expect(invalid.readLatest(1), isNull);
      final progress = NativeAlgorithmProgress(directory);
      File(
        '${directory.path}/progress-1-20.json',
      ).writeAsStringSync('{incomplete');
      expect(progress.publish(1, 10), isTrue);
      expect(progress.readLatest(1), 10);
      expect(progress.readLatest(1), isNull);
      expect(progress.publish(1, 30), isTrue);
      expect(progress.readLatest(1), 30);
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
