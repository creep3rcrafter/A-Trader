import 'dart:convert';
import 'dart:io';

import 'algorithm_file.dart';

Future<AlgorithmSourceFile?> pickAlgorithmFile() async {
  if (!Platform.isWindows) {
    throw UnsupportedError(
      'Use the web dashboard to import files on this platform.',
    );
  }
  // The script is fixed; file paths and file contents never become shell code.
  final result = await Process.run('powershell.exe', [
    '-NoProfile',
    '-NonInteractive',
    '-STA',
    '-Command',
    r'''
Add-Type -AssemblyName System.Windows.Forms
$dialog = New-Object System.Windows.Forms.OpenFileDialog
$dialog.Title = 'Add algorithm'
$dialog.Filter = 'Algorithm files (*.json;*.dart)|*.json;*.dart|JSON rules (*.json)|*.json|Dart algorithms (*.dart)|*.dart'
$dialog.CheckFileExists = $true
$dialog.Multiselect = $false
$dialog.RestoreDirectory = $true
try {
  if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
    [Console]::Write([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($dialog.FileName)))
  }
} finally { $dialog.Dispose() }
''',
  ]);
  if (result.exitCode != 0) {
    throw StateError('Could not open the file chooser: ${result.stderr}');
  }
  final path = result.stdout.toString().trim();
  if (path.isEmpty) return null;
  final file = File(utf8.decode(base64Decode(path)));
  if (await file.length() > 1024 * 1024) {
    throw const FormatException('Algorithm files must be smaller than 1 MB.');
  }
  return AlgorithmSourceFile(
    name: file.uri.pathSegments.last,
    source: await file.readAsString(),
  );
}
