import 'backend_process.dart';

BackendProcessController createController() => _UnavailableController();

class _UnavailableController implements BackendProcessController {
  @override
  bool get available => false;
  @override
  bool get ownsBackend => false;
  @override
  Future<void> start(Uri serviceUri) async =>
      throw const BackendProcessException('Windows desktop only.');
  @override
  Future<void> stop() async {}
  @override
  void dispose() {}
}
