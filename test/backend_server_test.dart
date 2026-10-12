import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:a_trade/market_data/market_data.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// ignore: avoid_relative_lib_imports
import '../backend/lib/assistant.dart';
// ignore: avoid_relative_lib_imports
import '../backend/lib/server.dart';
// ignore: avoid_relative_lib_imports
import '../backend/lib/lan_data_policy.dart';

void main() {
  test('LAN rights and model forwarding are independent fail-closed gates', () {
    final personalOnly = LanDataPolicy.fromEnvironment({
      'A_TRADER_AUTH_ENABLED': 'true',
      'TWELVE_DATA_RESEARCH_TERMS_CONFIRMED': 'true',
      'ALPACA_MARKET_DATA_TERMS_CONFIRMED': 'true',
      'A_TRADER_MODEL_FORWARDING_TERMS_CONFIRMED': 'true',
    });
    expect(personalOnly.permits(MarketDataProvider.alpaca), isFalse);
    expect(personalOnly.permits(MarketDataProvider.twelveData), isFalse);
    final expresslyConfirmed = LanDataPolicy.fromEnvironment({
      'A_TRADER_BIND_ADDRESS': '0.0.0.0',
      'ALPACA_LAN_DISPLAY_TERMS_CONFIRMED': 'true',
      'TWELVE_DATA_LAN_RIGHTS_CONFIRMED': 'true',
    });
    expect(expresslyConfirmed.permits(MarketDataProvider.alpaca), isTrue);
    expect(expresslyConfirmed.permits(MarketDataProvider.twelveData), isTrue);
    final loopback = LanDataPolicy.fromEnvironment({});
    expect(loopback.permits(MarketDataProvider.alpaca), isTrue);
    expect(loopback.permits(MarketDataProvider.twelveData), isTrue);
    expect(
      AssistantConfiguration.fromEnvironment({
        'LM_STUDIO_MODEL': 'test-model',
        'A_TRADER_ASSISTANT_ENABLED': 'true',
        'ALPACA_LAN_DISPLAY_TERMS_CONFIRMED': 'true',
      }).enabled,
      isFalse,
    );
  });
  group('assistant configuration and model requests', () {
    test(
      'OpenAI key selects Responses API without LM Studio fallback',
      () async {
        final client = MockClient((request) async {
          expect(request.url, Uri.https('api.openai.com', '/v1/responses'));
          expect(request.headers['authorization'], 'Bearer secret-key');
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['model'], 'custom-model');
          expect(body['max_output_tokens'], 123);
          expect(body['store'], isFalse);
          expect(body['input'], contains('no made-up values'));
          return http.Response(
            jsonEncode({
              'output': [
                {'type': 'reasoning', 'id': 'hidden'},
                {
                  'type': 'message',
                  'content': [
                    {
                      'type': 'output_text',
                      'text': 'Only verified quote context.',
                    },
                  ],
                },
              ],
            }),
            200,
          );
        });
        final configuration = AssistantConfiguration.fromEnvironment({
          'OPENAI_API_KEY': 'secret-key',
          'OPENAI_MODEL': 'custom-model',
          'LM_STUDIO_MODEL': 'local-model',
          'A_TRADER_ASSISTANT_ENABLED': 'true',
          'A_TRADER_MODEL_FORWARDING_TERMS_CONFIRMED': 'true',
        });

        expect(configuration.selectedProvider, AssistantProvider.openAi);
        expect(configuration.enabled, isTrue);
        expect(configuration.health['provider'], 'openai');
        expect(configuration.health['model'], 'custom-model');
        final model = configuration.createModelClient(httpClient: client)!;
        expect(model, isA<OpenAiResponsesClient>());
        expect(
          await model.generate('no made-up values', maximumOutputTokens: 123),
          'Only verified quote context.',
        );
      },
    );

    test(
      'missing OpenAI key selects explicit LM Studio model and non-streaming body',
      () async {
        final client = MockClient((request) async {
          if (request.url.path == '/v1/models') {
            expect(request.method, 'GET');
            expect(request.body, isEmpty);
            expect(request.followRedirects, isFalse);
            return _localModelsResponse('installed-model');
          }
          expect(
            request.url,
            Uri.parse('http://127.0.0.1:1234/v1/chat/completions'),
          );
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['model'], 'installed-model');
          expect(body['stream'], isFalse);
          expect(body['max_tokens'], 80);
          expect(body['messages'], [
            {'role': 'user', 'content': 'bounded prompt'},
          ]);
          expect(request.headers.containsKey('authorization'), isFalse);
          return http.Response(
            jsonEncode({
              'model': 'installed-model',
              'choices': [
                {
                  'message': {
                    'role': 'assistant',
                    'content': 'Local explanation.',
                  },
                },
              ],
            }),
            200,
          );
        });
        final configuration = AssistantConfiguration.fromEnvironment({
          'LM_STUDIO_MODEL': 'installed-model',
          'LM_STUDIO_LOCAL_ONLY_CONFIRMED': 'true',
          'A_TRADER_ASSISTANT_ENABLED': 'true',
          'A_TRADER_MODEL_FORWARDING_TERMS_CONFIRMED': 'true',
        });

        expect(configuration.selectedProvider, AssistantProvider.lmStudio);
        expect(configuration.enabled, isTrue);
        expect(
          await configuration
              .createModelClient(httpClient: client)!
              .generate('bounded prompt', maximumOutputTokens: 80),
          'Local explanation.',
        );
      },
    );

    test(
      'OpenAI errors are sanitized and never fall back to LM Studio',
      () async {
        final client = MockClient(
          (_) async => http.Response(
            '{"error":{"message":"private detail secret-key"}}',
            401,
          ),
        );
        final configuration = AssistantConfiguration.fromEnvironment({
          'OPENAI_API_KEY': 'secret-key',
          'LM_STUDIO_MODEL': 'local-model',
          'A_TRADER_ASSISTANT_ENABLED': 'true',
          'A_TRADER_MODEL_FORWARDING_TERMS_CONFIRMED': 'true',
        });
        final model = configuration.createModelClient(httpClient: client)!;
        await expectLater(
          model.generate('input', maximumOutputTokens: 100),
          throwsA(
            isA<AssistantModelException>().having(
              (error) => error.message,
              'sanitized',
              allOf(
                contains('OpenAI'),
                isNot(contains('secret-key')),
                isNot(contains('private detail')),
              ),
            ),
          ),
        );
        expect(configuration.selectedProvider, AssistantProvider.openAi);
      },
    );

    test('each independent assistant gate must be true', () {
      for (final environment in [
        <String, String>{'LM_STUDIO_MODEL': 'installed-model'},
        {
          'LM_STUDIO_MODEL': 'installed-model',
          'A_TRADER_ASSISTANT_ENABLED': 'true',
        },
        {
          'LM_STUDIO_MODEL': 'installed-model',
          'A_TRADER_MODEL_FORWARDING_TERMS_CONFIRMED': 'true',
        },
      ]) {
        final configuration = AssistantConfiguration.fromEnvironment(
          environment,
        );
        expect(configuration.enabled, isFalse);
        expect(configuration.createModelClient(), isNull);
      }
    });

    test('LM Studio locality requires explicit operator confirmation', () {
      final config = _enabledConfiguration({
        'LM_STUDIO_LOCAL_ONLY_CONFIRMED': 'false',
      });
      expect(config.enabled, isFalse);
      expect(config.createModelClient(), isNull);
      expect(
        config.healthStatus(AssistantProvider.lmStudio)['localOnlyConfirmed'],
        isFalse,
      );
      expect(
        _enabledConfiguration({
          'OPENAI_API_KEY': 'synthetic-key',
          'LM_STUDIO_LOCAL_ONLY_CONFIRMED': 'false',
        }).enabled,
        isTrue,
      );
    });

    test('default visible model does not imply verified availability', () {
      final config = AssistantConfiguration.fromEnvironment({
        'A_TRADER_ASSISTANT_ENABLED': 'true',
        'A_TRADER_MODEL_FORWARDING_TERMS_CONFIRMED': 'true',
        'LM_STUDIO_LOCAL_ONLY_CONFIRMED': 'true',
      });
      expect(config.selectedModel, 'google/gemma-4-e4b');
      expect(config.enabled, isTrue);
      expect(config.health['availabilityVerified'], isFalse);
      expect(
        config.healthStatus(AssistantProvider.lmStudio)['credentialsPresent'],
        isFalse,
      );
      expect(
        _enabledConfiguration({
          'LM_STUDIO_MODEL': 'google/gemma-4-12b',
        }).selectedModel,
        'google/gemma-4-12b',
      );
    });

    test(
      'optional LM Studio token authenticates listing and inference only',
      () async {
        var calls = 0;
        final config = _enabledConfiguration({
          'LM_STUDIO_API_TOKEN': 'synthetic-private-token',
        });
        expect(config.selectedProvider, AssistantProvider.lmStudio);
        expect(
          config.healthStatus(AssistantProvider.lmStudio)['credentialsPresent'],
          isTrue,
        );
        expect(
          jsonEncode(config.health),
          isNot(contains('synthetic-private-token')),
        );
        final client = MockClient((request) async {
          calls++;
          expect(
            request.headers['authorization'],
            'Bearer synthetic-private-token',
          );
          expect(request.followRedirects, isFalse);
          expect(request.body, isNot(contains('synthetic-private-token')));
          if (request.url.path == '/v1/models') {
            return _localModelsResponse('test-model');
          }
          expect(request.url.path, '/v1/chat/completions');
          return http.Response(
            '{"model":"test-model","choices":[{"message":{"content":"Local explanation."}}]}',
            200,
          );
        });
        expect(
          await config
              .createModelClient(httpClient: client)!
              .generate('bounded prompt', maximumOutputTokens: 80),
          'Local explanation.',
        );
        expect(calls, 2);
        await expectLater(
          config
              .createModelClient(
                httpClient: MockClient(
                  (_) async =>
                      http.Response('{"error":"synthetic-private-token"}', 401),
                ),
              )!
              .generate('bounded prompt', maximumOutputTokens: 80),
          throwsA(
            isA<AssistantModelException>().having(
              (error) => error.message,
              'safe authentication error',
              isNot(contains('synthetic-private-token')),
            ),
          ),
        );
      },
    );

    test('LM Studio malformed or rejected output is sanitized', () async {
      for (final response in [
        http.Response('{"error":"private response detail"}', 401),
        http.Response('{"error":"private response detail"}', 429),
        http.Response('private response detail', 200),
        http.Response('{"model":"test-model","choices":[]}', 200),
        http.Response(
          '{"model":"test-model","choices":[{"message":{"content":""}}]}',
          200,
        ),
        http.Response(
          '{"model":"test-model","choices":[{"message":{"content":[]}}]}',
          200,
        ),
        http.Response('x' * 65537, 200),
      ]) {
        final client = MockClient((request) async {
          expect(request.followRedirects, isFalse);
          if (request.url.path == '/v1/models') {
            return _localModelsResponse('test-model');
          }
          expect(request.url.path, '/v1/chat/completions');
          return response;
        });
        await expectLater(
          _enabledConfiguration()
              .createModelClient(httpClient: client)!
              .generate('private prompt', maximumOutputTokens: 80),
          throwsA(
            isA<AssistantModelException>().having(
              (error) => error.message,
              'sanitized',
              allOf(
                isNot(contains('private response detail')),
                isNot(contains('private prompt')),
              ),
            ),
          ),
        );
      }
    });

    test('LM Studio remote endpoint and invalid caps are rejected', () {
      expect(
        () => AssistantConfiguration.fromEnvironment({
          'LM_STUDIO_BASE_URL': 'http://192.168.1.10:1234',
        }),
        throwsFormatException,
      );
      expect(
        () => AssistantConfiguration.fromEnvironment({
          'A_TRADER_ASSISTANT_MAX_CALLS': '1001',
        }),
        throwsFormatException,
      );
    });

    test(
      'hosted identifiers disable LM Studio and missing models stay unverified',
      () {
        for (final model in [
          'https://hosted.example/model',
          ' model with spaces ',
        ]) {
          final config = _enabledConfiguration({'LM_STUDIO_MODEL': model});
          expect(config.enabled, isFalse);
          expect(config.createModelClient(), isNull);
          expect(
            config.healthStatus(AssistantProvider.lmStudio)['configured'],
            isFalse,
          );
          expect(
            () => LmStudioChatClient(
              endpoint: Uri.parse('http://127.0.0.1:1234'),
              model: model,
            ),
            throwsFormatException,
          );
        }
        final config = AssistantConfiguration.fromEnvironment({
          'A_TRADER_ASSISTANT_ENABLED': 'true',
          'A_TRADER_MODEL_FORWARDING_TERMS_CONFIRMED': 'true',
        });
        expect(config.enabled, isFalse);
        expect(config.health['availabilityVerified'], isFalse);
      },
    );

    test(
      'preflight rejects remote aliases before forwarding a prompt',
      () async {
        for (final metadata in [
          {
            'remote_host': 'https://hosted.example',
            'remote_model': 'cloud-model',
          },
          {'remote_model': 'alias-without-cloud-tag'},
          {'cloud': true},
          {
            'manifests': [
              {'remote_host': 'https://hosted.example'},
            ],
          },
        ]) {
          var calls = 0;
          final client = MockClient((request) async {
            calls++;
            expect(request.url.path, '/v1/models');
            expect(request.body, isNot(contains('private prompt')));
            return http.Response(
              jsonEncode({
                'data': [
                  {'id': 'test-model', ...metadata},
                ],
              }),
              200,
            );
          });
          final model = _enabledConfiguration().createModelClient(
            httpClient: client,
          )!;
          await expectLater(
            model.generate('private prompt', maximumOutputTokens: 80),
            throwsA(isA<AssistantModelException>()),
          );
          expect(calls, 1);
        }
      },
    );

    test('rejects cloud chat responses despite a local preflight', () async {
      for (final remoteFields in [
        {'model': 'unexpected-model'},
        {'remote_host': 'https://hosted.example'},
        {'remote_model': 'remote-alias'},
        {'cloud': true},
      ]) {
        final client = MockClient((request) async {
          if (request.url.path == '/v1/models') {
            return _localModelsResponse('test-model');
          }
          return http.Response(
            jsonEncode({
              'model': 'test-model',
              'choices': [
                {
                  'message': {'content': 'Must not return this cloud output.'},
                },
              ],
              ...remoteFields,
            }),
            200,
          );
        });
        await expectLater(
          _enabledConfiguration()
              .createModelClient(httpClient: client)!
              .generate('private prompt', maximumOutputTokens: 80),
          throwsA(isA<AssistantModelException>()),
        );
      }
    });

    test(
      'missing LM Studio model never forwards prompt or fabricates output',
      () async {
        var calls = 0;
        final client = MockClient((request) async {
          calls++;
          expect(request.url.path, '/v1/models');
          return http.Response('{"data":[]}', 200);
        });
        await expectLater(
          _enabledConfiguration()
              .createModelClient(httpClient: client)!
              .generate('private prompt', maximumOutputTokens: 80),
          throwsA(
            isA<AssistantModelException>().having(
              (error) => error.message,
              'safe error',
              isNot(contains('private response detail')),
            ),
          ),
        );
        expect(calls, 1);
      },
    );

    test('advertised remote models are rejected before chat', () async {
      for (final remoteFields in [
        {'remote_host': 'https://hosted.example'},
        {'remote_model': 'gpt-oss:120b'},
        {'remote_model': ''},
        {'remote_host': null},
      ]) {
        final paths = <String>[];
        final client = MockClient((request) async {
          paths.add(request.url.path);
          expect(request.body, isEmpty);
          return http.Response(
            jsonEncode({
              'data': [
                {'id': 'test-model', ...remoteFields},
              ],
            }),
            200,
          );
        });
        await expectLater(
          _enabledConfiguration()
              .createModelClient(httpClient: client)!
              .generate('must not be forwarded', maximumOutputTokens: 80),
          throwsA(isA<AssistantModelException>()),
        );
        expect(paths, ['/v1/models']);
      }
    });

    test(
      'rejects malformed model lists and mismatched installed model IDs',
      () async {
        for (final body in [
          '[]',
          '{}',
          '{"data":{}}',
          '{"data":[{"id":"test-model:other"}]}',
          '{"data":[{"id":"test-model:cloud"}]}',
          '{"data":["test-model"]}',
        ]) {
          var calls = 0;
          final client = MockClient((request) async {
            calls++;
            expect(request.url.path, '/v1/models');
            return http.Response(body, 200);
          });
          await expectLater(
            _enabledConfiguration()
                .createModelClient(httpClient: client)!
                .generate('must not be forwarded', maximumOutputTokens: 80),
            throwsA(isA<AssistantModelException>()),
          );
          expect(calls, 1);
        }
      },
    );
  });

  group('assistant evidence and request limits', () {
    test(
      'uses an actual quote and returns explicit provider provenance',
      () async {
        final now = DateTime.utc(2026, 10, 11, 20);
        final model = _FakeModel();
        final repository = _FakeMarketData(quote: _quote(now));
        final config = _enabledConfiguration();
        final service = AssistantService(
          configuration: config,
          marketData: repository,
          modelClient: model,
          marketDataProvider: 'alpaca',
          marketDataCoverage: 'IEX single-exchange coverage.',
          clock: () => now,
        );

        final result = await service.explain(
          symbol: 'AAPL',
          prompt: 'Explain this quote; no made-up values.',
        );
        expect(model.calls, 1);
        expect(model.lastInput, contains('"lastPrice":123.5'));
        expect(model.lastInput, contains('no made-up values'));
        expect(model.lastInput, contains('Do not invent'));
        expect(model.lastMaximumOutputTokens, config.maximumOutputTokens);
        expect(result['provider'], 'lmstudio');
        expect(result['model'], 'test-model');
        expect(
          result['usage'],
          containsPair('providerTokenUsageAvailable', false),
        );
        final inputs = result['inputs']! as Map<String, Object?>;
        expect(inputs['symbol'], 'AAPL');
        expect(inputs['prompt'], {
          'characters': 'Explain this quote; no made-up values.'.length,
          'utf8Bytes': utf8
              .encode('Explain this quote; no made-up values.')
              .length,
          'contentIncluded': false,
        });
        final provenance = result['provenance']! as Map<String, Object?>;
        expect(provenance['provider'], 'alpaca');
        expect(provenance['feed'], 'iex');
        expect(provenance['coverage'], 'IEX single-exchange coverage.');
        expect(
          (provenance['quote']! as Map<String, Object?>)['lastPrice'],
          123.5,
        );
      },
    );

    test(
      'does not ask a model to explain a missing or mismatched quote',
      () async {
        for (final quote in [
          null,
          _quote(DateTime.utc(2026), symbol: 'MSFT'),
        ]) {
          final model = _FakeModel();
          final service = AssistantService(
            configuration: _enabledConfiguration(),
            marketData: _FakeMarketData(quote: quote),
            modelClient: model,
            marketDataProvider: 'alpaca',
            marketDataCoverage: 'coverage',
          );
          await expectLater(
            service.explain(symbol: 'AAPL', prompt: 'Explain.'),
            throwsA(isA<AssistantRequestException>()),
          );
          expect(model.calls, 0);
        }
      },
    );

    test('enforces prompt length and per-process call caps', () async {
      final model = _FakeModel();
      final config = _enabledConfiguration({
        'A_TRADER_ASSISTANT_MAX_CALLS': '1',
        'A_TRADER_ASSISTANT_MAX_INPUT_CHARS': '128',
      });
      final service = AssistantService(
        configuration: config,
        marketData: _FakeMarketData(quote: _quote(DateTime.now().toUtc())),
        modelClient: model,
        marketDataProvider: 'alpaca',
        marketDataCoverage: 'coverage',
      );

      await expectLater(
        service.explain(symbol: 'AAPL', prompt: 'x' * 129),
        throwsA(
          isA<AssistantRequestException>().having(
            (error) => error.statusCode,
            'status',
            HttpStatus.badRequest,
          ),
        ),
      );
      await service.explain(symbol: 'AAPL', prompt: 'Explain.');
      await expectLater(
        service.explain(symbol: 'AAPL', prompt: 'Again.'),
        throwsA(
          isA<AssistantRequestException>().having(
            (error) => error.statusCode,
            'status',
            HttpStatus.tooManyRequests,
          ),
        ),
      );
      expect(model.calls, 1);
    });

    test(
      'enforces concurrent call cap while another model request is active',
      () async {
        final completer = Completer<String>();
        final model = _BlockingModel(completer);
        final service = AssistantService(
          configuration: _enabledConfiguration({
            'A_TRADER_ASSISTANT_MAX_CONCURRENT': '1',
          }),
          marketData: _FakeMarketData(quote: _quote(DateTime.now().toUtc())),
          modelClient: model,
          marketDataProvider: 'alpaca',
          marketDataCoverage: 'coverage',
        );

        final first = service.explain(symbol: 'AAPL', prompt: 'Explain.');
        await Future<void>.delayed(Duration.zero);
        await expectLater(
          service.explain(symbol: 'AAPL', prompt: 'Also explain.'),
          throwsA(
            isA<AssistantRequestException>().having(
              (error) => error.statusCode,
              'status',
              HttpStatus.tooManyRequests,
            ),
          ),
        );
        completer.complete('A bounded explanation.');
        await first;
        expect(model.calls, 1);
      },
    );
  });

  group('HTTP routes, authentication, and static web root', () {
    late Directory temporaryDirectory;
    final servers = <ATraderServer>[];

    setUp(() async {
      temporaryDirectory = await Directory.systemTemp.createTemp(
        'a-trader-backend-test-',
      );
    });

    tearDown(() async {
      for (final server in servers) {
        await server.close(force: true);
      }
      servers.clear();
      await temporaryDirectory.delete(recursive: true);
    });

    test(
      'local dev JSON POST preflight permits only configured origin',
      () async {
        final server = await _startServer(servers);
        final client = http.Client();
        addTearDown(client.close);
        for (final origin in [
          'http://localhost:3000',
          'http://127.0.0.1:3000',
          'http://localhost:3001',
          'http://untrusted.example',
        ]) {
          final request =
              http.Request(
                  'OPTIONS',
                  server.uri.resolve('/api/v1/assistant/explain'),
                )
                ..headers.addAll({
                  'Origin': origin,
                  'Access-Control-Request-Method': 'POST',
                  'Access-Control-Request-Headers': 'content-type',
                });
          final response = await http.Response.fromStream(
            await client.send(request),
          );
          expect(response.headers['access-control-allow-credentials'], isNull);
          if (origin == 'http://localhost:3000') {
            expect(response.statusCode, 204);
            expect(response.headers['access-control-allow-origin'], origin);
            expect(
              response.headers['access-control-allow-methods'],
              'GET, POST, OPTIONS',
            );
            expect(
              response.headers['access-control-allow-headers'],
              'Content-Type',
            );
            expect(response.headers['vary'], 'Origin');
          } else {
            expect(response.statusCode, 403);
            expect(response.headers['access-control-allow-origin'], isNull);
            expect(response.headers['access-control-allow-methods'], isNull);
            expect(response.headers['access-control-allow-headers'], isNull);
          }
        }
        final response = await http.post(
          server.uri.resolve('/api/v1/assistant/explain'),
          headers: {
            'Origin': 'http://localhost:3000',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'symbol': 'AAPL', 'prompt': 'Explain.'}),
        );
        expect(response.statusCode, 200);
        expect(
          response.headers['access-control-allow-origin'],
          'http://localhost:3000',
        );
        expect(response.headers['access-control-allow-credentials'], isNull);
      },
    );

    test(
      'unauthenticated LAN APIs return JSON 401 even when HTML is accepted',
      () async {
        final server = await _startServer(
          servers,
          staticRoot: temporaryDirectory.path,
          authenticationEnabled: true,
          authenticationPassword: 'a-strong-test-password-123',
        );
        for (final path in [
          '/health',
          '/api/v1/market-data/quote?symbol=AAPL',
          '/api/v1/market-data/bars',
          '/api/v1/assistant/explain',
        ]) {
          final headers = {
            'Origin': server.uri.origin,
            'Accept': 'text/html',
            'Content-Type': 'application/json',
            'Cookie': 'a_trader_session=invalid-session',
          };
          final response = path.endsWith('/explain')
              ? await http.post(
                  server.uri.resolve(path),
                  headers: headers,
                  body: jsonEncode({'symbol': 'AAPL', 'prompt': 'Explain.'}),
                )
              : await http.get(server.uri.resolve(path), headers: headers);
          expect(response.statusCode, 401);
          expect(
            response.headers['content-type'],
            contains('application/json'),
          );
          expect(response.headers['location'], isNull);
          expect(response.headers['access-control-allow-origin'], isNull);
          expect(response.headers['access-control-allow-credentials'], isNull);
          expect(jsonDecode(response.body), {
            'error': 'Authentication is required.',
          });
        }
      },
    );

    test(
      'LAN rejects rebinding Host even when Origin matches forged Host',
      () async {
        final server = await _startServer(
          servers,
          staticRoot: temporaryDirectory.path,
          authenticationEnabled: true,
          authenticationPassword: 'a-strong-test-password-123',
        );
        final client = http.Client();
        addTearDown(client.close);
        for (final host in [
          'attacker.example:${server.uri.port}',
          '127.0.0.1.attacker.example:${server.uri.port}',
          '192.0.2.99:${server.uri.port}',
          'localhost:3000',
        ]) {
          for (final path in ['/', '/main.dart.js', '/health', '/auth/login']) {
            final request =
                http.Request(
                    path == '/auth/login' ? 'POST' : 'GET',
                    server.uri.resolve(path),
                  )
                  ..headers.addAll({
                    'Host': host,
                    'Origin': 'http://$host',
                    'Cookie': 'a_trader_session=invalid-session',
                  });
            final response = await http.Response.fromStream(
              await client.send(request),
            );
            expect(response.statusCode, 403);
            expect(jsonDecode(response.body), {
              'error': 'Host is not allowed.',
            });
            expect(response.headers['set-cookie'], isNull);
          }
        }
      },
    );

    test(
      'LAN passwords accept any character mix at twelve characters',
      () async {
        for (final password in [
          'abcdefghijkl',
          '111111111111',
          '!!!!!!!!!!!!',
          '            ',
          'longlowercasepassphrase',
        ]) {
          final server = await _startServer(
            servers,
            staticRoot: temporaryDirectory.path,
            authenticationEnabled: true,
            authenticationPassword: password,
          );
          final login = await http.post(
            server.uri.resolve('/auth/login'),
            headers: {
              'Origin': server.uri.origin,
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'password': password}),
          );
          expect(login.statusCode, 200);
        }
        for (final password in ['', 'abcdefghijk']) {
          await expectLater(
            _startServer(
              servers,
              staticRoot: temporaryDirectory.path,
              authenticationEnabled: true,
              authenticationPassword: password,
            ),
            throwsStateError,
          );
        }
      },
    );

    test('explicit LAN origins replace default interface allowlist', () async {
      final reservation = await ServerSocket.bind('127.0.0.1', 0);
      final port = reservation.port;
      await reservation.close();
      final server = await _startServer(
        servers,
        port: port,
        lanOrigins: 'http://localhost:$port',
        staticRoot: temporaryDirectory.path,
        authenticationEnabled: true,
        authenticationPassword: 'a-strong-test-password-123',
      );
      expect((await http.get(server.uri)).statusCode, 403);
      final client = http.Client();
      addTearDown(client.close);
      final request = http.Request('GET', server.uri)
        ..headers['Host'] = 'localhost:$port';
      final response = await http.Response.fromStream(
        await client.send(request),
      );
      expect(response.statusCode, 200);
      expect(response.body, contains('LAN access password'));
    });

    test(
      'explicit public test origin preserves authentication and Host checks',
      () async {
        final reservation = await ServerSocket.bind('127.0.0.1', 0);
        final port = reservation.port;
        await reservation.close();
        final origin = 'http://192.0.2.99:$port';
        final server = await _startServer(
          servers,
          port: port,
          lanOrigins: '$origin,http://localhost:$port,http://127.0.0.1:$port',
          staticRoot: temporaryDirectory.path,
          authenticationEnabled: true,
          authenticationPassword: 'a-strong-test-password-123',
        );
        final client = http.Client();
        addTearDown(client.close);
        Future<http.Response> send(
          String path, {
          String method = 'GET',
          String? cookie,
          String? requestOrigin,
        }) async {
          final request = http.Request(method, server.uri.resolve(path))
            ..headers['Host'] = '192.0.2.99:$port';
          if (cookie != null) request.headers['Cookie'] = cookie;
          if (requestOrigin != null) request.headers['Origin'] = requestOrigin;
          if (method == 'POST') {
            request.headers['Content-Type'] = 'application/json';
            request.body = jsonEncode({
              'password': 'a-strong-test-password-123',
            });
          }
          return http.Response.fromStream(await client.send(request));
        }

        expect((await send('/')).body, contains('LAN access password'));
        expect((await send('/health')).statusCode, 401);
        expect(
          (await send(
            '/auth/login',
            method: 'POST',
            requestOrigin: 'http://attacker.example:$port',
          )).statusCode,
          403,
        );
        final login = await send(
          '/auth/login',
          method: 'POST',
          requestOrigin: origin,
        );
        expect(login.statusCode, 200);
        final cookie = login.headers['set-cookie']!.split(';').first;
        expect((await send('/health', cookie: cookie)).statusCode, 200);
        final forged = http.Request('GET', server.uri)
          ..headers['Host'] = '192.0.2.100:$port';
        expect((await client.send(forged)).statusCode, 403);
      },
    );

    test('unsafe or wrong-port configured LAN origins fail startup', () async {
      for (final origins in [
        'http://*.example:3000',
        'https://localhost:3000',
        'http://localhost:3000/path',
        'http://user@localhost:3000',
        'http://localhost:1',
      ]) {
        await expectLater(
          _startServer(
            servers,
            lanOrigins: origins,
            staticRoot: temporaryDirectory.path,
            authenticationEnabled: true,
            authenticationPassword: 'a-strong-test-password-123',
          ),
          throwsFormatException,
        );
      }
    });

    test(
      'LAN mode authenticates static web, health, and API requests',
      () async {
        await File(
          '${temporaryDirectory.path}\\index.html',
        ).writeAsString('<html>private web app</html>');
        final server = await _startServer(
          servers,
          staticRoot: temporaryDirectory.path,
          authenticationEnabled: true,
          authenticationPassword: 'a-strong-test-password-123',
        );
        final root = await http.get(server.uri);
        expect(root.statusCode, 200);
        expect(root.body, contains('LAN access password'));
        expect(root.body, isNot(contains('private web app')));
        expect((await http.get(server.uri.resolve('/health'))).statusCode, 401);

        final origin = server.uri.origin;
        final failedLogin = await http.post(
          server.uri.resolve('/auth/login'),
          headers: {'Origin': origin, 'Content-Type': 'application/json'},
          body: jsonEncode({'password': 'wrong'}),
        );
        expect(failedLogin.statusCode, 401);
        expect(failedLogin.body, isNot(contains('wrong')));
        expect(failedLogin.headers['set-cookie'], isNull);

        final login = await http.post(
          server.uri.resolve('/auth/login'),
          headers: {'Origin': origin, 'Content-Type': 'application/json'},
          body: jsonEncode({'password': 'a-strong-test-password-123'}),
        );
        expect(login.statusCode, 200);
        expect(login.body, contains('authenticated'));
        expect(jsonDecode(login.body)['expiresInSeconds'], 86400);
        final cookie = login.headers['set-cookie']!.split(';').first;
        expect(login.headers['set-cookie'], contains('HttpOnly'));
        expect(login.headers['set-cookie'], contains('SameSite=Strict'));
        expect(login.headers['set-cookie'], contains('Max-Age=86400'));

        for (final path in ['/api/v1/assistant/explain', '/auth/logout']) {
          for (final originHeaders in [
            <String, String>{},
            {'Origin': 'null'},
            {'Origin': 'http://attacker.example'},
            {'Origin': 'http://localhost:3000'},
            {'Origin': '$origin/unexpected-path'},
            {'Origin': '$origin?unexpected-query'},
          ]) {
            final rejected = await http.post(
              server.uri.resolve(path),
              headers: {
                'Cookie': cookie,
                'Content-Type': 'application/json',
                ...originHeaders,
              },
              body: jsonEncode({'symbol': 'AAPL', 'prompt': 'Explain.'}),
            );
            expect(rejected.statusCode, 403);
            expect(rejected.headers['set-cookie'], isNull);
          }
        }

        final index = await http.get(server.uri, headers: {'Cookie': cookie});
        expect(index.body, contains('private web app'));
        final health = await http.get(
          server.uri.resolve('/health'),
          headers: {'Cookie': cookie},
        );
        expect(health.statusCode, 200);
        final healthBody = jsonDecode(health.body) as Map<String, dynamic>;
        expect(healthBody['assistant']['supported'], isTrue);
        expect(healthBody['assistant']['model'], 'test-model');
        expect(healthBody['assistant']['provider'], 'lmstudio');
        expect(healthBody['assistant']['enabled'], isTrue);
        final assistantProviders =
            healthBody['assistant']['providers'] as Map<String, dynamic>;
        for (final provider in ['lmStudio', 'openAi']) {
          expect(
            assistantProviders[provider],
            containsPair('credentialsPresent', isA<bool>()),
          );
          expect(
            assistantProviders[provider],
            containsPair('enabled', isA<bool>()),
          );
          expect(
            assistantProviders[provider],
            containsPair('integrationImplemented', true),
          );
          expect(
            assistantProviders[provider],
            containsPair('termsConfirmed', true),
          );
        }
        expect(health.body, isNot(contains('a-strong-test-password')));

        final explain = await http.post(
          server.uri.resolve('/api/v1/assistant/explain'),
          headers: {
            'Cookie': cookie,
            'Origin': origin,
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'symbol': 'aapl', 'prompt': 'Explain the quote.'}),
        );
        expect(explain.statusCode, 200);
        final result = jsonDecode(explain.body) as Map<String, dynamic>;
        expect(result['explanation'], 'A bounded explanation.');
        expect(result['provider'], 'lmstudio');
        expect(result['provenance']['provider'], 'alpaca');
        expect(result['inputs']['prompt']['contentIncluded'], isFalse);
        expect(result['inputs']['quote']['lastPrice'], 123.5);
        expect(result['usage']['providerTokenUsageAvailable'], isFalse);

        final logout = await http.post(
          server.uri.resolve('/auth/logout'),
          headers: {'Cookie': cookie, 'Origin': origin},
        );
        expect(logout.statusCode, 200);
        expect(logout.headers['set-cookie'], contains('Max-Age=0'));
        expect(
          (await http.get(
            server.uri.resolve('/health'),
            headers: {'Cookie': cookie},
          )).statusCode,
          401,
        );
      },
    );

    test(
      'LAN without display rights disables data and explanation routes',
      () async {
        final server = await _startServer(
          servers,
          staticRoot: temporaryDirectory.path,
          authenticationEnabled: true,
          authenticationPassword: 'a-strong-test-password-123',
          lanDataPolicy: const LanDataPolicy(lanMode: true),
        );
        final login = await http.post(
          server.uri.resolve('/auth/login'),
          headers: {
            'Origin': server.uri.origin,
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'password': 'a-strong-test-password-123'}),
        );
        final cookie = login.headers['set-cookie']!.split(';').first;
        final health =
            jsonDecode(
                  (await http.get(
                    server.uri.resolve('/health'),
                    headers: {'Cookie': cookie},
                  )).body,
                )
                as Map<String, dynamic>;
        expect(health['configured'], isFalse);
        expect(health['providers']['alpaca']['enabled'], isFalse);
        expect(health['providers']['lmStudio']['enabled'], isFalse);
        expect(health['assistant']['enabled'], isFalse);
        expect(health['assistant']['model'], 'test-model');
        for (final path in [
          '/api/v1/market-data/quote?symbol=AAPL',
          '/api/v1/market-data/bars?symbol=AAPL&start=2026-10-01&end=2026-10-11',
        ]) {
          expect(
            (await http.get(
              server.uri.resolve(path),
              headers: {'Cookie': cookie},
            )).statusCode,
            503,
          );
        }
        expect(
          (await http.post(
            server.uri.resolve('/api/v1/assistant/explain'),
            headers: {
              'Cookie': cookie,
              'Origin': server.uri.origin,
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'symbol': 'AAPL', 'prompt': 'Explain.'}),
          )).statusCode,
          503,
        );
      },
    );

    test('throttles repeated invalid login attempts', () async {
      final server = await _startServer(
        servers,
        staticRoot: temporaryDirectory.path,
        authenticationEnabled: true,
        authenticationPassword: 'a-strong-test-password-123',
      );
      for (var attempt = 0; attempt < 5; attempt++) {
        final response = await http.post(
          server.uri.resolve('/auth/login'),
          headers: {
            'Origin': server.uri.origin,
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'password': 'bad-password'}),
        );
        expect(response.statusCode, attempt == 4 ? 429 : 401);
      }
      final valid = await http.post(
        server.uri.resolve('/auth/login'),
        headers: {
          'Origin': server.uri.origin,
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'password': 'a-strong-test-password-123'}),
      );
      expect(valid.statusCode, 429);
      expect(valid.headers['retry-after'], isNotNull);
    });

    test(
      'rejects cross-origin login and sanitizes model failures over HTTP',
      () async {
        final authenticatedServer = await _startServer(
          servers,
          staticRoot: temporaryDirectory.path,
          authenticationEnabled: true,
          authenticationPassword: 'a-strong-test-password-123',
        );
        final crossOrigin = await http.post(
          authenticatedServer.uri.resolve('/auth/login'),
          headers: {
            'Origin': 'http://attacker.example',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'password': 'a-strong-test-password-123'}),
        );
        expect(crossOrigin.statusCode, 403);

        final failingServer = await _startServer(
          servers,
          modelClientOverride: _FailingModel(),
        );
        final response = await http.post(
          failingServer.uri.resolve('/api/v1/assistant/explain'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'symbol': 'AAPL', 'prompt': 'Explain.'}),
        );
        expect(response.statusCode, 500);
        expect(response.body, isNot(contains('secret')));
        expect(response.body, contains('could not complete'));
      },
    );

    test(
      'expires authenticated sessions and refuses unsafe remote binds',
      () async {
        var now = DateTime.utc(2026, 10, 11);
        final server = await _startServer(
          servers,
          staticRoot: temporaryDirectory.path,
          authenticationEnabled: true,
          authenticationPassword: 'a-strong-test-password-123',
          clock: () => now,
        );
        final login = await http.post(
          server.uri.resolve('/auth/login'),
          headers: {
            'Origin': server.uri.origin,
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'password': 'a-strong-test-password-123'}),
        );
        final cookie = login.headers['set-cookie']!.split(';').first;
        expect(
          (await http.get(
            server.uri.resolve('/health'),
            headers: {'Cookie': cookie},
          )).statusCode,
          200,
        );
        now = now.add(const Duration(hours: 24) - const Duration(seconds: 1));
        expect(
          (await http.get(
            server.uri.resolve('/health'),
            headers: {'Cookie': cookie},
          )).statusCode,
          200,
        );
        now = now.add(const Duration(seconds: 1));
        expect(
          (await http.get(
            server.uri.resolve('/health'),
            headers: {'Cookie': cookie},
          )).statusCode,
          401,
        );

        final unsafeServer = ATraderServer(
          bindAddress: '0.0.0.0',
          port: 0,
          selectedProvider: MarketDataProvider.alpaca,
          marketDataClient: null,
          providerStatuses: const {},
          assistantConfiguration: _enabledConfiguration(),
          assistantService: null,
        );
        await expectLater(unsafeServer.start(), throwsStateError);
      },
    );

    test('serves web assets with safe MIME and blocks traversal', () async {
      await File(
        '${temporaryDirectory.path}\\index.html',
      ).writeAsString('<html>safe index</html>');
      await File(
        '${temporaryDirectory.path}\\app.js',
      ).writeAsString('const app = true;');
      final outside = File(
        '${temporaryDirectory.parent.path}\\${temporaryDirectory.uri.pathSegments.last}secret.txt',
      );
      await outside.writeAsString('outside secret content');
      addTearDown(() async {
        if (await outside.exists()) await outside.delete();
      });
      final server = await _startServer(
        servers,
        staticRoot: temporaryDirectory.path,
      );

      final index = await http.get(server.uri);
      expect(index.body, '<html>safe index</html>');
      final script = await http.get(server.uri.resolve('/app.js'));
      expect(script.statusCode, 200);
      expect(script.headers['content-type'], contains('javascript'));
      final traversal = await http.get(
        Uri.parse('${server.uri}/%2e%2e/${outside.uri.pathSegments.last}'),
      );
      expect(traversal.statusCode, 404);
      expect(traversal.body, isNot(contains('outside secret content')));
    });

    test(
      'enforces origin, method, payload shape, and assistant config gate',
      () async {
        final server = await _startServer(servers);
        final blockedOrigin = await http.get(
          server.uri.resolve('/health'),
          headers: {'Origin': 'http://untrusted.example'},
        );
        expect(blockedOrigin.statusCode, 403);
        final allowedOrigin = await http.get(
          server.uri.resolve('/health'),
          headers: {'Origin': 'http://localhost:3000'},
        );
        expect(
          allowedOrigin.headers['access-control-allow-origin'],
          'http://localhost:3000',
        );
        final getExplain = await http.get(
          server.uri.resolve('/api/v1/assistant/explain'),
        );
        expect(getExplain.statusCode, 405);
        final injectedFields = await http.post(
          server.uri.resolve('/api/v1/assistant/explain'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'symbol': 'AAPL', 'prompt': 'explain', 'price': 1}),
        );
        expect(injectedFields.statusCode, 400);

        final disabledServer = await _startServer(
          servers,
          configuration: AssistantConfiguration.fromEnvironment({
            'LM_STUDIO_MODEL': 'test-model',
            'LM_STUDIO_LOCAL_ONLY_CONFIRMED': 'true',
            'A_TRADER_MODEL_FORWARDING_TERMS_CONFIRMED': 'true',
          }),
        );
        final disabled = await http.post(
          disabledServer.uri.resolve('/api/v1/assistant/explain'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'symbol': 'AAPL', 'prompt': 'Explain.'}),
        );
        expect(disabled.statusCode, 503);
        expect(disabled.body, isNot(contains('secret')));
      },
    );
  });
}

