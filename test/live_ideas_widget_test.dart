import 'dart:async';

import 'package:a_trade/main.dart';
import 'package:a_trade/market_data/live_ideas_view.dart';
import 'package:a_trade/market_data/local_market_data_service.dart';
import 'package:a_trade/providers/assistant_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'market_data_fixtures.dart';

Widget view(
  LocalMarketDataService service, {
  String url = 'http://127.0.0.1:8765',
  AssistantService? assistant,
  String prompt = 'Explain the verified quote limitations.',
  DateTime Function()? clock,
}) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      child: LiveIdeasView(
        backendUrl: url,
        service: service,
        assistantService: assistant,
        analysisPrompt: prompt,
        requestClock: clock,
        savedTickers: const {},
        savedOnly: false,
        onToggleSaved: (_) {},
      ),
    ),
  ),
);

Future<void> expandAndTap(WidgetTester tester, String action) async {
  final header = find.byKey(const Key('expand_SOFI'));
  await tester.ensureVisible(header);
  await tester.pumpAndSettle();
  await tester.tap(header);
  await tester.pumpAndSettle();
  final button = find.byKey(Key(action));
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
}

void main() {
  testWidgets(
    'Schwab card preserves metadata and explicitly unavailable daily change',
    (tester) async {
      final market = LocalMarketDataService(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/bars')) {
            return fixtureResponse(
              barsFixture(
                symbol: request.url.queryParameters['symbol']!,
                schwab: true,
              ),
            );
          }
          final body = quoteFixture(
            symbol: request.url.queryParameters['symbol']!,
          );
          body['provider'] = 'schwab';
          body['feed'] = 'schwabEquity';
          final data = body['data'] as Map<String, dynamic>;
          data['provider'] = 'schwab';
          data['feed'] = 'schwabEquity';
          data['realtime'] = false;
          data['quoteType'] = 'NFL';
          data['totalVolume'] = 150000;
          data['freshness'] = 'delayed';
          return fixtureResponse(body);
        }),
      );
      await tester.pumpWidget(view(market, clock: tester.binding.clock.now));
      await tester.pump();
      for (var index = 0; index < 19; index++) {
        await tester.pump(const Duration(seconds: 7));
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(find.text('schwab / schwabEquity'), findsWidgets);
      final header = find.byKey(const Key('expand_SOFI'));
      await tester.ensureVisible(header);
      await tester.tap(header);
      await tester.pumpAndSettle();
      final details = find.byKey(const Key('details_SOFI'));
      await tester.ensureVisible(details);
      await tester.tap(details);
      await tester.pumpAndSettle();
      expect(find.textContaining('Provider realtime: false'), findsOneWidget);
      expect(find.textContaining('quote type: NFL'), findsOneWidget);
      expect(find.textContaining('150000'), findsWidgets);
      expect(find.text('Daily change'), findsOneWidget);
      expect(find.textContaining('Prior regular-session close'), findsWidgets);
    },
  );
  testWidgets('local research is explicit and renders real tool metadata', (
    tester,
  ) async {
    var calls = 0;
    final market = LocalMarketDataService(
      client: MockClient(
        (request) async => fixtureResponse(cardRequestFixture(request)),
      ),
    );
    final assistant = AssistantService(
      client: MockClient((request) async {
        calls++;
        expect(request.url.path, '/api/v1/assistant/research');
        expect(request.body, contains('"holdingDays":10'));
        return fixtureResponse({
          'explanation': 'No verified recent catalyst.',
          'provider': 'lmstudio',
          'model': 'fixture-local',
          'toolsUsed': ['get_market_quote'],
          'limitations': ['News search is not configured.'],
          'sources': <Object>[],
        });
      }),
    );
    await tester.pumpWidget(view(market, assistant: assistant));
    await tester.pumpAndSettle();
    expect(calls, 0);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -300));
    await tester.pumpAndSettle();
    await expandAndTap(tester, 'research_ai_SOFI');
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.text('Tools used: get_market_quote'), findsOneWidget);
    expect(find.text('News search is not configured.'), findsOneWidget);
  });

  testWidgets('changing the prompt discards an in-flight explanation', (
    tester,
  ) async {
    final marketService = LocalMarketDataService(
      client: MockClient(
        (request) async => fixtureResponse(cardRequestFixture(request)),
      ),
    );
    final response = Completer<http.Response>();
    final assistant = AssistantService(
      client: MockClient((_) async => response.future),
    );
    await tester.pumpWidget(view(marketService, assistant: assistant));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -300));
    await tester.pumpAndSettle();
    await expandAndTap(tester, 'ask_ai_SOFI');
    await tester.pump();
    await tester.pumpWidget(
      view(marketService, assistant: assistant, prompt: 'New prompt.'),
    );
    response.complete(
      fixtureResponse({
        'explanation': 'Outdated model response.',
        'provider': 'lmstudio',
        'model': 'fixture-local',
      }),
    );
    await tester.pumpAndSettle();
    expect(find.text('Outdated model response.'), findsNothing);
    expect(find.byKey(const Key('analysis_SOFI')), findsNothing);
  });

  testWidgets(
    'Ask AI is explicit, displays local model response and sends no credentials',
    (tester) async {
      var analysisCalls = 0;
      final marketService = LocalMarketDataService(
        client: MockClient(
          (request) async => fixtureResponse(cardRequestFixture(request)),
        ),
      );
      final assistant = AssistantService(
        client: MockClient((request) async {
          analysisCalls++;
          expect(request.body, contains('SOFI'));
          return fixtureResponse({
            'explanation':
                'Insufficient evidence for a trade. Verify liquidity.',
            'provider': 'lmstudio',
            'model': 'fixture-local',
          });
        }),
      );
      await tester.pumpWidget(
        MyApp(marketDataService: marketService, assistantService: assistant),
      );
      await tester.pumpAndSettle();
      expect(analysisCalls, 0);
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -400));
      await tester.pumpAndSettle();
      await expandAndTap(tester, 'ask_ai_SOFI');
      await tester.pumpAndSettle();
      expect(analysisCalls, 1);
      expect(find.text('lmstudio / fixture-local'), findsOneWidget);
      expect(
        find.textContaining('Insufficient evidence for a trade.'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'Ask AI reports disabled model explicitly without fabricated response',
    (tester) async {
      final marketService = LocalMarketDataService(
        client: MockClient(
          (request) async => fixtureResponse(cardRequestFixture(request)),
        ),
      );
      final assistant = AssistantService(
        client: MockClient(
          (_) async => fixtureResponse({'error': 'private details'}, 503),
        ),
      );
      await tester.pumpWidget(
        MyApp(marketDataService: marketService, assistantService: assistant),
      );
      await tester.pumpAndSettle();
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -400));
      await tester.pumpAndSettle();
      await expandAndTap(tester, 'ask_ai_SOFI');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('analysis_error_SOFI')), findsOneWidget);
      expect(find.textContaining('Assistant unavailable'), findsOneWidget);
      expect(find.textContaining('private details'), findsNothing);
    },
  );

  testWidgets('ten automatic quotes; tab changes and settings do not reload', (
    tester,
  ) async {
    final symbols = <String>[];
    final service = LocalMarketDataService(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/quote')) {
          symbols.add(request.url.queryParameters['symbol']!);
        }
        return fixtureResponse(cardRequestFixture(request));
      }),
    );
    await tester.pumpWidget(MyApp(marketDataService: service));
    await tester.pumpAndSettle();
    expect(symbols, temporaryStocks.map((stock) => stock.$1).toList());
    expect(find.text('\$123.5000'), findsNWidgets(10));
    expect(find.textContaining('not trade recommendations'), findsOneWidget);
    await tester.tap(find.text('History'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ideas'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings_button')));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(symbols.length, 10);
    await tester.tap(find.byKey(const Key('refresh_ideas')));
    await tester.pumpAndSettle();
    expect(symbols.length, 20);
  });

  for (final status in [429, 503]) {
    testWidgets(
      'HTTP $status stops the run with explicit errors and no prices',
      (tester) async {
        var calls = 0;
        final service = LocalMarketDataService(
          client: MockClient((_) async {
            calls++;
            return fixtureResponse({
              'error': 'do not expose arbitrary body',
            }, status);
          }),
        );
        await tester.pumpWidget(view(service));
        await tester.pumpAndSettle();
        expect(calls, 1);
        expect(find.textContaining('Not requested:'), findsNWidgets(19));
        expect(
          find.textContaining('do not expose arbitrary body'),
          findsNothing,
        );
        expect(find.text('\$123.5000'), findsNothing);
        expect(find.text('Refresh quotes & charts'), findsOneWidget);
      },
    );
  }

  testWidgets('missing symbol does not prevent other quotes', (tester) async {
    var calls = 0;
    final service = LocalMarketDataService(
      client: MockClient((request) async {
        calls++;
        final symbol = request.url.queryParameters['symbol']!;
        return symbol == 'SOFI' && request.url.path.endsWith('/quote')
            ? fixtureResponse({'error': 'missing'}, 404)
            : fixtureResponse(cardRequestFixture(request));
      }),
    );
    await tester.pumpWidget(view(service, clock: tester.binding.clock.now));
    await tester.pump();
    await tester.pump(const Duration(seconds: 11));
    await tester.pumpAndSettle();
    expect(calls, 20);
    expect(
      find.text('No market data is available for this ticker.'),
      findsOneWidget,
    );
    expect(find.text('\$123.5000'), findsNWidgets(9));
  });

  testWidgets('Twelve Data automatic requests are paced eleven seconds apart', (
    tester,
  ) async {
    var calls = 0;
    final service = LocalMarketDataService(
      client: MockClient((request) async {
        calls++;
        return fixtureResponse(cardRequestFixture(request, twelve: true));
      }),
    );
    await tester.pumpWidget(view(service, clock: tester.binding.clock.now));
    await tester.pump();
    expect(calls, 1);
    await tester.pump(const Duration(seconds: 10));
    expect(calls, 1);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(calls, 2);
    for (var index = 2; index < 20; index++) {
      await tester.pump(const Duration(seconds: 11));
      await tester.pump();
    }
    expect(calls, 20);
    expect(find.text('Refresh quotes & charts'), findsOneWidget);
  });

  testWidgets('backend changes discard stale in-flight responses', (
    tester,
  ) async {
    final oldResponse = Completer<http.Response>();
    final calls = <Uri>[];
    final service = LocalMarketDataService(
      client: MockClient((request) async {
        calls.add(request.url);
        if (request.url.port == 8765) return oldResponse.future;
        if (request.url.path.endsWith('/bars')) {
          return fixtureResponse(cardRequestFixture(request));
        }
        final fixture = quoteFixture(
          symbol: request.url.queryParameters['symbol']!,
        );
        (fixture['data']! as Map<String, Object?>)['lastPrice'] = 9.25;
        return fixtureResponse(fixture);
      }),
    );
    await tester.pumpWidget(view(service, clock: tester.binding.clock.now));
    await tester.pump();
    await tester.pumpWidget(
      view(
        service,
        url: 'http://127.0.0.1:8766',
        clock: tester.binding.clock.now,
      ),
    );
    await tester.pump(const Duration(seconds: 11));
    await tester.pumpAndSettle();
    oldResponse.complete(fixtureResponse(quoteFixture(symbol: 'SOFI')));
    await tester.pumpAndSettle();
    expect(calls.where((url) => url.port == 8765).length, 1);
    expect(calls.where((url) => url.port == 8766).length, 20);
    expect(find.text('\$9.2500'), findsNWidgets(10));
    expect(find.text('\$123.5000'), findsNothing);
  });

  testWidgets('disposal stops subsequent requests', (tester) async {
    final response = Completer<http.Response>();
    var calls = 0;
    final service = LocalMarketDataService(
      client: MockClient((_) async {
        calls++;
        return response.future;
      }),
    );
    await tester.pumpWidget(view(service));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    response.complete(fixtureResponse(quoteFixture(symbol: 'SOFI')));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(tester.takeException(), isNull);
  });
}
