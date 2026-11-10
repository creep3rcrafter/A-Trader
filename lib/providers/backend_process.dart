import 'backend_process_stub.dart'
    if (dart.library.io) 'backend_process_io.dart'
    as implementation;

abstract class BackendProcessController {
  bool get available;
  bool get ownsBackend;
  Future<void> start(Uri serviceUri);
  Future<void> stop();
  void dispose();
}

class BackendProcessException implements Exception {
  const BackendProcessException(this.message);
  final String message;
}

BackendProcessController createBackendProcessController() =>
    implementation.createController();
