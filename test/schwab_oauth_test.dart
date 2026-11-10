import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// ignore: avoid_relative_lib_imports
import '../backend/lib/schwab_oauth.dart';

final now = DateTime.utc(2026, 11, 5, 12);

class MemoryTokens implements SchwabTokenStore {
  SchwabTokens? value;
  var writes = 0;
  bool failWrite = false;
  @override
  Future<SchwabTokens?> read() async => value;
  @override
  Future<void> write(SchwabTokens tokens) async {
    if (failWrite) throw const SchwabAuthException('Private storage failed.');
    writes++;
    value = tokens;
  }
}

Map<String, dynamic> tokenResponse({String? refresh = 'synthetic-refresh'}) => {
  'access_token': 'synthetic-access',
  'refresh_token': ?refresh,
  'token_type': 'Bearer',
  'expires_in': 1800,
};

SchwabTokens stored({int seconds = -1}) => SchwabTokens(
  accessToken: 'synthetic-old-access',
  refreshToken: 'synthetic-old-refresh',
  expiresAt: now.add(Duration(seconds: seconds)),
);

void main() {
  group('OAuth callback state', () {
    test('cryptographic state, fixed HTTPS endpoints, no invented scopes', () {
      final a = SchwabAuthorization(clock: () => now);
      final b = SchwabAuthorization(clock: () => now);
      expect(a.state, isNot(b.state));
      expect(base64Url.decode(a.state).length, 32);
      final uri = a.authorizeUri('synthetic app & key');
      expect(uri.origin, 'https://api.schwabapi.com');
      expect(uri.path, '/v1/oauth/authorize');
      expect(uri.queryParameters, {
        'response_type': 'code',
        'client_id': 'synthetic app & key',
        'redirect_uri': schwabCallback,
        'state': a.state,
      });
    });

    test('exact callback decodes code once and cannot be replayed', () {
      final a = SchwabAuthorization(clock: () => now);
      final uri = Uri.parse(
        '$schwabCallback?state=${a.state}&code=a%2Bb%2525&session=ignored-synthetic',
      );
      expect(
        a.consume(method: 'GET', host: '127.0.0.1:8766', uri: uri),
        'a+b%25',
      );
      expect(
        () => a.consume(method: 'GET', host: '127.0.0.1:8766', uri: uri),
        throwsA(isA<SchwabAuthException>()),
      );
    });

    test('rejects wrong state/method/host/path/scheme and malformed query', () {
      final a = SchwabAuthorization(clock: () => now);
      final query = 'state=${a.state}&code=synthetic';
      for (final entry in <(String, String, String)>[
        ('POST', '127.0.0.1:8766', '$schwabCallback?$query'),
        ('GET', 'localhost:8766', '$schwabCallback?$query'),
        ('GET', '127.0.0.1', '$schwabCallback?$query'),
        ('GET', '127.0.0.1:8766', '$schwabCallback/?$query'),
        (
          'GET',
          '127.0.0.1:8766',
          '//evil.example/oauth/schwab/callback?$query',
        ),
        (
          'GET',
          '127.0.0.1:8766',
          'https://user@127.0.0.1:8766/oauth/schwab/callback?$query',
        ),
        (
          'GET',
          '127.0.0.1:8766',
          'http://127.0.0.1:8766/oauth/schwab/callback?$query',
        ),
        (
          'GET',
          '127.0.0.1:8766',
          'https://evil.example/oauth/schwab/callback?$query',
        ),
        ('GET', '127.0.0.1:8766', '$schwabCallback?state=wrong&code=synthetic'),
        ('GET', '127.0.0.1:8766', '$schwabCallback?code=synthetic'),
        ('GET', '127.0.0.1:8766', '$schwabCallback?$query&state=${a.state}'),
        ('GET', '127.0.0.1:8766', '$schwabCallback?$query&code=other'),
        ('GET', '127.0.0.1:8766', '$schwabCallback?$query&extra=x'),
        ('GET', '127.0.0.1:8766', '$schwabCallback?$query&session=a&session=b'),
        ('GET', '127.0.0.1:8766', '$schwabCallback?$query&error=denied'),
        ('GET', '127.0.0.1:8766', '$schwabCallback?$query#error'),
        ('GET', '127.0.0.1:8766', '$schwabCallback?$query&error_description=x'),
      ]) {
        expect(
          () => a.consume(
            method: entry.$1,
            host: entry.$2,
            uri: Uri.parse(entry.$3),
          ),
          throwsA(isA<SchwabAuthException>()),
          reason: entry.$3,
        );
      }
      expect(
        a.consume(
          method: 'GET',
          host: '127.0.0.1:8766',
          uri: Uri.parse('$schwabCallback?$query'),
        ),
        'synthetic',
      );
    });

    test(
      'expires at five minutes; denial and malformed code consume state',
      () {
        var time = now;
        final a = SchwabAuthorization(clock: () => time);
        time = now.add(const Duration(minutes: 5));
        expect(
          () => a.consume(
            method: 'GET',
            host: '127.0.0.1:8766',
            uri: Uri.parse('$schwabCallback?state=${a.state}&code=x'),
          ),
          throwsA(isA<SchwabAuthException>()),
        );
        for (final query in [
          'error=access_denied&error_description=SECRET',
          'code=',
          'code=a%0Ab',
        ]) {
          final b = SchwabAuthorization(clock: () => now);
          final uri = Uri.parse('$schwabCallback?state=${b.state}&$query');
          expect(
            () => b.consume(method: 'GET', host: '127.0.0.1:8766', uri: uri),
            throwsA(
              predicate(
                (Object e) =>
                    e is SchwabAuthException &&
                    !e.toString().contains('SECRET'),
              ),
            ),
          );
          expect(
            () => b.consume(
              method: 'GET',
              host: '127.0.0.1:8766',
              uri: Uri.parse('$schwabCallback?state=${b.state}&code=x'),
            ),
            throwsA(isA<SchwabAuthException>()),
          );
        }
      },
    );
  });

  group('token exchange and refresh fixtures (no provider calls)', () {
    test(
      'Basic auth, form encoding, exact redirect, no redirects and durable expiry',
      () async {
        final store = MemoryTokens();
        var time = now;
        final client = SchwabOAuthClient(
          clientId: 'synthetic-id',
          clientSecret: 'synthetic-&secret',
          store: store,
          clock: () => time,
          httpClient: MockClient((request) async {
            expect(
              request.url.toString(),
              'https://api.schwabapi.com/v1/oauth/token',
            );
            expect(request.method, 'POST');
            expect(request.followRedirects, isFalse);
            expect(request.maxRedirects, 0);
            expect(
              request.headers['Authorization'],
              'Basic ${base64Encode(utf8.encode('synthetic-id:synthetic-&secret'))}',
            );
            expect(
              request.headers['content-type'],
              contains('application/x-www-form-urlencoded'),
            );
            expect(request.bodyFields, {
              'grant_type': 'authorization_code',
              'code': 'code+/%&=',
              'redirect_uri': schwabCallback,
            });
            time = now.add(const Duration(seconds: 10));
            return http.Response(jsonEncode(tokenResponse()), 200);
          }),
        );
        addTearDown(client.close);
        final tokens = await client.exchange('code+/%&=');
        expect(tokens.expiresAt, now.add(const Duration(seconds: 1800)));
        expect(store.value, same(tokens));
        expect(store.writes, 1);
      },
    );

    test(
      'valid saved token makes no HTTP call; refresh within 60 second margin',
      () async {
        final store = MemoryTokens()..value = stored(seconds: 61);
        var calls = 0;
        final client = SchwabOAuthClient(
          clientId: 'id',
          clientSecret: 'secret',
          store: store,
          clock: () => now,
          httpClient: MockClient((request) async {
            calls++;
            expect(request.bodyFields, {
              'grant_type': 'refresh_token',
              'refresh_token': 'synthetic-old-refresh',
            });
            return http.Response(jsonEncode(tokenResponse()), 200);
          }),
        );
        addTearDown(client.close);
        expect(await client.validTokens(), same(store.value));
        expect(calls, 0);
        store.value = stored(seconds: 60);
        await client.validTokens();
        expect(calls, 1);
      },
    );

    for (final rotate in [true, false]) {
      test(
        'coalesces refresh and persists ${rotate ? 'rotation' : 'unchanged refresh token'}',
        () async {
          final store = MemoryTokens()..value = stored();
          final gate = Completer<void>();
          var calls = 0;
          final client = SchwabOAuthClient(
            clientId: 'id',
            clientSecret: 'secret',
            store: store,
            clock: () => now,
            httpClient: MockClient((request) async {
              calls++;
              await gate.future;
              return http.Response(
                jsonEncode(tokenResponse(refresh: rotate ? 'rotated' : null)),
                200,
              );
            }),
          );
          addTearDown(client.close);
          final first = client.validTokens();
          final second = client.validTokens();
          expect(first, same(second));
          gate.complete();
          final results = await Future.wait([first, second]);
          expect(calls, 1);
          expect(store.writes, 1);
          expect(
            results.first.refreshToken,
            rotate ? 'rotated' : 'synthetic-old-refresh',
          );
          expect(store.value, same(results.first));
        },
      );
    }

    test(
      'invalid_grant requires explicit reauthorization, never falls back/retries',
      () async {
        final store = MemoryTokens()..value = stored();
        var calls = 0;
        final client = SchwabOAuthClient(
          clientId: 'id',
          clientSecret: 'secret',
          store: store,
          clock: () => now,
          httpClient: MockClient((_) async {
            calls++;
            return http.Response(
              '{"error":"invalid_grant","error_description":"SECRET"}',
              400,
            );
          }),
        );
        addTearDown(client.close);
        for (var i = 0; i < 2; i++) {
          await expectLater(
            client.validTokens(),
            throwsA(
              predicate(
                (Object e) =>
                    e is SchwabAuthException &&
                    e.message.contains('reauthorize') &&
                    !e.message.contains('SECRET'),
              ),
            ),
          );
        }
        expect(calls, 1);
        expect(store.writes, 0);
      },
    );

    for (final status in [301, 302, 307, 400, 401, 429, 500]) {
      test('HTTP $status sanitized; no persistence/retry/redirect', () async {
        final store = MemoryTokens();
        var calls = 0;
        final client = SchwabOAuthClient(
          clientId: 'id',
          clientSecret: 'secret',
          store: store,
          httpClient: MockClient((_) async {
            calls++;
            return http.Response(
              'SECRET',
              status,
              headers: {'location': 'https://evil.example'},
            );
          }),
        );
        addTearDown(client.close);
        await expectLater(
          client.exchange('x'),
          throwsA(
            predicate(
              (Object e) =>
                  e is SchwabAuthException && !e.message.contains('SECRET'),
            ),
          ),
        );
        expect(calls, 1);
        expect(store.writes, 0);
      });
    }

    test('missing saved consent never starts browser or network', () async {
      final client = SchwabOAuthClient(
        clientId: 'id',
        clientSecret: 'secret',
        store: MemoryTokens(),
        httpClient: MockClient((_) async => fail('Unexpected HTTP')),
      );
      addTearDown(client.close);
      await expectLater(
        client.validTokens(),
        throwsA(isA<SchwabAuthException>()),
      );
    });

    test(
      'timeout is bounded, no write or retry; exception details suppressed',
      () async {
        final store = MemoryTokens();
        var calls = 0;
        final client = SchwabOAuthClient(
          clientId: 'id',
          clientSecret: 'secret',
          store: store,
          timeout: const Duration(milliseconds: 10),
          httpClient: MockClient((_) async {
            calls++;
            await Future<void>.delayed(const Duration(milliseconds: 50));
            throw Exception('SECRET');
          }),
        );
        addTearDown(client.close);
        await expectLater(
          client.exchange('x'),
          throwsA(
            predicate(
              (Object e) =>
                  e is SchwabAuthException && !e.message.contains('SECRET'),
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(calls, 1);
        expect(store.writes, 0);
      },
    );

    test('write failure never reports exchange as saved', () async {
      final store = MemoryTokens()..failWrite = true;
      final client = SchwabOAuthClient(
        clientId: 'id',
        clientSecret: 'secret',
        store: store,
        httpClient: MockClient(
          (_) async => http.Response(jsonEncode(tokenResponse()), 200),
        ),
      );
      addTearDown(client.close);
      await expectLater(
        client.exchange('x'),
        throwsA(isA<SchwabAuthException>()),
      );
      expect(store.value, isNull);
    });

    test(
      'malformed token bodies and invalid expiry rejected before persistence',
      () async {
        for (final body in [
          'not json',
          '[]',
          '{}',
          jsonEncode({...tokenResponse(), 'token_type': 'MAC'}),
          jsonEncode({...tokenResponse(), 'expires_in': 0}),
          jsonEncode({...tokenResponse(), 'expires_in': -1}),
          jsonEncode({...tokenResponse(), 'expires_in': 86401}),
          jsonEncode({...tokenResponse(), 'expires_in': 1800.5}),
          jsonEncode({...tokenResponse(), 'expires_in': '1800'}),
          jsonEncode({...tokenResponse(), 'access_token': ''}),
          jsonEncode({...tokenResponse(), 'access_token': 'a\r\nb'}),
          jsonEncode({...tokenResponse(), 'refresh_token': null}),
          jsonEncode(tokenResponse(refresh: null)),
          'x' * 65537,
        ]) {
          final store = MemoryTokens();
          final client = SchwabOAuthClient(
            clientId: 'id',
            clientSecret: 'secret',
            store: store,
            httpClient: MockClient((_) async => http.Response(body, 200)),
          );
          try {
            await expectLater(
              client.exchange('x'),
              throwsA(isA<SchwabAuthException>()),
            );
            expect(store.writes, 0);
          } finally {
            client.close();
          }
        }
      },
    );
  });

  group(
    'native Windows TLS and DPAPI fixtures',
    () {
      late Map<String, dynamic> bundle;
      late Directory directory;
      setUpAll(() async {
        directory = await Directory(
          '.local\\schwab-test-${DateTime.now().microsecondsSinceEpoch}',
        ).create(recursive: true);
        final result = await Process.run('powershell.exe', [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          r". .\scripts\schwab_private.ps1; try { New-ATraderSchwabTlsBundle | ConvertTo-Json -Compress } catch { [Console]::Error.WriteLine('Synthetic TLS fixture failed.'); exit 1 }",
        ]);
        expect(
          result.exitCode,
          0,
          reason:
              'Synthetic certificate creation must work without admin or root trust changes.',
        );
        bundle =
            jsonDecode((result.stdout as String).trim())
                as Map<String, dynamic>;
      });
      tearDownAll(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });

      test(
        'private config imports Schwab with environment precedence and preserves other values',
        () async {
          final fixture = '${directory.absolute.path}\\config.dpapi';
          final result = await Process.run('powershell.exe', [
            '-NoProfile',
            '-NonInteractive',
            '-Command',
            r". .\scripts\schwab_private.ps1; "
                "Write-ATraderProtectedJson '$fixture' "
                "'{\"SCHWAB_CLIENT_ID\":\"synthetic-id\",\"SCHWAB_CLIENT_SECRET\":\"synthetic-secret\",\"OPENAI_MODEL\":\"preserved-model\"}'; "
                r"$env:SCHWAB_CLIENT_ID = 'environment-override'; $env:SCHWAB_CLIENT_SECRET = $null; $env:OPENAI_MODEL = $null; "
                "Import-ATraderPrivateConfig -Path '$fixture'; "
                r"if ($env:SCHWAB_CLIENT_ID -cne 'environment-override' -or $env:SCHWAB_CLIENT_SECRET -cne 'synthetic-secret' -or $env:OPENAI_MODEL -cne 'preserved-model') { exit 1 }; "
                r"[Console]::Out.Write('PASS')",
          ]);
          expect(result.exitCode, 0);
          expect((result.stdout as String).trim(), 'PASS');
          await File(fixture).delete();
        },
      );

      test(
        'current-user DPAPI roundtrip, replacement, restrictive ACL, no plaintext remnants',
        () async {
          final store = WindowsSchwabTokenStore(
            '${Directory.current.path}\\scripts\\schwab_token_store.ps1',
            storeDirectory: directory.absolute.path,
          );
          expect(await store.read(), isNull);
          await store.write(stored());
          await store.write(stored(seconds: 200));
          final loaded = await store.read();
          expect(loaded!.refreshToken, 'synthetic-old-refresh');
          expect(loaded.expiresAt, stored(seconds: 200).expiresAt);
          final file = File('${directory.path}\\tokens.dpapi');
          final ciphertext = await file.readAsString();
          expect(ciphertext, isNot(contains('synthetic')));
          expect(await directory.list().length, 1);
          final acl = await Process.run('powershell.exe', [
            '-NoProfile',
            '-NonInteractive',
            '-Command',
            "\$acl = Get-Acl -LiteralPath '${file.absolute.path}'; "
                r"if (!$acl.AreAccessRulesProtected) { exit 1 }; $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value; foreach ($rule in $acl.Access) { if ($rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -ne $sid) { exit 2 } }",
          ]);
          expect(acl.exitCode, 0);
          await file.writeAsString('corrupted');
          await expectLater(store.read(), throwsA(isA<SchwabAuthException>()));
        },
      );

      test(
        'native PKCS12 HTTPS bind, exact callback, invalid attempt then success, port released',
        () async {
          final authorization = SchwabAuthorization();
          final context = schwabSecurityContext(bundle);
          final pfx = base64Decode(bundle['pfx'] as String);
          final clientContext = SecurityContext(withTrustedRoots: false)
            ..setTrustedCertificatesBytes(
              pfx,
              password: bundle['password'] as String,
            );
          final httpClient = HttpClient(context: clientContext);
          addTearDown(() => httpClient.close(force: true));
          final code = await receiveSchwabCode(
            context: context,
            authorization: authorization,
            openBrowser: () async {
              final invalid = await httpClient.getUrl(
                Uri.parse('$schwabCallback?state=wrong&code=synthetic'),
              );
              final rejected = await invalid.close();
              expect(rejected.statusCode, 400);
              await rejected.drain<void>();
              final request = await httpClient.getUrl(
                Uri.parse(
                  '$schwabCallback?state=${authorization.state}&code=synthetic%2Bcode',
                ),
              );
              final response = await request.close();
              expect(response.statusCode, 200);
              expect(response.headers.value('cache-control'), 'no-store');
              expect(response.headers.value('referrer-policy'), 'no-referrer');
              final body = await utf8.decoder.bind(response).join();
              expect(body, isNot(contains('synthetic')));
              expect(body, isNot(contains(authorization.state)));
            },
          );
          expect(code, 'synthetic+code');
          final rebound = await ServerSocket.bind(
            InternetAddress.loopbackIPv4,
            8766,
          );
          await rebound.close();
        },
      );

      test(
        'HTTPS denial terminates without leaking query; timeout closes listener',
        () async {
          final authorization = SchwabAuthorization();
          final clientContext = SecurityContext(withTrustedRoots: false)
            ..setTrustedCertificatesBytes(
              base64Decode(bundle['pfx'] as String),
              password: bundle['password'] as String,
            );
          final httpClient = HttpClient(context: clientContext);
          addTearDown(() => httpClient.close(force: true));
          await expectLater(
            receiveSchwabCode(
              context: schwabSecurityContext(bundle),
              authorization: authorization,
              openBrowser: () async {
                final request = await httpClient.getUrl(
                  Uri.parse(
                    '$schwabCallback?state=${authorization.state}&error=denied&error_description=SECRET',
                  ),
                );
                final response = await request.close();
                final body = await utf8.decoder.bind(response).join();
                expect(body, isNot(contains('SECRET')));
              },
            ),
            throwsA(isA<SchwabAuthException>()),
          );
          await expectLater(
            receiveSchwabCode(
              context: schwabSecurityContext(bundle),
              authorization: SchwabAuthorization(),
              openBrowser: () async {},
              timeout: const Duration(milliseconds: 20),
            ),
            throwsA(isA<TimeoutException>()),
          );
          final rebound = await ServerSocket.bind(
            InternetAddress.loopbackIPv4,
            8766,
          );
          await rebound.close();
        },
      );
    },
    skip: !Platform.isWindows
        ? 'Windows current-user DPAPI/certificate fixtures only.'
        : false,
  );
}
