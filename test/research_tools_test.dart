import 'dart:convert';
import 'dart:io';

import 'package:a_trade/market_data/daily_indicators.dart';
import 'package:a_trade/market_data/market_data.dart';
import 'package:a_trade/market_data/alpaca_market_data_client.dart';
import 'package:a_trade/providers/assistant_service.dart' as frontend;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// ignore: avoid_relative_lib_imports
import '../backend/lib/assistant.dart';
// ignore: avoid_relative_lib_imports
import '../backend/lib/daily_indicator_service.dart';
// ignore: avoid_relative_lib_imports
import '../backend/lib/research.dart';
// ignore: avoid_relative_lib_imports
import '../backend/lib/sec_filings.dart';
// ignore: avoid_relative_lib_imports
import '../backend/lib/server.dart';

final fixtureNow = DateTime.utc(2026, 10, 12, 12);

AssistantConfiguration researchConfiguration([
  Map<String, String> extra = const {},
]) => AssistantConfiguration.fromEnvironment({
  'LM_STUDIO_MODEL': 'synthetic-local',
  'LM_STUDIO_LOCAL_ONLY_CONFIRMED': 'true',
  'A_TRADER_ASSISTANT_ENABLED': 'true',
  'A_TRADER_MODEL_FORWARDING_TERMS_CONFIRMED': 'true',
  ...extra,
});

class SyntheticResearchMarket implements MarketDataRepository {
  int quoteCalls = 0;
  int barCalls = 0;
  bool unavailable = false;
  bool failProvider = false;
  String returnedSymbol = 'SYNTH';
  List<MarketBar>? overrideBars;
  MarketQuote? overrideQuote;

  @override
  Future<MarketQuote?> latestQuote(String symbol) async {
    quoteCalls++;
    if (failProvider) {
      throw const MarketDataException(
        'private upstream detail',
        statusCode: 429,
      );
    }
    if (unavailable) return null;
    if (overrideQuote != null) return overrideQuote;
    return MarketQuote(
      symbol: returnedSymbol,
      provider: MarketDataProvider.alpaca,
      feed: MarketDataFeed.iex,
      lastPrice: 17.375,
      lastTradeAt: fixtureNow.subtract(const Duration(seconds: 10)),
      retrievedAt: fixtureNow,
    );
  }

  @override
  Future<List<MarketBar>> dailyBars(
    String symbol, {
    required DateTime start,
    required DateTime end,
    PriceAdjustment adjustment = PriceAdjustment.raw,
  }) async {
    barCalls++;
    if (failProvider) {
      throw const MarketDataException(
        'private upstream detail',
        statusCode: 403,
      );
    }
    expect(symbol, 'SYNTH');
    expect(adjustment, PriceAdjustment.raw);
    expect(end.isBefore(DateTime.utc(2026, 10, 12)), isTrue);
    return overrideBars ??
        [
          MarketBar(
            symbol: returnedSymbol,
            provider: MarketDataProvider.alpaca,
            feed: MarketDataFeed.iex,
            timestamp: DateTime.utc(2026, 10, 9),
            retrievedAt: fixtureNow,
            adjustment: PriceAdjustment.raw,
            open: 17,
            high: 18,
            low: 16,
            close: 17.375,
            volume: 1000,
          ),
        ];
  }
}

ResearchTools syntheticTools(SyntheticResearchMarket market) => ResearchTools(
  marketData: market,
  provider: MarketDataProvider.alpaca,
  secFilings: SecFilingsClient(permitted: false, userAgent: ''),
  evidenceLabel: 'SYNTHETIC TEST FIXTURE - NOT LIVE MARKET DATA',
  clock: () => fixtureNow,
);

List<MarketBar> syntheticIndicatorHistory() {
  final dates = UsEquitySessionCalendar.expectedSessionDates(
    start: DateTime.utc(2026, 6, 15),
    end: DateTime.utc(2026, 10, 9),
  );
  return [
    for (var index = 0; index < dates.length; index++)
      MarketBar(
        symbol: 'SYNTH',
        provider: MarketDataProvider.alpaca,
        feed: MarketDataFeed.iex,
        timestamp: DateTime.utc(
          int.parse(dates[index].substring(0, 4)),
          int.parse(dates[index].substring(5, 7)),
          int.parse(dates[index].substring(8, 10)),
        ),
        retrievedAt: fixtureNow,
        adjustment: PriceAdjustment.raw,
        open: 100 + index.toDouble(),
        high: 102 + index.toDouble(),
        low: 99 + index.toDouble(),
        close: 101 + index.toDouble(),
        volume: 1000 + index,
      ),
  ];
}

