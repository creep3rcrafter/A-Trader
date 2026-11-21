import 'dart:convert';
import 'dart:io';

import 'package:atrader/checkpoint_archives.dart';
import 'package:atrader/data_export_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'completed snapshots are stored once, restore fully, and export in one JSON',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'checkpoint-archives-',
      );
      try {
        final directory = Directory('${root.path}/state-archives');
        final archives = CheckpointArchives(directory);
        final run = <String, dynamic>{
          'id': 'run-1',
          'name': 'Example',
          'settings': {'startingCash': 10000},
          'runtime': {'engines': null},
          'generationResults': [
            {
              'generation': 1,
              'simulation': {
                'candles': List.generate(100, (i) => {'close': 100 + i}),
              },
            },
          ],
          'trainingArchive': [
            {
              'session': {'cycles': 3},
              'generations': [],
            },
          ],
        };
        final packed = await archives.packRun(run);
        expect(packed.containsKey('generationResults'), isFalse);
        expect(packed['generationResultsFiles'], hasLength(1));
        expect(await directory.list().length, 2);
        expect(await archives.packRun(run), packed);
        expect(await directory.list().length, 2);
        final reopened = CheckpointArchives(directory);
        expect(await reopened.unpackRun(packed), run);
        expect(
          await reopened.packRun(await reopened.unpackRun(packed)),
          packed,
        );
        await File('${root.path}/state.json').writeAsString(
          jsonEncode({
            'runs': [packed],
            'savedAt': DateTime.now().toUtc().toIso8601String(),
          }),
        );
        final path = await exportRunData(
          stateDirectoryPath: root.path,
          exportDirectoryPath: '${root.path}/exports',
        );
        final exported = jsonDecode(await File(path).readAsString()) as Map;
        expect((exported['savedState'] as Map)['runs'], [run]);
        expect(await Directory('${root.path}/exports').list().length, 1);
        await expectLater(
          archives.unpackRun({
            'generationResultsFiles': ['../unsafe.json.gz'],
          }),
          throwsFormatException,
        );
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
}
