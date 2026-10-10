import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:a_trade/main.dart';
import 'package:a_trade/providers/provider_health.dart';

Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    250,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

Future<void> _scrollSettingsTo(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    250,
    scrollable: find
        .descendant(
          of: find.byKey(const Key('settings_list')),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.pumpAndSettle();
}

Future<void> _scrollToTop(WidgetTester tester) async {
  await tester.drag(find.byType(Scrollable).first, const Offset(0, 2000));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('dashboard clearly labels all recommendations as mock', (
    tester,
  ) async {
    await tester.pumpWidget(const MyApp());

    expect(find.text('A-Trader'), findsOneWidget);
    expect(find.text('Private swing-trading research'), findsNothing);
    expect(
      find.text('MOCK DATA — NOT LIVE MARKET INFORMATION'),
      findsOneWidget,
    );
    expect(find.textContaining('NOVA'), findsOneWidget);
    expect(find.textContaining('MOCK'), findsWidgets);
    expect(find.text('Ask GPT Why (mock)'), findsNWidgets(3));
    expect(
      tester
          .widget<MaterialApp>(find.byType(MaterialApp))
          .theme!
          .scaffoldBackgroundColor,
      const Color(0xFFF5FAFF),
    );
  });

  testWidgets('recommendation details expand to supporting evidence', (
    tester,
  ) async {
    await tester.pumpWidget(const MyApp());

    await _scrollTo(tester, find.byKey(const Key('details_NOVA')));
    await tester.tap(find.byKey(const Key('details_NOVA')));
    await tester.pumpAndSettle();

    expect(find.text('Supporting evidence'), findsOneWidget);
    expect(find.textContaining('fictional company release'), findsOneWidget);
    expect(find.text('Indicators'), findsOneWidget);
    expect(find.text('Risks'), findsOneWidget);
  });

  testWidgets('ideas can be saved and reviewed in the saved section', (
    tester,
  ) async {
    await tester.pumpWidget(const MyApp());

    await _scrollTo(tester, find.byKey(const Key('save_NOVA')));
    await tester.tap(find.byKey(const Key('save_NOVA')));
    await tester.pumpAndSettle();
    await _scrollToTop(tester);
    await tester.tap(find.textContaining('Saved (1)'));
    await tester.pumpAndSettle();

    expect(find.textContaining('NOVA'), findsOneWidget);
    expect(find.textContaining('KITE'), findsNothing);
  });

  testWidgets('Ask GPT Why returns a clearly identified mock explanation', (
    tester,
  ) async {
    await tester.pumpWidget(const MyApp());

    await _scrollTo(tester, find.byKey(const Key('why_NOVA')));
    await tester.tap(find.byKey(const Key('why_NOVA')));
    await tester.pumpAndSettle();

    expect(find.text('NOVA: mock explanation'), findsOneWidget);
    expect(find.textContaining('No GPT request was made'), findsOneWidget);
  });

  testWidgets(
    'settings expose risk controls, prompt preview, theme and providers',
    (tester) async {
      await tester.pumpWidget(const MyApp());

      await tester.tap(find.byKey(const Key('settings_button')));
      await tester.pumpAndSettle();

      expect(find.text('Portfolio value (\$)'), findsOneWidget);
      expect(find.text('Allocation available (%)'), findsOneWidget);
      expect(find.text('Holding period (calendar days)'), findsOneWidget);
      expect(find.text('Maximum number of ideas'), findsOneWidget);
      await _scrollSettingsTo(tester, find.text('Dark'));
      expect(find.text('System'), findsOneWidget);
      expect(find.text('Light'), findsOneWidget);
      expect(find.text('Dark'), findsOneWidget);
      await _scrollSettingsTo(tester, find.byKey(const Key('prompt_editor')));
      expect(find.byKey(const Key('prompt_editor')), findsOneWidget);
      await _scrollSettingsTo(tester, find.byKey(const Key('prompt_preview')));
      expect(find.byKey(const Key('prompt_preview')), findsOneWidget);
      await _scrollSettingsTo(tester, find.byKey(const Key('backend_url')));
      expect(
        find.byKey(const Key('check_provider_connections')),
        findsOneWidget,
      );
      await _scrollSettingsTo(tester, find.text('Schwab Trader API'));
      expect(find.text('Schwab Trader API'), findsOneWidget);
      await _scrollSettingsTo(tester, find.text('Alpaca IEX market data'));
      expect(find.text('Alpaca IEX market data'), findsOneWidget);
      await _scrollSettingsTo(tester, find.text('OpenAI'));
      expect(find.text('OpenAI'), findsOneWidget);
      await _scrollSettingsTo(
        tester,
        find.text('Bright Data Social Scraper (X / Reddit)'),
      );
      expect(
        find.text('Bright Data Social Scraper (X / Reddit)'),
        findsOneWidget,
      );
    },
  );

  testWidgets('connection check shows backend-reported provider setup safely', (
    tester,
  ) async {
    final service = ProviderHealthService(
      client: MockClient((request) async {
        expect(request.url.path, '/health');
        expect(request.url.host, '127.0.0.1');
        return httpResponse({
          'status': 'ok',
          'providers': {
            'alpaca': {
              'credentialsPresent': false,
              'enabled': false,
              'integrationImplemented': true,
              'termsConfirmed': false,
            },
            'schwab': {
              'credentialsPresent': true,
              'enabled': false,
              'integrationImplemented': false,
            },
            'alphaVantage': {
              'credentialsPresent': false,
              'enabled': false,
              'integrationImplemented': false,
            },
            'secEdgar': {
              'credentialsPresent': false,
              'enabled': false,
              'integrationImplemented': false,
              'requiresApiKey': false,
            },
            'brightData': {
              'credentialsPresent': false,
              'enabled': false,
              'integrationImplemented': false,
            },
            'openAi': {
              'credentialsPresent': false,
              'enabled': false,
              'integrationImplemented': false,
            },
          },
        });
      }),
    );
    await tester.pumpWidget(MyApp(providerHealthService: service));

    await tester.tap(find.byKey(const Key('settings_button')));
    await tester.pumpAndSettle();
    await _scrollSettingsTo(
      tester,
      find.byKey(const Key('check_provider_connections')),
    );
    await tester.tap(find.byKey(const Key('check_provider_connections')));
    await tester.pumpAndSettle();

    await _scrollSettingsTo(tester, find.text('Schwab Trader API'));
    expect(
      find.textContaining('Credentials detected · Approval / adapter pending'),
      findsOneWidget,
    );
    await _scrollSettingsTo(tester, find.text('Alpaca IEX market data'));
    expect(find.textContaining('Credentials missing'), findsWidgets);
    await _scrollSettingsTo(
      tester,
      find.byKey(const Key('provider_health_success')),
    );
    expect(
      find.textContaining('does not mean a provider connection or entitlement'),
      findsOneWidget,
    );
  });

  testWidgets('theme selection is applied after saving settings', (
    tester,
  ) async {
    await tester.pumpWidget(const MyApp());

    await tester.tap(find.byKey(const Key('settings_button')));
    await tester.pumpAndSettle();
    await _scrollSettingsTo(tester, find.text('Dark'));
    await tester.tap(find.text('Dark'));
    await tester.tap(find.byKey(const Key('save_settings')));
    await tester.pumpAndSettle();

    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.dark,
    );
  });

  testWidgets('editing the prompt updates the assembled mock request preview', (
    tester,
  ) async {
    await tester.pumpWidget(const MyApp());

    await tester.tap(find.byKey(const Key('settings_button')));
    await tester.pumpAndSettle();
    await _scrollSettingsTo(tester, find.byKey(const Key('prompt_editor')));
    await tester.enterText(
      find.byKey(const Key('prompt_editor')),
      'Check downside before upside.',
    );
    await tester.pump();
    await _scrollSettingsTo(tester, find.byKey(const Key('prompt_preview')));

    expect(
      find.descendant(
        of: find.byKey(const Key('prompt_preview')),
        matching: find.textContaining('Check downside before upside.'),
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'history view shows mock outcomes and does not claim verified results',
    (tester) async {
      await tester.pumpWidget(const MyApp());

      await tester.tap(find.text('History'));
      await tester.pumpAndSettle();

      expect(find.text('Historical results'), findsOneWidget);
      expect(
        find.textContaining('not tracked or verified outcomes'),
        findsOneWidget,
      );
      expect(find.textContaining('Unfilled'), findsOneWidget);
    },
  );
}

http.Response httpResponse(Map<String, Object?> body) =>
    http.Response(jsonEncode(body), 200);
