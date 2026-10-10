import 'dart:convert';

import 'package:a_trade/providers/provider_health.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'only permits provider-health requests to HTTP loopback hosts',
    () async {
      final service = ProviderHealthService(
        client: MockClient(
          (_) async => throw StateError('Request must not run'),
        ),
      );

      await expectLater(
        service.check(Uri.parse('https://127.0.0.1:8765')),
        throwsA(isA<ProviderHealthException>()),
      );
      await expectLater(
        service.check(Uri.parse('http://example.com:8765')),
        throwsA(isA<ProviderHealthException>()),
      );
      service.close();
    },
  );

  test(
    'parses credential presence without interpreting it as a connection',
    () async {
      final service = ProviderHealthService(
        client: MockClient((request) async {
          expect(request.url, Uri.parse('http://localhost:8765/health'));
          return http.Response(
            jsonEncode({
              'status': 'ok',
              'providers': {
                'schwab': {
                  'credentialsPresent': true,
                  'enabled': false,
                  'integrationImplemented': false,
                },
              },
            }),
            200,
          );
        }),
      );

      final health = await service.check(Uri.parse('http://localhost:8765'));
      final schwab = health.providers['schwab']!;
      expect(schwab.credentialsPresent, isTrue);
      expect(schwab.enabled, isFalse);
      expect(schwab.integrationImplemented, isFalse);
      service.close();
    },
  );

  test('rejects malformed provider health data', () async {
    final service = ProviderHealthService(
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'status': 'ok',
            'providers': {
              'alpaca': {'credentialsPresent': false},
            },
          }),
          200,
        ),
      ),
    );

    await expectLater(
      service.check(Uri.parse('http://127.0.0.1:8765')),
      throwsA(isA<ProviderHealthException>()),
    );
    service.close();
  });
}
