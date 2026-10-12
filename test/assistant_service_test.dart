import 'dart:convert';

import 'package:a_trade/providers/assistant_service.dart';
import 'package:a_trade/providers/local_service_url.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'research sends configured horizon and validates source evidence',
    () async {
      final service = AssistantService(
        client: MockClient((request) async {
          expect(request.url.path, '/api/v1/assistant/research');
          expect(jsonDecode(request.body), {
            'symbol': 'SOFI',
            'prompt': 'Review risks.',
            'holdingDays': 12,
            'lookbackDays': 7,
          });
          return http.Response(
            jsonEncode({
              'explanation': 'A filing exists; no catalysts were verified.',
              'provider': 'lmstudio',
              'model': 'fixture-local',
              'toolsUsed': ['get_sec_filings'],
              'limitations': ['No news or social tools configured.'],
              'sources': [
                {
                  'title': '10-Q filing',
                  'url': 'https://www.sec.gov/Archives/edgar/data/1/filing.htm',
                  'publishedAt': '2026-10-10',
                  'retrievedAt': '2026-10-12T12:00:00Z',
                },
              ],
            }),
            200,
          );
        }),
      );
      final result = await service.research(
        'http://localhost:8765',
        'SOFI',
        'Review risks.',
        holdingDays: 12,
      );
      expect(result.sources.single.publishedAt, '2026-10-10');
      expect(result.toolsUsed, ['get_sec_filings']);
      expect(result.limitations.single, contains('No news'));
    },
  );

  test('research rejects unsafe URLs and undeclared tools', () async {
    for (final unsafe in [true, false]) {
      final service = AssistantService(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'explanation': 'Test',
              'provider': 'lmstudio',
              'model': 'fixture',
              'toolsUsed': unsafe ? ['get_sec_filings'] : ['execute_shell'],
              'limitations': <String>[],
              'sources': [
                {
                  'title': 'Test source',
                  'url': unsafe
                      ? 'javascript:alert(1)'
                      : 'https://www.sec.gov/',
                  'publishedAt': null,
                  'retrievedAt': '2026-10-12T12:00:00Z',
                },
              ],
            }),
            200,
          ),
        ),
      );
      await expectLater(
        service.research(
          'http://localhost:8765',
          'SOFI',
          'Review.',
          holdingDays: 10,
        ),
        throwsA(isA<AssistantException>()),
      );
    }
  });

  test(
    'research rejects untrusted HTTPS sources and other-symbol market sources',
    () async {
      for (final url in [
        'https://invented.example/news',
        'https://data.alpaca.markets/v2/stocks/OTHER/trades/latest?feed=iex',
        'https://api.twelvedata.com/quote?symbol=SOFI&apikey=private',
      ]) {
        final service = AssistantService(
          client: MockClient(
            (_) async => http.Response(
              jsonEncode({
                'explanation': 'Untrusted evidence',
                'provider': 'lmstudio',
                'model': 'fixture',
                'toolsUsed': ['get_market_quote'],
                'limitations': [],
                'sources': [
                  {
                    'title': 'Bad source',
                    'url': url,
                    'publishedAt': null,
                    'retrievedAt': '2026-10-12T12:00:00Z',
                  },
                ],
              }),
              200,
            ),
          ),
        );
        await expectLater(
          service.research(
            'http://localhost:8765',
            'SOFI',
            'Review.',
            holdingDays: 10,
          ),
          throwsA(isA<AssistantException>()),
        );
      }
    },
  );

  test('LAN permits same browser origin only and preserves loopback', () {
    final page = Uri.parse('http://192.168.1.20:3000');
    expect(isTrustedServiceUri(page, browserOrigin: page), isTrue);
    expect(
      isTrustedServiceUri(
        Uri.parse('http://192.168.1.21:3000'),
        browserOrigin: page,
      ),
      isFalse,
    );
    expect(
      isTrustedServiceUri(
        Uri.parse('http://192.168.1.20:3001'),
        browserOrigin: page,
      ),
      isFalse,
    );
    expect(
      isTrustedServiceUri(
        Uri.parse('http://user@192.168.1.20:3000'),
        browserOrigin: page,
      ),
      isFalse,
    );
    expect(isTrustedServiceUri(page), isFalse);
    expect(isTrustedServiceUri(Uri.parse('http://127.0.0.1:8765')), isTrue);
    final securePage = Uri.parse('https://research.example');
    expect(isTrustedServiceUri(securePage, browserOrigin: securePage), isTrue);
    expect(
      isTrustedServiceUri(
        Uri.parse('http://research.example'),
        browserOrigin: securePage,
      ),
      isFalse,
    );
  });

  for (final provider in ['lmstudio', 'openai']) {
    test(
      'analysis sends bounded prompt and ticker to backend ($provider)',
      () async {
        final service = AssistantService(
          client: MockClient((request) async {
            expect(request.method, 'POST');
            expect(request.url.path, '/api/v1/assistant/explain');
            expect(request.followRedirects, isFalse);
            expect(jsonDecode(request.body), {
              'symbol': 'SOFI',
              'prompt': 'Explain limitations.',
            });
            expect(request.headers.containsKey('Authorization'), isFalse);
            return http.Response(
              jsonEncode({
                'explanation':
                    'Liquidity cannot be established from this quote.',
                'provider': provider,
                'model': 'fixture-local',
              }),
              200,
            );
          }),
        );
        final result = await service.explain(
          'http://127.0.0.1:8765',
          ' sofi ',
          'Explain limitations.',
        );
        expect(result.provider, provider);
        expect(result.model, 'fixture-local');
        expect(result.text, contains('Liquidity'));
      },
    );
  }

  test('reject invalid URLs/prompts before requests', () async {
    var calls = 0;
    final service = AssistantService(
      client: MockClient((_) async {
        calls++;
        return http.Response('{}', 200);
      }),
    );
    for (final url in ['https://remote.example', 'http://192.168.1.20:3000']) {
      await expectLater(
        service.explain(url, 'SOFI', 'Explain.'),
        throwsA(isA<AssistantException>()),
      );
    }
    for (final prompt in ['', ' ' * 4001]) {
      await expectLater(
        service.explain('http://localhost:8765', 'SOFI', prompt),
        throwsA(isA<AssistantException>()),
      );
    }
    expect(calls, 0);
  });

  for (final code in [401, 403, 404, 429, 503, 500]) {
    test('sanitizes assistant HTTP $code', () async {
      final service = AssistantService(
        client: MockClient(
          (_) async => http.Response('secret server body', code),
        ),
      );
      await expectLater(
        service.explain('http://localhost:8765', 'SOFI', 'Explain.'),
        throwsA(
          isA<AssistantException>().having(
            (e) => e.message,
            'sanitized',
            isNot(contains('secret')),
          ),
        ),
      );
    });
  }

  for (final body in [
    'invalid json',
    '{"explanation":"","provider":"lmstudio","model":"test"}',
    '{"explanation":"text","provider":"unknown","model":"test"}',
    '{"explanation":"text","provider":"lmstudio"}',
  ]) {
    test('rejects invalid analysis response $body', () async {
      final service = AssistantService(
        client: MockClient((_) async => http.Response(body, 200)),
      );
      await expectLater(
        service.explain('http://localhost:8765', 'SOFI', 'Explain.'),
        throwsA(isA<AssistantException>()),
      );
    });
  }
}
