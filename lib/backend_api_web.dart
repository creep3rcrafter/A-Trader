// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:convert';
import 'dart:html' as html;

class BackendApi {
  const BackendApi({this.baseUrl = 'http://127.0.0.1:8787'});

  final String baseUrl;

  bool get supportsBackendLaunch => false;

  Future<void> startBackend() async => throw UnsupportedError(
    'Start the backend from the Windows app or a terminal.',
  );
  Future<void> restartBackend() => startBackend();

  Future<Map<String, dynamic>> get(String path) async {
    final request = await html.HttpRequest.request(
      '$baseUrl$path',
      method: 'GET',
      requestHeaders: const {'Accept': 'application/json'},
    );
    return _decode(request);
  }

  Future<Map<String, dynamic>> post(
    String path,
    Map<String, Object?> body,
  ) async {
    final request = await html.HttpRequest.request(
      '$baseUrl$path',
      method: 'POST',
      sendData: jsonEncode(body),
      requestHeaders: const {'Content-Type': 'application/json'},
    );
    return _decode(request);
  }

  void openExternal(String url) {
    html.window.open(url, '_blank', 'noopener,noreferrer');
  }

  Map<String, dynamic> _decode(html.HttpRequest request) {
    final body = request.responseText ?? '{}';
    final decoded = jsonDecode(body) as Map<String, dynamic>;
    if (request.status == null ||
        request.status! < 200 ||
        request.status! >= 300) {
      throw StateError(
        decoded['error']?.toString() ??
            'Local backend request failed (${request.status}).',
      );
    }
    return decoded;
  }
}