Map<String, Object?> nativeCall(
  String name, {
  String id = 'call_1',
  Object? args = const {'symbol': 'SYNTH'},
}) => {
  'id': id,
  'type': 'function',
  'function': {'name': name, 'arguments': jsonEncode(args)},
};

http.Response nativeResponse(Map<String, Object?> message) => http.Response(
  jsonEncode({
    'model': 'synthetic-local',
    'choices': [
      {
        'message': {'role': 'assistant', ...message},
        'finish_reason': 'stop',
      },
    ],
  }),
  200,
);

ResearchService fixtureResearch({
  required SyntheticResearchMarket market,
  required Future<http.Response> Function(Map<String, dynamic>) respond,
  AssistantConfiguration? configuration,
  AssistantCallBudget? budget,
}) {
  final config = configuration ?? researchConfiguration();
  return ResearchService(
    configuration: config,
    modelClient: config.createResearchClient(
      httpClient: MockClient((request) async {
        expect(request.url.host, '127.0.0.1');
        expect(request.followRedirects, isFalse);
        if (request.url.path.endsWith('/models')) {
          return http.Response('{"data":[{"id":"synthetic-local"}]}', 200);
        }
        return respond(jsonDecode(request.body) as Map<String, dynamic>);
      }),
    )!,
    tools: syntheticTools(market),
    callBudget: budget ?? AssistantCallBudget(configuration: config),
    clock: () => fixtureNow,
  );
}

Future<Map<String, Object?>> runResearch(ResearchService service) =>
    service.research(
      symbol: 'SYNTH',
      prompt: 'Explain only synthetic evidence.',
      holdingDays: 12,
      lookbackDays: 7,
    );

