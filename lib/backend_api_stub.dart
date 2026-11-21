class BackendApi {
  const BackendApi({this.baseUrl = 'http://127.0.0.1:8787'});

  final String baseUrl;

  bool get supportsBackendLaunch => false;

  Future<void> startBackend() async =>
      throw UnsupportedError('Starting the backend is supported on Windows.');
  Future<void> restartBackend() => startBackend();

  Future<Map<String, dynamic>> get(String path) async =>
      throw UnsupportedError('This platform has no local backend HTTP client.');

  Future<Map<String, dynamic>> post(
    String path,
    Map<String, Object?> body,
  ) async =>
      throw UnsupportedError('This platform has no local backend HTTP client.');

  void openExternal(String url) {}
}
