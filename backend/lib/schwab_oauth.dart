import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

const schwabCallback = 'https://127.0.0.1:8766/oauth/schwab/callback';
final _tokenEndpoint = Uri.parse('https://api.schwabapi.com/v1/oauth/token');

class SchwabAuthException implements Exception {
  const SchwabAuthException(this.message);
  final String message;
  @override
  String toString() => message;
}

class SchwabTokens {
  SchwabTokens({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
  });

  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;

  static String _secret(Object? value) {
    if (value is! String ||
        value.isEmpty ||
        value.length > 32768 ||
        value.contains(RegExp(r'[\x00-\x20\x7f]'))) {
      throw const SchwabAuthException('Invalid token response.');
    }
    return value;
  }

  factory SchwabTokens.fromResponse(
    Map<String, dynamic> json,
    DateTime requestStarted, {
    String? previousRefreshToken,
  }) {
    final seconds = json['expires_in'];
    if (json['token_type'] is! String ||
        (json['token_type'] as String).toLowerCase() != 'bearer' ||
        seconds is! int ||
        seconds <= 0 ||
        seconds > 86400) {
      throw const SchwabAuthException('Invalid token response.');
    }
    return SchwabTokens(
      accessToken: _secret(json['access_token']),
      refreshToken: _secret(
        json.containsKey('refresh_token')
            ? json['refresh_token']
            : previousRefreshToken,
      ),
      expiresAt: requestStarted.toUtc().add(Duration(seconds: seconds)),
    );
  }

  factory SchwabTokens.fromStored(Map<String, dynamic> json) {
    try {
      return SchwabTokens(
        accessToken: _secret(json['access_token']),
        refreshToken: _secret(json['refresh_token']),
        expiresAt: DateTime.parse(json['expires_at'] as String).toUtc(),
      );
    } catch (_) {
      throw const SchwabAuthException('Invalid private token store.');
    }
  }

  Map<String, dynamic> toJson() => {
    'access_token': accessToken,
    'refresh_token': refreshToken,
    'expires_at': expiresAt.toUtc().toIso8601String(),
  };
}

abstract interface class SchwabTokenStore {
  Future<SchwabTokens?> read();
  Future<void> write(SchwabTokens tokens);
}

/// Secrets cross the Windows DPAPI helper boundary through captured stdin/stdout,
/// never command-line arguments, logs or plaintext files.
class WindowsSchwabTokenStore implements SchwabTokenStore {
  WindowsSchwabTokenStore(this.scriptPath, {this.storeDirectory});
  final String scriptPath;
  final String? storeDirectory;

  Future<String> _run(String operation, [String? input]) async {
    Process? process;
    try {
      process = await Process.start('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-File',
        scriptPath,
        '-Operation',
        operation,
        if (storeDirectory != null) ...['-StoreDirectory', storeDirectory!],
      ]);
      final output = utf8.decoder.bind(process.stdout).join();
      final errors = process.stderr.drain<void>();
      if (input != null) process.stdin.add(utf8.encode(input));
      await process.stdin.close();
      final result = await process.exitCode.timeout(
        const Duration(seconds: 15),
      );
      await errors;
      final text = await output;
      if (result != 0) {
        throw const SchwabAuthException('Private storage failed.');
      }
      return text;
    } catch (_) {
      process?.kill();
      throw const SchwabAuthException('Private storage failed.');
    }
  }

  @override
  Future<SchwabTokens?> read() async {
    try {
      final value = jsonDecode(await _run('Read'));
      return value == null
          ? null
          : SchwabTokens.fromStored(value as Map<String, dynamic>);
    } catch (_) {
      throw const SchwabAuthException('Cannot read private tokens; run setup.');
    }
  }

  @override
  Future<void> write(SchwabTokens tokens) async {
    await _run('Write', jsonEncode(tokens.toJson()));
  }
}

class SchwabOAuthClient {
  SchwabOAuthClient({
    required this.clientId,
    required this.clientSecret,
    required this.store,
    http.Client? httpClient,
    DateTime Function()? clock,
    this.timeout = const Duration(seconds: 20),
    this.lockPath,
  }) : _http = httpClient ?? http.Client(),
       _clock = clock ?? DateTime.now {
    if (clientId.trim().isEmpty ||
        clientSecret.trim().isEmpty ||
        '$clientId$clientSecret'.contains(RegExp(r'[\r\n]')) ||
        clientId.contains(':')) {
      throw const SchwabAuthException('Schwab private credentials required.');
    }
  }

