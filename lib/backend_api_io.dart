import 'dart:convert';
import 'dart:io';

import 'backend_launcher.dart';

class BackendApi {
  const BackendApi({this.baseUrl = 'http://127.0.0.1:8787'});

  final String baseUrl;

  bool get supportsBackendLaunch => Platform.isWindows;

  Future<void> startBackend() =>
      WindowsBackendLauncher(baseUrl: baseUrl).start();

  Future<Map<String, dynamic>> get(String path) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse('$baseUrl$path'));
      final response = await request.close();
      return await _decode(response);
    } finally {
      client.close();
    }
  }

  Future<Map<String, dynamic>> post(
    String path,
    Map<String, Object?> body,
  ) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(Uri.parse('$baseUrl$path'));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
      final response = await request.close();
      return await _decode(response);
    } finally {
      client.close();
    }
  }

  void openExternal(String url) {
    if (Platform.isWindows) {
      Process.start('rundll32', ['url.dll,FileProtocolHandler', url]);
    } else if (Platform.isMacOS) {
      Process.start('open', [url]);
    } else if (Platform.isLinux) {
      Process.start('xdg-open', [url]);
    }
  }

  Future<Map<String, dynamic>> _decode(HttpClientResponse response) async {
    final decoded =
        jsonDecode(await utf8.decoder.bind(response).join())
            as Map<String, dynamic>;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        decoded['error']?.toString() ??
            'Local backend request failed (${response.statusCode}).',
      );
    }
    return decoded;
  }
}
