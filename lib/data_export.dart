/// Platform-specific export of the backend's saved run data.
library;

export 'data_export_stub.dart' if (dart.library.io) 'data_export_io.dart';