Future<ATraderServer> _startServer(
  List<ATraderServer> servers, {
  String? staticRoot,
  bool authenticationEnabled = false,
  String? authenticationPassword,
  AssistantConfiguration? configuration,
  DateTime Function()? clock,
  AssistantModelClient? modelClientOverride,
  LanDataPolicy? lanDataPolicy,
  String? lanOrigins,
  int port = 0,
}) async {
  final assistantConfiguration = configuration ?? _enabledConfiguration();
  final marketData = _FakeMarketData(quote: _quote(DateTime.now().toUtc()));
  final model = modelClientOverride ?? _FakeModel();
  final active = assistantConfiguration.enabled ? model : null;
  final service = active == null
      ? null
      : AssistantService(
          configuration: assistantConfiguration,
          marketData: marketData,
          modelClient: active,
          marketDataProvider: 'alpaca',
          marketDataCoverage: 'IEX single-exchange coverage.',
        );
  final server = ATraderServer(
    bindAddress: '127.0.0.1',
    port: port,
    selectedProvider: MarketDataProvider.alpaca,
    marketDataClient: marketData,
    providerStatuses: const {
      'alpaca': {
        'credentialsPresent': true,
        'termsConfirmed': true,
        'enabled': true,
        'integrationImplemented': true,
      },
    },
    assistantConfiguration: assistantConfiguration,
    assistantService: service,
    allowedOrigin: 'http://localhost:3000',
    authenticationEnabled: authenticationEnabled,
    authenticationPassword: authenticationPassword,
    staticRoot: staticRoot,
    lanDataPolicy:
        lanDataPolicy ??
        LanDataPolicy(
          lanMode: authenticationEnabled,
          alpacaDisplayConfirmed: true,
        ),
    clock: clock,
    lanOrigins: lanOrigins,
  );
  await server.start();
  servers.add(server);
  return server;
}

