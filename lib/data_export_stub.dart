/// Export is currently supported by the Windows desktop application.
library;

const bool canExportRunData = false;

Future<String> exportRunData({
  String? stateDirectoryPath,
  String? exportDirectoryPath,
  Map<String, dynamic>? data,
}) async => throw UnsupportedError(
  'Run-data export is only available in the Windows app.',
);

Future<void> openRunDataExportFolder(String path) async {}