  final String clientId;
  final String clientSecret;
  final SchwabTokenStore store;
  final http.Client _http;
  final DateTime Function() _clock;
  final Duration timeout;
  final String? lockPath;
  Future<SchwabTokens>? _refreshing;
  bool _reauthorizationRequired = false;
  bool get reauthorizationRequired => _reauthorizationRequired;

  Future<SchwabTokens> exchange(String code) async {
    final tokens = await _request({
      'grant_type': 'authorization_code',
      'code': code,
      'redirect_uri': schwabCallback,
    });
    await store.write(tokens);
    _reauthorizationRequired = false;
    return tokens;
  }

  /// Concurrent consumers share one refresh and its durable write. A revoked
  /// grant is terminal for this instance; no fallback or browser is automatic.
  Future<SchwabTokens> validTokens() {
    if (_reauthorizationRequired) {
      return Future.error(
        const SchwabAuthException(
          'Schwab consent expired/revoked; reauthorize.',
        ),
      );
    }
    return _refreshing ??= _lockedLoadOrRefresh().whenComplete(
      () => _refreshing = null,
    );
  }

  Future<SchwabTokens> _lockedLoadOrRefresh() async {
    final path = lockPath;
    if (path == null) return _loadOrRefresh();
    RandomAccessFile? lease;
    try {
      lease = await File(path).open(mode: FileMode.append);
      await lease.lock(FileLock.exclusive);
      return await _loadOrRefresh();
    } on FileSystemException {
      throw const SchwabAuthException(
        'Schwab private authorization is busy or unavailable; retry explicitly.',
      );
    } finally {
      await lease?.close();
    }
  }

  Future<SchwabTokens> _loadOrRefresh() async {
    final existing = await store.read();
    if (existing == null) {
      throw const SchwabAuthException(
        'No Schwab consent; authorize explicitly.',
      );
    }
    if (existing.expiresAt.isAfter(
      _clock().toUtc().add(const Duration(seconds: 60)),
    )) {
      return existing;
    }
    final tokens = await _request({
      'grant_type': 'refresh_token',
      'refresh_token': existing.refreshToken,
    }, previousRefreshToken: existing.refreshToken);
    await store.write(tokens);
    return tokens;
  }

  Future<SchwabTokens> _request(
    Map<String, String> form, {
    String? previousRefreshToken,
  }) async {
    final started = _clock().toUtc();
    try {
      final request = http.Request('POST', _tokenEndpoint)
        ..followRedirects = false
        ..maxRedirects = 0
        ..headers.addAll({
          'Authorization':
              'Basic ${base64Encode(utf8.encode('$clientId:$clientSecret'))}',
          'Content-Type': 'application/x-www-form-urlencoded',
          'Accept': 'application/json',
        })
        ..bodyFields = form;
      final tokens = await (() async {
        final response = await _http.send(request);
        final bytes = <int>[];
        await for (final chunk in response.stream) {
          if (bytes.length + chunk.length > 65536) {
            throw const SchwabAuthException('Invalid token response.');
          }
          bytes.addAll(chunk);
        }
        Map<String, dynamic>? json;
        try {
          final decoded = jsonDecode(utf8.decode(bytes));
          if (decoded is Map<String, dynamic>) json = decoded;
        } catch (_) {
          // Bodies may contain secrets; never include them in an exception.
        }
        if (response.statusCode != 200) {
          if (json?['error'] == 'invalid_grant') {
            _reauthorizationRequired = true;
            throw const SchwabAuthException(
              'Schwab consent expired/revoked; reauthorize.',
            );
          }
          throw const SchwabAuthException('Schwab token request rejected.');
        }
        if (json == null) {
          throw const SchwabAuthException('Invalid token response.');
        }
        return SchwabTokens.fromResponse(
          json,
          started,
          previousRefreshToken: previousRefreshToken,
        );
      })().timeout(timeout);
      if (!tokens.expiresAt.isAfter(_clock().toUtc())) {
        throw const SchwabAuthException('Token expired during request.');
      }
      return tokens;
    } on TimeoutException {
      _http.close();
      throw const SchwabAuthException(
        'Schwab token request timed out; restart the auth command.',
      );
    } on SchwabAuthException {
      rethrow;
    } catch (_) {
      // No automatic retries (especially after refresh-token rotation).
      throw const SchwabAuthException(
        'Schwab token request failed or timed out.',
      );
    }
  }

  void close() => _http.close();
}