AssistantConfiguration _enabledConfiguration([
  Map<String, String> additional = const {},
]) => AssistantConfiguration.fromEnvironment({
  'LM_STUDIO_MODEL': 'test-model',
  'LM_STUDIO_LOCAL_ONLY_CONFIRMED': 'true',
  'A_TRADER_ASSISTANT_ENABLED': 'true',
  'A_TRADER_MODEL_FORWARDING_TERMS_CONFIRMED': 'true',
  ...additional,
});

http.Response _localModelsResponse(String name) => http.Response(
  jsonEncode({
    'data': [
      {'id': name, 'object': 'model'},
    ],
  }),
  200,
);

MarketQuote _quote(DateTime time, {String symbol = 'AAPL'}) => MarketQuote(
  symbol: symbol,
  provider: MarketDataProvider.alpaca,
  feed: MarketDataFeed.iex,
  retrievedAt: time,
  lastPrice: 123.5,
  lastTradeAt: time,
);

class _FakeMarketData implements MarketDataRepository {
  _FakeMarketData({required this.quote});
  final MarketQuote? quote;
  String? lastSymbol;

  @override
  Future<MarketQuote?> latestQuote(String symbol) async {
    lastSymbol = symbol;
    return quote;
  }

  @override
  Future<List<MarketBar>> dailyBars(
    String symbol, {
    required DateTime start,
    required DateTime end,
    PriceAdjustment adjustment = PriceAdjustment.raw,
  }) async => const [];
}

class _FakeModel implements AssistantModelClient {
  int calls = 0;
  String? lastInput;
  int? lastMaximumOutputTokens;

  @override
  AssistantProvider get provider => AssistantProvider.lmStudio;

  @override
  String get model => 'test-model';

  @override
  Future<String> generate(
    String input, {
    required int maximumOutputTokens,
  }) async {
    calls++;
    lastInput = input;
    lastMaximumOutputTokens = maximumOutputTokens;
    return 'A bounded explanation.';
  }
}

class _BlockingModel extends _FakeModel {
  _BlockingModel(this.completer);
  final Completer<String> completer;

  @override
  Future<String> generate(String input, {required int maximumOutputTokens}) {
    calls++;
    lastInput = input;
    lastMaximumOutputTokens = maximumOutputTokens;
    return completer.future;
  }
}

class _FailingModel extends _FakeModel {
  @override
  Future<String> generate(
    String input, {
    required int maximumOutputTokens,
  }) async {
    throw Exception('private api key secret');
  }
}
