/// Loopback HTTPS listener for the registered Schwab OAuth callback URL.
///
/// Schwab requires an HTTPS callback such as
/// `https://127.0.0.1:8766/oauth/schwab/callback`. The backend creates a
/// self-signed certificate for 127.0.0.1 once, protects its random PFX
/// password with Windows DPAPI, and listens only while authorization is in
/// progress. Browsers show a certificate warning for this local certificate;
/// users may accept it or paste the redirected URL into Settings instead.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'secure_storage.dart';

/// Handles a callback URI and returns a plain-English result for the browser.
typedef OAuthCallbackHandler = Future<String> Function(Uri callbackUri);

/// Converts an OAuth failure into a short message without Dart type prefixes.
String describeOAuthError(Object error) => switch (error) {
  StateError(:final message) => message,
  ArgumentError(:final message) => '$message',
  _ => error.toString(),
};

class OAuthCallbackServer {
  OAuthCallbackServer({required this.dataDirectory, required this.onCallback});

  final Directory dataDirectory;
  final OAuthCallbackHandler onCallback;
  HttpServer? _server;
  Uri? _redirectUri;

  bool get isListening => _server != null;

  /// Returns true when [redirectUri] points at this computer and needs a
  /// listener separate from the backend API port.
  static bool needsListener(Uri redirectUri, int backendPort) =>
      const {'127.0.0.1', 'localhost'}.contains(redirectUri.host) &&
      (redirectUri.scheme == 'https' || redirectUri.port != backendPort);

  Future<void> listen(Uri redirectUri) async {
    if (_server != null && _redirectUri == redirectUri) return;
    await close();
    final port = redirectUri.hasPort
        ? redirectUri.port
        : (redirectUri.scheme == 'https' ? 443 : 80);
    final server = redirectUri.scheme == 'https'
        ? await HttpServer.bindSecure(
            InternetAddress.loopbackIPv4,
            port,
            await _securityContext(),
          )
        : await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    _server = server;
    _redirectUri = redirectUri;
    server.listen((request) => unawaited(_handle(request)));
  }

  Future<void> close() async {
    final server = _server;
    _server = null;
    _redirectUri = null;
    await server?.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    final expectedPath = _redirectUri?.path ?? '';
    String message;
    if (request.method != 'GET' ||
        request.uri.path != (expectedPath.isEmpty ? '/' : expectedPath)) {
      request.response.statusCode = HttpStatus.notFound;
      message = 'This address is used only for the A-Trader Schwab callback.';
    } else {
      try {
        message = await onCallback(request.uri);
      } catch (error) {
        request.response.statusCode = HttpStatus.badRequest;
        message = 'Schwab authorization failed: ${describeOAuthError(error)}';
      }
    }
    request.response.headers.contentType = ContentType.html;
    request.response.write(
      '<html><body style="font-family:sans-serif">'
      '<h2>A-Trader</h2><p>${const HtmlEscape().convert(message)}</p>'
      '</body></html>',
    );
    await request.response.close();
  }

  File get _pfxFile => File('${dataDirectory.path}\\oauth-callback.pfx');
  File get _passwordFile =>
      File('${dataDirectory.path}\\oauth-callback-password.dpapi');

  Future<SecurityContext> _securityContext() async {
    if (await _pfxFile.exists() && await _passwordFile.exists()) {
      try {
        return _contextFrom(await _readPassword());
      } catch (_) {
        // Recreate an unreadable or expired local certificate below.
      }
    }
    final password = base64Url
        .encode(List<int>.generate(24, (_) => Random.secure().nextInt(256)))
        .replaceAll('=', '');
    await dataDirectory.create(recursive: true);
    await _createCertificate(password);
    await _passwordFile.writeAsBytes(
      WindowsDpapi.protect(Uint8List.fromList(utf8.encode(password))),
      flush: true,
    );
    return _contextFrom(password);
  }

  Future<String> _readPassword() async =>
      utf8.decode(WindowsDpapi.unprotect(await _passwordFile.readAsBytes()));

  SecurityContext _contextFrom(String password) => SecurityContext()
    ..useCertificateChain(_pfxFile.path, password: password)
    ..usePrivateKey(_pfxFile.path, password: password);

  /// Uses the built-in Windows PKI cmdlets without standard input; the
  /// password travels only through this child's environment.
  Future<void> _createCertificate(String password) async {
    if (await _pfxFile.exists()) await _pfxFile.delete();
    const script = r'''
$ErrorActionPreference = 'Stop'
$cert = New-SelfSignedCertificate -Subject 'CN=127.0.0.1' `
  -FriendlyName 'A-Trader local Schwab OAuth callback' `
  -TextExtension @('2.5.29.17={text}IPAddress=127.0.0.1&DNS=localhost') `
  -CertStoreLocation 'Cert:\CurrentUser\My' -KeyExportPolicy Exportable `
  -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256 `
  -NotAfter (Get-Date).AddYears(5)
try {
  $secure = ConvertTo-SecureString -String $env:ATRADER_PFX_PASSWORD -AsPlainText -Force
  Export-PfxCertificate -Cert $cert -FilePath $env:ATRADER_PFX_PATH -Password $secure | Out-Null
} finally {
  Remove-Item -LiteralPath ('Cert:\CurrentUser\My\' + $cert.Thumbprint) -DeleteKey -ErrorAction SilentlyContinue
}
''';
    final process = await Process.start(
      'powershell.exe',
      [
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        script,
      ],
      environment: {
        'ATRADER_PFX_PASSWORD': password,
        'ATRADER_PFX_PATH': _pfxFile.path,
      },
    );
    unawaited(process.stdin.close());
    final output = process.stdout.drain<void>();
    final errors = process.stderr.transform(utf8.decoder).join();
    final int exitCode;
    try {
      exitCode = await process.exitCode.timeout(const Duration(seconds: 60));
    } on TimeoutException {
      process.kill();
      throw StateError(
        'Creating the local HTTPS callback certificate timed out.',
      );
    }
    await output;
    final errorText = (await errors).trim();
    if (exitCode != 0 || !await _pfxFile.exists()) {
      throw StateError(
        'Could not create the local HTTPS callback certificate'
        '${errorText.isEmpty ? '' : ': ${errorText.split('\n').first}'}',
      );
    }
  }
}