void main() {
  test(
    'deterministic quote and bars retain fixture provenance and bounds',
    () async {
      final market = SyntheticResearchMarket();
      final tools = syntheticTools(market);
      final quote = await tools.execute(
        'get_market_quote',
        {'symbol': 'SYNTH'},
        symbol: 'SYNTH',
        lookbackDays: 7,
      );
      expect(quote['status'], 'ok');
      expect((quote['data'] as Map)['lastPrice'], 17.375);
      expect(
        (quote['sources'] as List).single['publishedAt'],
        '2026-10-12T11:59:50.000Z',
      );
      final bars = await tools.execute(
        'get_daily_bars',
        {'symbol': 'SYNTH'},
        symbol: 'SYNTH',
        lookbackDays: 7,
      );
      expect(bars['status'], 'ok');
      expect((bars['data'] as List).single['volume'], 1000);
      expect(bars['limitations'].toString(), contains('SYNTHETIC'));
      expect(market.barCalls, 1);
    },
  );

  test(
    'technical-indicator tool uses the bounded deterministic engine',
    () async {
      final market = SyntheticResearchMarket();
      final tools = syntheticTools(market);
      final result = await tools.execute(
        'get_technical_indicators',
        {'symbol': 'SYNTH'},
        symbol: 'SYNTH',
        lookbackDays: 7,
      );

      expect(result['status'], 'ok');
      expect((result['data'] as Map)['symbol'], 'SYNTH');
      expect((result['data'] as Map)['lookback'], 20);
      expect((result['sources'] as List), hasLength(1));
      expect(
        ((result['sources'] as List).single as Map)['url'],
        contains('data.alpaca.markets/v2/stocks/SYNTH/bars'),
      );
      expect(market.barCalls, 1);
      final definition = ResearchTools.definitions.singleWhere(
        (entry) =>
            (entry['function'] as Map)['name'] == 'get_technical_indicators',
      );
      expect(
        (definition['function'] as Map)['description'],
        contains('no trading authority'),
      );
      expect(
        ((definition['function'] as Map)['parameters']
            as Map)['additionalProperties'],
        false,
      );
    },
  );

  test('missing SEC permission returns no sources and no network', () async {
    final result = await syntheticTools(SyntheticResearchMarket()).execute(
      'get_sec_filings',
      {'symbol': 'SYNTH'},
      symbol: 'SYNTH',
      lookbackDays: 7,
    );
    expect(result['status'], 'unavailable');
    expect(result['sources'], isEmpty);
    expect(result['limitations'], isNotEmpty);
  });

  test(
    'SEC tool dispatch returns deterministic permitted metadata evidence',
    () async {
      var secNow = fixtureNow;
      final sec = SecFilingsClient(
        permitted: true,
        userAgent: 'SyntheticFixture fixture@example.test',
        clock: () => secNow,
        delay: (duration) async {
          secNow = secNow.add(duration);
        },
        client: MockClient((request) async {
          if (request.url.path.endsWith('company_tickers.json')) {
            return http.Response(
              jsonEncode({
                '0': {
                  'ticker': 'SYNTH',
                  'cik_str': 123,
                  'title': 'Synthetic issuer',
                },
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode({
              'cik': 123,
              'filings': {
                'recent': {
                  'form': ['10-Q'],
                  'filingDate': ['2026-10-09'],
                  'accessionNumber': ['0000000123-26-000001'],
                  'primaryDocument': ['synthetic.htm'],
                },
              },
            }),
            200,
          );
        }),
      );
      final tools = ResearchTools(
        marketData: null,
        provider: MarketDataProvider.alpaca,
        secFilings: sec,
        clock: () => fixtureNow,
      );
      final result = await tools.execute(
        'get_sec_filings',
        {'symbol': 'SYNTH'},
        symbol: 'SYNTH',
        lookbackDays: 7,
      );
      expect(result['status'], 'ok', reason: result.toString());
      final source = (result['sources'] as List).single as Map;
      expect(source['publishedAt'], '2026-10-09');
      expect(source['retrievedAt'], secNow.toIso8601String());
      expect(
        source['url'],
        'https://www.sec.gov/Archives/edgar/data/123/000000012326000001/synthetic.htm',
      );
    },
  );

  test(
    'market provider quota/errors return sanitized explicit limitations',
    () async {
      final market = SyntheticResearchMarket()..failProvider = true;
      for (final name in ['get_market_quote', 'get_daily_bars']) {
        final result = await syntheticTools(
          market,
        ).execute(name, {'symbol': 'SYNTH'}, symbol: 'SYNTH', lookbackDays: 7);
        expect(result['status'], 'unavailable');
        expect(result['sources'], isEmpty);
        expect(result['limitations'].toString(), contains('provider switch'));
        expect(result.toString(), isNot(contains('private upstream')));
      }
    },
  );

  test(
    'crossed quotes fail and old trade prices cannot inherit newer quote freshness',
    () async {
      final market = SyntheticResearchMarket();
      final tools = syntheticTools(market);
      market.overrideQuote = MarketQuote(
        symbol: 'SYNTH',
        provider: MarketDataProvider.alpaca,
        feed: MarketDataFeed.iex,
        retrievedAt: fixtureNow,
        lastPrice: 17.375,
        lastTradeAt: fixtureNow,
        bidPrice: 18,
        askPrice: 17,
      );
      expect(
        (await tools.execute(
          'get_market_quote',
          {'symbol': 'SYNTH'},
          symbol: 'SYNTH',
          lookbackDays: 7,
        ))['status'],
        'unavailable',
      );
      market.overrideQuote = MarketQuote(
        symbol: 'SYNTH',
        provider: MarketDataProvider.alpaca,
        feed: MarketDataFeed.iex,
        retrievedAt: fixtureNow,
        lastPrice: 17.375,
        lastTradeAt: fixtureNow.subtract(const Duration(days: 1)),
        quoteAt: fixtureNow,
        bidPrice: 17,
        askPrice: 18,
      );
      final result = await tools.execute(
        'get_market_quote',
        {'symbol': 'SYNTH'},
        symbol: 'SYNTH',
        lookbackDays: 7,
      );
      expect(result['status'], 'ok');
      expect(
        result['limitations'].toString(),
        contains('Last trade price is stale'),
      );
    },
  );

  test('empty/mismatched quotes and bars explicitly unavailable', () async {
    final market = SyntheticResearchMarket()..unavailable = true;
    final tools = syntheticTools(market);
    expect(
      (await tools.execute(
        'get_market_quote',
        {'symbol': 'SYNTH'},
        symbol: 'SYNTH',
        lookbackDays: 7,
      ))['status'],
      'unavailable',
    );
    market.unavailable = false;
    market.returnedSymbol = 'OTHER';
    for (final name in ['get_market_quote', 'get_daily_bars']) {
      final result = await tools.execute(
        name,
        {'symbol': 'SYNTH'},
        symbol: 'SYNTH',
        lookbackDays: 7,
      );
      expect(result['status'], 'unavailable');
      expect(result['sources'], isEmpty);
    }
    market.overrideBars = [];
    expect(
      (await tools.execute(
        'get_daily_bars',
        {'symbol': 'SYNTH'},
        symbol: 'SYNTH',
        lookbackDays: 7,
      ))['status'],
      'unavailable',
    );
  });

  test(
    'native cycle sends linked actual tool result before final explanation',
    () async {
      var calls = 0;
      final market = SyntheticResearchMarket();
      final config = researchConfiguration({
        'OPENAI_API_KEY': 'synthetic-never-used',
      });
      final budget = AssistantCallBudget(configuration: config);
      final service = fixtureResearch(
        market: market,
        configuration: config,
        budget: budget,
        respond: (body) async {
          expect(body['tools'], hasLength(4));
          final messages = body['messages'] as List;
          final systemPrompt = (messages.first as Map)['content'] as String;
          expect(systemPrompt, contains('code-computed indicators'));
          expect(systemPrompt, contains('exact returned values and units'));
          expect(systemPrompt, contains('do not recalculate'));
          expect(systemPrompt, contains('numeric forecasts'));
          expect(systemPrompt, contains('not authored by you'));
          if (++calls == 1) {
            return nativeResponse({
              'tool_calls': [nativeCall('get_market_quote')],
            });
          }
          final result = messages.last as Map;
          expect(result['role'], 'tool');
          expect(result['tool_call_id'], 'call_1');
          expect(
            jsonDecode(result['content'] as String)['data']['lastPrice'],
            17.375,
          );
          return nativeResponse({
            'content': 'Synthetic quote is 17.375, not live data.',
          });
        },
      );
      final result = await runResearch(service);
      expect(result['provider'], 'lmstudio');
      expect(result['toolsUsed'], ['get_market_quote']);
      expect(result['sources'], hasLength(1));
      expect(
        result['limitations'].toString(),
        contains('No news, social, browsing, trade plans, scoring'),
      );
      expect(
        result['limitations'].toString(),
        contains('deterministic code-computed metrics only'),
      );
      expect(budget.callsStarted, 2);
      expect(market.quoteCalls, 1);
    },
  );

  for (final call in [
    nativeCall('execute_shell'),
    nativeCall('get_market_quote', args: {'symbol': 'OTHER'}),
    nativeCall(
      'get_market_quote',
      args: {'symbol': 'SYNTH', 'url': 'https://evil.test'},
    ),
    nativeCall(
      'get_technical_indicators',
      args: {'symbol': 'SYNTH', 'lookback': 999},
    ),
    nativeCall('get_market_quote', args: ['SYNTH']),
    {
      'id': 'bad',
      'type': 'function',
      'function': {'name': 'get_market_quote', 'arguments': '{'},
    },
  ]) {
    test('rejects invalid tool before provider execution: $call', () async {
      final market = SyntheticResearchMarket();
      final service = fixtureResearch(
        market: market,
        respond: (_) async => nativeResponse({
          'tool_calls': [call],
        }),
      );
      await expectLater(
        runResearch(service),
        throwsA(isA<AssistantModelException>()),
      );
      expect(market.quoteCalls, 0);
    });
  }

  test('batch is completely validated before executing any tool', () async {
    final market = SyntheticResearchMarket();
    final service = fixtureResearch(
      market: market,
      respond: (_) async => nativeResponse({
        'tool_calls': [
          nativeCall('get_market_quote'),
          nativeCall('execute_shell', id: 'call_2'),
        ],
      }),
    );
    await expectLater(
      runResearch(service),
      throwsA(isA<AssistantModelException>()),
    );
    expect(market.quoteCalls, 0);
  });

  test('four tools, three turns and final tool_choice none', () async {
    var calls = 0;
    final market = SyntheticResearchMarket();
    final service = fixtureResearch(
      market: market,
      respond: (body) async {
        calls++;
        if (calls == 3) {
          expect(body['tool_choice'], 'none');
          return nativeResponse({
            'content': 'Only synthetic quotes were returned.',
          });
        }
        return nativeResponse({
          'tool_calls': [
            nativeCall('get_market_quote', id: 'turn_${calls}_a'),
            nativeCall('get_market_quote', id: 'turn_${calls}_b'),
          ],
        });
      },
    );
    final result = await runResearch(service);
    expect(result['toolsUsed'], hasLength(4));
    expect(result['usage'], containsPair('modelTurns', 3));
    expect(market.quoteCalls, 4);
  });

  test(
    'fifth tool and tool calls on last turn fail without executing them',
    () async {
      for (final excessiveBatch in [true, false]) {
        var calls = 0;
        final market = SyntheticResearchMarket();
        final service = fixtureResearch(
          market: market,
          respond: (_) async {
            calls++;
            return nativeResponse({
              'tool_calls': [
                for (var i = 0; i < (excessiveBatch ? 5 : 1); i++)
                  nativeCall('get_market_quote', id: 'turn_${calls}_$i'),
              ],
            });
          },
        );
        await expectLater(
          runResearch(service),
          throwsA(isA<AssistantModelException>()),
        );
        expect(market.quoteCalls, excessiveBatch ? 0 : 2);
        expect(calls, excessiveBatch ? 1 : 3);
      }
    },
  );

  test('process budget counts each chat, not just research requests', () async {
    final config = researchConfiguration({'A_TRADER_ASSISTANT_MAX_CALLS': '1'});
    var chats = 0;
    final budget = AssistantCallBudget(configuration: config);
    final service = fixtureResearch(
      market: SyntheticResearchMarket(),
      configuration: config,
      budget: budget,
      respond: (_) async {
        chats++;
        return nativeResponse({
          'tool_calls': [nativeCall('get_market_quote')],
        });
      },
    );
    await expectLater(
      runResearch(service),
      throwsA(isA<AssistantRequestException>()),
    );
    expect(chats, 1);
    expect(budget.callsStarted, 1);
  });

  test('Ask AI and local research share the same process call cap', () async {
    final config = researchConfiguration({'A_TRADER_ASSISTANT_MAX_CALLS': '3'});
    final budget = AssistantCallBudget(configuration: config);
    final market = SyntheticResearchMarket();
    var chats = 0;
    final research = fixtureResearch(
      market: market,
      configuration: config,
      budget: budget,
      respond: (_) async => ++chats == 1
          ? nativeResponse({
              'tool_calls': [nativeCall('get_market_quote')],
            })
          : nativeResponse({'content': 'Synthetic evidence only.'}),
    );
    await runResearch(research);
    final ask = AssistantService(
      configuration: config,
      marketData: market,
      modelClient: _SyntheticExplanation(),
      marketDataProvider: 'alpaca',
      marketDataCoverage: 'Synthetic fixture only.',
      callBudget: budget,
      clock: () => fixtureNow,
    );
    await ask.explain(symbol: 'SYNTH', prompt: 'Explain fixture.');
    expect(budget.callsStarted, 3);
    await expectLater(
      runResearch(research),
      throwsA(
        isA<AssistantRequestException>().having(
          (error) => error.statusCode,
          'shared cap',
          429,
        ),
      ),
    );
    expect(chats, 2);
  });

  for (final text in [
    'Invented https://evil.test/news',
    'Unsafe javascript:alert(1)',
    '[citation](/invented)',
    '[citation](https://www.sec.gov/not-returned)',
    'Invented source evil.test/news',
  ]) {
    test('rejects unsafe/invented citations: $text', () async {
      final service = fixtureResearch(
        market: SyntheticResearchMarket(),
        respond: (_) async => nativeResponse({'content': text}),
      );
      await expectLater(
        runResearch(service),
        throwsA(isA<AssistantModelException>()),
      );
    });
  }

  test(
    'exact evidence URL accepted and source metadata is not model-authored',
    () async {
      var calls = 0;
      const url =
          'https://data.alpaca.markets/v2/stocks/SYNTH/trades/latest?feed=iex';
      final result = await runResearch(
        fixtureResearch(
          market: SyntheticResearchMarket(),
          respond: (_) async => ++calls == 1
              ? nativeResponse({
                  'tool_calls': [nativeCall('get_market_quote')],
                })
              : nativeResponse({
                  'content': 'Synthetic [evidence]($url).',
                  'sources': [
                    {'url': 'https://invented.test', 'retrievedAt': 'invented'},
                  ],
                }),
        ),
      );
      expect((result['sources'] as List).single['url'], url);
      expect(
        (result['sources'] as List).single['retrievedAt'],
        fixtureNow.toIso8601String(),
      );
    },
  );

  test(
    'missing native calls reports unverified capability, not tool success',
    () async {
      final result = await runResearch(
        fixtureResearch(
          market: SyntheticResearchMarket(),
          respond: (_) async =>
              nativeResponse({'content': 'No data was obtained.'}),
        ),
      );
      expect(result['toolsUsed'], isEmpty);
      expect(result['sources'], isEmpty);
      expect(result['limitations'].toString(), contains('No native tool call'));
    },
  );

  test('local failure never uses OpenAI', () async {
    final config = researchConfiguration({'OPENAI_API_KEY': 'synthetic-key'});
    var chats = 0;
    final service = fixtureResearch(
      market: SyntheticResearchMarket(),
      configuration: config,
      respond: (_) async {
        chats++;
        return http.Response('secret upstream detail', 500);
      },
    );
    await expectLater(
      runResearch(service),
      throwsA(isA<AssistantModelException>()),
    );
    expect(chats, 1);
  });

  test('research endpoint and real frontend contract agree', () async {
    var calls = 0;
    final research = fixtureResearch(
      market: SyntheticResearchMarket(),
      respond: (_) async {
        if (++calls == 1) {
          return nativeResponse({
            'tool_calls': [nativeCall('get_market_quote')],
          });
        }
        return nativeResponse({'content': 'Synthetic evidence only.'});
      },
    );
    final server = ATraderServer(
      bindAddress: '127.0.0.1',
      port: 0,
      selectedProvider: MarketDataProvider.alpaca,
      marketDataClient: null,
      providerStatuses: {},
      assistantConfiguration: research.configuration,
      assistantService: null,
      researchService: research,
      allowedOrigin: 'http://localhost:3000',
    );
    await server.start();
    addTearDown(() => server.close(force: true));
    final client = frontend.AssistantService();
    addTearDown(client.close);
    final result = await client.research(
      server.uri.toString(),
      'SYNTH',
      'Synthetic evidence.',
      holdingDays: 12,
    );
    expect(result.toolsUsed, ['get_market_quote']);
    expect(result.sources.single.title, contains('SYNTHETIC'));
    final httpClient = http.Client();
    addTearDown(httpClient.close);
    for (final extra in [
      {'holdingDays': 366, 'lookbackDays': 7},
      {'holdingDays': '12', 'lookbackDays': 7},
      {'holdingDays': 12, 'lookbackDays': 7, 'url': 'https://evil.test'},
    ]) {
      final response = await httpClient.post(
        server.uri.resolve('/api/v1/assistant/research'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'symbol': 'SYNTH', 'prompt': 'Test', ...extra}),
      );
      expect(response.statusCode, 400);
    }
  });

  test(
    'real LM Studio native tool cycle with synthetic quote only',
    () async {
      final config = AssistantConfiguration.fromEnvironment(
        Platform.environment,
      );
      expect(
        config.researchEnabled,
        isTrue,
        reason: 'Local-only and processing confirmation are required.',
      );
      final observed = _ObservedLocalClient();
      final model = config.createResearchClient(httpClient: observed)!;
      addTearDown(observed.close);
      final market = SyntheticResearchMarket();
      final service = ResearchService(
        configuration: config,
        modelClient: model,
        tools: syntheticTools(market),
        callBudget: AssistantCallBudget(configuration: config),
        clock: () => fixtureNow,
      );
      final result = await service.research(
        symbol: 'SYNTH',
        prompt:
            'This is a synthetic fixture test, not a real security. '
            'Call get_market_quote for SYNTH. After receiving the tool result, '
            'state the exact fixture lastPrice and that it is synthetic, not live. '
            'Do not call daily bars or SEC and do not include URLs.',
        holdingDays: 12,
        lookbackDays: 7,
      );
      expect(
        result['toolsUsed'],
        contains('get_market_quote'),
        reason: 'No native tool call: model tool support not demonstrated.',
      );
      expect(market.quoteCalls, greaterThan(0));
      expect(observed.receivedToolResult, isTrue);
      expect(result['explanation'].toString(), contains('17.375'));
      expect(
        result['explanation'].toString().toLowerCase(),
        contains('synthetic'),
      );
      // Only synthetic fixture content and bounded counters are printed.
      // ignore: avoid_print
      print(
        jsonEncode({
          'nativeCycle': 'verified',
          'model': model.model,
          'toolsUsed': result['toolsUsed'],
          'usage': result['usage'],
          'toolResultSent': observed.receivedToolResult,
          'explanation': result['explanation'],
        }),
      );
    },
    skip: Platform.environment['A_TRADER_NATIVE_TOOL_SMOKE'] != 'true',
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'real LM Studio native indicator tool cycle with synthetic daily history',
    () async {
      final config = AssistantConfiguration.fromEnvironment(
        Platform.environment,
      );
      expect(
        config.researchEnabled,
        isTrue,
        reason: 'Local-only and processing confirmation are required.',
      );
      final observed = _ObservedLocalClient();
      final model = config.createResearchClient(httpClient: observed)!;
      addTearDown(observed.close);
      final market = SyntheticResearchMarket()
        ..overrideBars = syntheticIndicatorHistory();
      final service = ResearchService(
        configuration: config,
        modelClient: model,
        tools: syntheticTools(market),
        callBudget: AssistantCallBudget(configuration: config),
        clock: () => fixtureNow,
      );
      final result = await service.research(
        symbol: 'SYNTH',
        prompt:
            'This is a synthetic fixture test, not a real security. '
            'Call get_technical_indicators for SYNTH. After receiving the '
            'result, summarize only fields present in the deterministic result '
            'and state that it is synthetic, not live data. Do not call other '
            'tools and do not include URLs.',
        holdingDays: 12,
        lookbackDays: 7,
      );
      expect(
        result['toolsUsed'],
        contains('get_technical_indicators'),
        reason: 'No native indicator-tool call was observed from LM Studio.',
      );
      expect(market.barCalls, greaterThan(0));
      expect(observed.receivedIndicatorToolResult, isTrue);
      expect(
        result['sources'].toString(),
        contains('data.alpaca.markets/v2/stocks/SYNTH/bars'),
      );
    },
    skip: Platform.environment['A_TRADER_NATIVE_TOOL_SMOKE'] != 'true',
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

class _ObservedLocalClient extends http.BaseClient {
  final http.Client _client = http.Client();
  bool receivedToolResult = false;
  bool receivedIndicatorToolResult = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request is http.Request && request.method == 'POST') {
      final body = jsonDecode(request.body) as Map;
      for (final message in body['messages'] as List) {
        if (message['role'] == 'tool') {
          final result = jsonDecode(message['content'] as String) as Map;
          if (result['data'] is Map && result['data']['lastPrice'] == 17.375) {
            receivedToolResult = true;
          }
          if (result['data'] is Map &&
              result['data']['formulaVersion'] ==
                  dailyIndicatorFormulaVersion &&
              result['data']['symbol'] == 'SYNTH') {
            receivedIndicatorToolResult = true;
          }
        }
      }
    }
    return _client.send(request);
  }

  @override
  void close() => _client.close();
}

class _SyntheticExplanation implements AssistantModelClient {
  @override
  AssistantProvider get provider => AssistantProvider.lmStudio;

  @override
  String get model => 'synthetic-local';

  @override
  Future<String> generate(
    String input, {
    required int maximumOutputTokens,
  }) async => 'Synthetic fixture explanation only.';
}
