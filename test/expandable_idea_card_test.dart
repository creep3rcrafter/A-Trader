import 'package:a_trade/main.dart';
import 'package:a_trade/market_data/live_ideas_view.dart';
import 'package:a_trade/market_data/local_market_data_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';

import 'market_data_fixtures.dart';

Future<void> toggleCard(WidgetTester tester, String ticker) async {
  final header = find.byKey(Key('expand_$ticker'));
  await tester.ensureVisible(header);
  await tester.pumpAndSettle();
  await tester.tap(header);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'independent expansion survives refresh, saved filters and tabs',
    (tester) async {
      var calls = 0;
      final service = LocalMarketDataService(
        client: MockClient((request) async {
          calls++;
          return fixtureResponse(cardRequestFixture(request));
        }),
      );
      await tester.pumpWidget(MyApp(marketDataService: service));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('expanded_SOFI')), findsNothing);
      await toggleCard(tester, 'SOFI');
      await toggleCard(tester, 'RKLB');
      expect(find.byKey(const Key('expanded_SOFI')), findsOneWidget);
      expect(find.byKey(const Key('expanded_RKLB')), findsOneWidget);
      await toggleCard(tester, 'SOFI');
      expect(find.byKey(const Key('expanded_SOFI')), findsNothing);
      expect(find.byKey(const Key('expanded_RKLB')), findsOneWidget);
      expect(calls, 20);
      await tester.ensureVisible(find.byKey(const Key('save_RKLB')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('save_RKLB')));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(Scrollable).first, const Offset(0, 10000));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Saved (1)'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('expanded_RKLB')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('save_RKLB')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('save_RKLB')));
      await tester.pumpAndSettle();
      expect(find.textContaining('No saved stocks yet'), findsOneWidget);
      await tester.ensureVisible(find.text('Ideas'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ideas'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('expanded_RKLB')), findsOneWidget);
      await tester.tap(find.text('History'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ideas'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('expanded_RKLB')), findsOneWidget);
      expect(calls, 20);
      await tester.ensureVisible(find.byKey(const Key('refresh_ideas')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('refresh_ideas')));
      await tester.pumpAndSettle();
      expect(calls, 40);
      expect(find.byKey(const Key('expanded_RKLB')), findsOneWidget);
      expect(find.byKey(const Key('expanded_SOFI')), findsNothing);
    },
  );

  for (final width in [320.0, 760.0, 1024.0, 1440.0]) {
    for (final brightness in Brightness.values) {
      testWidgets('card is honest and responsive at $width / $brightness', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final semantics = tester.ensureSemantics();
        var calls = 0;
        final service = LocalMarketDataService(
          client: MockClient((request) async {
            calls++;
            return fixtureResponse(cardRequestFixture(request));
          }),
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: brightness),
            home: Scaffold(
              body: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: LiveIdeasView(
                    backendUrl: 'http://localhost:8765',
                    service: service,
                    savedTickers: const {},
                    savedOnly: false,
                    onToggleSaved: (_) {},
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final card = find.byKey(const Key('idea_SOFI'));
        Finder inCard(String text) =>
            find.descendant(of: card, matching: find.text(text));
        expect(inCard('Entry'), findsOneWidget);
        expect(inCard('First Target'), findsOneWidget);
        expect(inCard('Extended Target'), findsOneWidget);
        expect(inCard('Unavailable'), findsNWidgets(3));
        expect(inCard('\$123.5000'), findsOneWidget);
        expect(inCard('SoFi Technologies'), findsOneWidget);
        expect(inCard('Daily change'), findsNothing);
        await toggleCard(tester, 'SOFI');
        expect(inCard('Unavailable'), findsNWidgets(10));
        expect(inCard('Daily change'), findsOneWidget);
        expect(
          inCard('Prior regular-session close not supplied.'),
          findsOneWidget,
        );
        expect(inCard('AI direction / confidence'), findsOneWidget);
        expect(find.textContaining('0%'), findsNothing);
        expect(find.textContaining('Neutral'), findsNothing);
        expect(find.textContaining('Monitoring'), findsNothing);
        expect(
          tester.getSemantics(find.byKey(const Key('expand_SOFI'))),
          matchesSemantics(
            hasExpandedState: true,
            isExpanded: true,
            isButton: true,
            isFocusable: true,
            hasTapAction: true,
            hasFocusAction: true,
            label: 'SOFI\nSoFi Technologies',
          ),
        );
        Size columnSize(String label) => tester.getSize(
          find
              .ancestor(of: inCard(label), matching: find.byType(Expanded))
              .first,
        );
        expect(
          columnSize('Entry').width,
          closeTo(columnSize('First Target').width, 0.01),
        );
        expect(
          columnSize('Entry').width,
          closeTo(columnSize('Extended Target').width, 0.01),
        );
        expect(calls, 20);
        expect(tester.takeException(), isNull);
        await toggleCard(tester, 'SOFI');
        expect(inCard('Daily change'), findsNothing);
        expect(calls, 20);
        semantics.dispose();
      });
    }
  }
}