class SchwabAuthorization {
  SchwabAuthorization({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now {
    final random = Random.secure();
    state = base64UrlEncode(List.generate(32, (_) => random.nextInt(256)));
    _expiresAt = _clock().toUtc().add(const Duration(minutes: 5));
  }

  final DateTime Function() _clock;
  late final String state;
  late final DateTime _expiresAt;
  bool _used = false;

  Uri authorizeUri(String clientId) =>
      Uri.https('api.schwabapi.com', '/v1/oauth/authorize', {
        'response_type': 'code',
        'client_id': clientId,
        'redirect_uri': schwabCallback,
        'state': state,
        // No scope is assumed to narrow arbitrary app permissions.
      });

  String consume({
    required String method,
    required String host,
    required Uri uri,
  }) {
    if (_used || !_clock().toUtc().isBefore(_expiresAt)) {
      throw const SchwabAuthException('Authorization expired or already used.');
    }
    final parameters = uri.queryParametersAll;
    final keys = parameters.keys.toSet();
    if (method != 'GET' ||
        uri.toString().length > 16384 ||
        host != '127.0.0.1:8766' ||
        uri.path != '/oauth/schwab/callback' ||
        uri.hasFragment ||
        ((uri.hasScheme || uri.hasAuthority) &&
            (!uri.hasScheme || uri.origin != 'https://127.0.0.1:8766')) ||
        uri.userInfo.isNotEmpty ||
        !keys.contains('state') ||
        keys.any(
          (k) => !{
            'state',
            'code',
            'error',
            'error_description',
            'session',
          }.contains(k),
        ) ||
        parameters.values.any((v) => v.length != 1) ||
        parameters['state']!.single != state ||
        keys.contains('code') == keys.contains('error') ||
        (keys.contains('error_description') && !keys.contains('error'))) {
      throw const SchwabAuthException('Invalid authorization callback.');
    }
    _used = true;
    if (keys.contains('error')) {
      throw const SchwabAuthException(
        'Schwab authorization denied; try again.',
      );
    }
    final code = parameters['code']!.single;
    if (code.isEmpty ||
        code.length > 8192 ||
        code.contains(RegExp(r'[\x00-\x20\x7f]'))) {
      throw const SchwabAuthException('Invalid authorization callback.');
    }
    return code;
  }
}

SecurityContext schwabSecurityContext(Map<String, dynamic> bundle) {
  try {
    final pfx = base64Decode(bundle['pfx'] as String);
    final password = bundle['password'] as String;
    return SecurityContext()
      ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_2
      ..useCertificateChainBytes(pfx, password: password)
      ..usePrivateKeyBytes(pfx, password: password);
  } catch (_) {
    throw const SchwabAuthException('Local TLS setup invalid; rerun setup.');
  }
}

/// The service on 8765 deliberately has no OAuth route. This short-lived,
/// exclusive HTTPS listener exists only during an operator-started flow.
Future<String> receiveSchwabCode({
  required SecurityContext context,
  required SchwabAuthorization authorization,
  required Future<void> Function() openBrowser,
  Duration timeout = const Duration(minutes: 5),
}) async {
  final server = await HttpServer.bindSecure(
    InternetAddress.loopbackIPv4,
    8766,
    context,
    shared: false,
  );
  final result = Completer<String?>();
  final subscription = server.listen(
    (request) async {
      String? code;
      var accepted = false;
      final wasUsed = authorization._used;
      try {
        code = authorization.consume(
          method: request.method,
          host: request.headers.value(HttpHeaders.hostHeader) ?? '',
          uri: request.uri,
        );
        accepted = true;
      } on SchwabAuthException {
        // A validated denial consumes state and terminates; malformed attempts
        // cannot cancel another user's pending flow.
        accepted = !wasUsed && authorization._used;
      } catch (_) {}
      request.response
        ..statusCode = code == null ? 400 : 200
        ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
        ..headers.set('Referrer-Policy', 'no-referrer')
        ..headers.set(
          'Content-Security-Policy',
          "default-src 'none'; frame-ancestors 'none'",
        )
        ..headers.set('X-Content-Type-Options', 'nosniff')
        ..headers.contentType = ContentType.text
        ..write(
          code == null
              ? 'Authorization callback rejected. Return to the local terminal.'
              : 'Callback received. Close this tab and check the local terminal for token storage status.',
        );
      try {
        await request.response.close();
      } catch (_) {}
      if (accepted && !result.isCompleted) {
        if (code != null) {
          result.complete(code);
        } else {
          result.complete(null);
        }
      }
    },
    onError: (Object _) {
      // TLS failures (including browsers rejecting the self-signed cert) are
      // untrusted input, not loggable URL/exception material.
    },
  );
  try {
    await openBrowser();
    final code = await result.future.timeout(timeout);
    if (code == null) {
      throw const SchwabAuthException(
        'Authorization denied or invalid; restart.',
      );
    }
    return code;
  } finally {
    await subscription.cancel();
    await server.close(force: true);
  }
}
