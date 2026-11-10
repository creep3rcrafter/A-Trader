import 'dart:convert';
import 'dart:io';

// ignore: avoid_relative_lib_imports
import '../lib/schwab_oauth.dart';

Future<void> main(List<String> arguments) async {
  SchwabOAuthClient? client;
  try {
    if (!Platform.isWindows ||
        arguments.length != 1 ||
        !{'authorize', 'refresh'}.contains(arguments.single)) {
      throw const SchwabAuthException('Use scripts\\authorize_schwab.ps1.');
    }
    final bootstrap =
        jsonDecode(await utf8.decoder.bind(stdin).join())
            as Map<String, dynamic>;
    final root = File.fromUri(Platform.script).parent.parent.parent.path;
    final store = WindowsSchwabTokenStore(
      '$root\\scripts\\schwab_token_store.ps1',
    );
    client = SchwabOAuthClient(
      clientId: bootstrap['clientId'] as String,
      clientSecret: bootstrap['clientSecret'] as String,
      store: store,
    );
    if (arguments.single == 'refresh') {
      await client.validTokens();
      stdout.writeln('Schwab private token is current (refreshed if needed).');
    } else {
      final authorization = SchwabAuthorization();
      final code = await receiveSchwabCode(
        context: schwabSecurityContext(
          bootstrap['tls'] as Map<String, dynamic>,
        ),
        authorization: authorization,
        openBrowser: () async {
          final process = await Process.start(
            'powershell.exe',
            [
              '-NoProfile',
              '-NonInteractive',
              '-Command',
              r'Start-Process -FilePath ([Console]::In.ReadToEnd().Trim())',
            ],
            environment: {
              for (final name in [
                'SystemRoot',
                'SystemDrive',
                'WINDIR',
                'PATH',
                'PATHEXT',
                'COMSPEC',
                'USERPROFILE',
                'LOCALAPPDATA',
                'APPDATA',
                'TEMP',
                'TMP',
              ])
                if (Platform.environment[name] case final String value)
                  name: value,
            },
            includeParentEnvironment: false,
          );
          final output = process.stdout.drain<void>();
          final errors = process.stderr.drain<void>();
          process.stdin.add(
            utf8.encode(
              authorization.authorizeUri(client!.clientId).toString(),
            ),
          );
          await process.stdin.close();
          try {
            if (await process.exitCode.timeout(const Duration(seconds: 15)) !=
                0) {
              throw const SchwabAuthException('Browser launch failed.');
            }
            await Future.wait([output, errors]);
          } catch (_) {
            process.kill();
            throw const SchwabAuthException('Browser launch failed.');
          }
        },
      );
      await client.exchange(code);
      stdout.writeln(
        'Schwab authorization saved privately with Windows DPAPI. '
        'Market-data adapter remains disabled.',
      );
    }
  } on SchwabAuthException catch (error) {
    stderr.writeln(error.message);
    exitCode = 1;
  } catch (_) {
    stderr.writeln(
      'Schwab auth failed, timed out, or local port/TLS setup unavailable. '
      'Run setup or restart explicit authorization. No sensitive details logged.',
    );
    exitCode = 1;
  } finally {
    client?.close();
  }
}
