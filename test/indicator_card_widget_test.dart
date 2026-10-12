import 'dart:async';

import 'package:a_trade/market_data/live_ideas_view.dart';
import 'package:a_trade/market_data/local_market_data_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'indicator_card_fixtures.dart';
import 'market_data_fixtures.dart';

Widget indicatorView(
  LocalMarketDataService service, {
  String url = 'http://localhost:8765',
}) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      child: LiveIdeasView(
        backendUrl: url,
        service: service,
        savedTickers: const {},
        savedOnly: false,
        onToggleSaved: (_) {},
      ),
    ),
  ),
);

Future<void> tapIndicators(WidgetTester tester) async {
  final button = find.byKey(const Key('indicators_SOFI'));
  await tester.ensureVisible(button);
  await tester.tap(button);
}

void main() {
  testWidgets(
    'card indicators request only on click and show calculated provenance',
    (tester) async {
      var indicatorCalls = 0;
      final service = LocalMarketDataService(
        client: MockClient((request) async {
          final symbol = request.url.queryParameters['symbol']!;
          if (request.url.path.endsWith('/indicators')) {
            indicatorCalls++;
            return fixtureResponse(indicatorCardFixture(symbol: symbol));
          }
          return fixtureResponse(quoteFixture(symbol: symbol));
        }),
      );
      await tester.pumpWidget(indicatorView(service));
      await tester.pumpAndSettle();
      expect(indicatorCalls, 0);
      await tapIndicators(tester);
      await tester.pumpAndSettle();
      expect(indicatorCalls, 1);
      expect(find.byKey(const Key('indicator_result_SOFI')), findsOneWidget);
      expect(find.textContaining('Calculated in Dart'), findsOneWidget);
      expect(find.textContaining('SMA: 7.5000'), findsOneWidget);
      expect(find.textContaining('RSI: 62.5000'), findsOneWidget);
      expect(find.textContaining('SMA trend: rising'), findsOneWidget);
      expect(
        find.textContaining('raw-price corporate actions unverified'),
        findsOneWidget,
      );
      expect(find.textContaining('Source session: 2026-10-09'), findsOneWidget);
    },
  );

  testWidgets(
    'card unavailable data is explicit and never a neutral indicator',
    (tester) async {
      final service = LocalMarketDataService(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/indicators')) {
            return fixtureResponse({
              'status': 'unavailable',
              'data': null,
              'sources': [],
              'coverage': 'Fixture unavailable',
              'limitations': ['No completed bars are available.'],
            });
          }
          return fixtureResponse(
            quoteFixture(symbol: request.url.queryParameters['symbol']!),
          );
        }),
      );
      await tester.pumpWidget(indicatorView(service));
      await tester.pumpAndSettle();
      await tapIndicators(tester);
      await tester.pumpAndSettle();
      expect(find.text('Data unavailable'), findsOneWidget);
      expect(find.text('No completed bars are available.'), findsOneWidget);
      expect(find.textContaining('RSI:'), findsNothing);
    },
  );

  testWidgets('indicator failures show safe errors without retries', (
    tester,
  ) async {
    var calls = 0;
    final service = LocalMarketDataService(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/indicators')) {
          calls++;
          return http.Response('{"error":"credential private detail"}', 429);
        }
        return fixtureResponse(
          quoteFixture(symbol: request.url.queryParameters['symbol']!),
        );
      }),
    );
    await tester.pumpWidget(indicatorView(service));
    await tester.pumpAndSettle();
    await tapIndicators(tester);
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.byKey(const Key('indicator_error_SOFI')), findsOneWidget);
    expect(find.textContaining('quota exhausted'), findsOneWidget);
    expect(find.textContaining('private detail'), findsNothing);
  });

  testWidgets('backend changes discard an in-flight indicator response', (
    tester,
  ) async {
    final pending = Completer<http.Response>();
    final service = LocalMarketDataService(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/indicators')) return pending.future;
        return fixtureResponse(
          quoteFixture(symbol: request.url.queryParameters['symbol']!),
        );
      }),
    );
    await tester.pumpWidget(indicatorView(service));
    await tester.pumpAndSettle();
    await tapIndicators(tester);
    await tester.pump();
    expect(find.text('Calculating indicators...'), findsOneWidget);
    await tester.pumpWidget(
      indicatorView(service, url: 'http://127.0.0.1:8765'),
    );
    pending.complete(fixtureResponse(indicatorCardFixture()));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('indicator_result_SOFI')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'refresh clears prior indicator snapshot without fetching indicators',
    (tester) async {
      var calls = 0;
      final service = LocalMarketDataService(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/indicators')) {
            calls++;
            return fixtureResponse(indicatorCardFixture());
          }
          return fixtureResponse(
            quoteFixture(symbol: request.url.queryParameters['symbol']!),
          );
        }),
      );
      await tester.pumpWidget(indicatorView(service));
      await tester.pumpAndSettle();
      await tapIndicators(tester);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('refresh_ideas')));
      await tester.tap(find.byKey(const Key('refresh_ideas')));
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(find.byKey(const Key('indicator_result_SOFI')), findsNothing);
    },
  );

  testWidgets(
    'pending indicator action disables overlapping requests and disposal ignores result',
    (tester) async {
      final pending = Completer<http.Response>();
      var calls = 0;
      final service = LocalMarketDataService(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/indicators')) {
            calls++;
            return pending.future;
          }
          return fixtureResponse(
            quoteFixture(symbol: request.url.queryParameters['symbol']!),
          );
        }),
      );
      await tester.pumpWidget(indicatorView(service));
      await tester.pumpAndSettle();
      await tapIndicators(tester);
      await tester.pump();
      final refresh = tester.widget<OutlinedButton>(
        find.byKey(const Key('refresh_ideas')),
      );
      expect(refresh.onPressed, isNull);
      final other = tester.widget<OutlinedButton>(
        find.byKey(const Key('indicators_RKLB')),
      );
      expect(other.onPressed, isNull);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      pending.complete(fixtureResponse(indicatorCardFixture()));
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
