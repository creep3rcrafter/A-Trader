import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:a_trade/main.dart';
import 'package:a_trade/market_data/local_market_data_service.dart';
import 'package:a_trade/providers/provider_health.dart';

import 'market_data_fixtures.dart';

LocalMarketDataService _marketService() => LocalMarketDataService(
  client: MockClient(
    (request) async => fixtureResponse(cardRequestFixture(request)),
  ),
);

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
  testWidgets(
    'dashboard automatically loads ten real quote cards without mocks',
    (tester) async {
      await tester.pumpWidget(MyApp(marketDataService: _marketService()));
      await tester.pumpAndSettle();

      expect(find.text('A-Trader'), findsOneWidget);
      expect(find.text('Private swing-trading research'), findsNothing);
      expect(
        find.text('MOCK DATA — NOT LIVE MARKET INFORMATION'),
        findsNothing,
      );
      expect(find.text('SOFI'), findsOneWidget);
      expect(find.byType(Card), findsNWidgets(10));
      expect(find.textContaining('MOCK'), findsNothing);
      expect(find.text('Market data'), findsNothing);
      expect(find.text('Ask GPT Why (mock)'), findsNothing);
      expect(
        tester
            .widget<MaterialApp>(find.byType(MaterialApp))
            .theme!
            .scaffoldBackgroundColor,
        const Color(0xFFF5FAFF),
      );
    },
  );

  testWidgets('stock details expand to provider coverage', (tester) async {
    await tester.pumpWidget(MyApp(marketDataService: _marketService()));
    await tester.pumpAndSettle();

    await _scrollTo(tester, find.byKey(const Key('expand_SOFI')));
    await tester.tap(find.byKey(const Key('expand_SOFI')));
    await tester.pumpAndSettle();
    await _scrollTo(tester, find.byKey(const Key('details_SOFI')));
    await tester.tap(find.byKey(const Key('details_SOFI')));
    await tester.pumpAndSettle();

    final details = find.byKey(const Key('details_SOFI'));
    expect(
      find.descendant(
        of: details,
        matching: find.textContaining('IEX is single-exchange'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: details,
        matching: find.textContaining('Retrieved (UTC)'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('ideas can be saved and reviewed in the saved section', (
    tester,
  ) async {
    await tester.pumpWidget(MyApp(marketDataService: _marketService()));
    await tester.pumpAndSettle();

    await _scrollTo(tester, find.byKey(const Key('save_SOFI')));
    await tester.tap(find.byKey(const Key('save_SOFI')));
    await tester.pumpAndSettle();
    await _scrollToTop(tester);
    await tester.tap(find.textContaining('Saved (1)'));
    await tester.pumpAndSettle();

    expect(find.text('SOFI'), findsOneWidget);
    expect(find.text('RKLB'), findsNothing);
  });

  testWidgets(
    'settings expose risk controls, prompt preview, theme and providers',
    (tester) async {
      await tester.pumpWidget(MyApp(marketDataService: _marketService()));

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
      expect(find.byKey(const Key('local_connection_status')), findsOneWidget);
      await _scrollSettingsTo(tester, find.text('Twelve Data market research'));
      expect(find.textContaining('TWELVE_DATA_API_KEY'), findsOneWidget);
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
            'twelveData': {
              'credentialsPresent': true,
              'enabled': true,
              'integrationImplemented': true,
              'termsConfirmed': true,
            },
            'alpaca': {
              'credentialsPresent': false,
              'enabled': false,
              'integrationImplemented': true,
              'termsConfirmed': false,
            },
            'schwab': {
              'credentialsPresent': true,
              'enabled': false,
              'integrationImplemented': true,
              'authorizationStored': true,
              'termsConfirmed': false,
              'selected': false,
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
    await tester.pumpWidget(
      MyApp(
        providerHealthService: service,
        marketDataService: _marketService(),
      ),
    );

    await tester.tap(find.byKey(const Key('settings_button')));
    await tester.pumpAndSettle();
    await _scrollSettingsTo(
      tester,
      find.byKey(const Key('local_connection_status')),
    );
    await tester.pumpAndSettle();

    await _scrollSettingsTo(tester, find.text('Twelve Data market research'));
    expect(
      find.textContaining(
        'Configured for research/testing; provider not tested',
      ),
      findsOneWidget,
    );
    await _scrollSettingsTo(tester, find.text('Schwab Trader API'));
    expect(
      find.textContaining(
        'Private OAuth stored · confirm market-data usage rights',
      ),
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
    await tester.pumpWidget(MyApp(marketDataService: _marketService()));

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

  for (final termsConfirmed in [false, true]) {
    testWidgets(
      'Twelve Data inactive status distinguishes terms ($termsConfirmed)',
      (tester) async {
        final service = ProviderHealthService(
          client: MockClient(
            (_) async => httpResponse({
              'status': 'ok',
              'providers': {
                'twelveData': {
                  'credentialsPresent': true,
                  'enabled': false,
                  'integrationImplemented': true,
                  'termsConfirmed': termsConfirmed,
                },
              },
            }),
          ),
        );
        await tester.pumpWidget(
          MyApp(
            providerHealthService: service,
            marketDataService: _marketService(),
          ),
        );
        await tester.tap(find.byKey(const Key('settings_button')));
        await tester.pumpAndSettle();
        await _scrollSettingsTo(
          tester,
          find.byKey(const Key('local_connection_status')),
        );
        await tester.pumpAndSettle();
        await _scrollSettingsTo(
          tester,
          find.text('Twelve Data market research'),
        );
        expect(
          find.textContaining(
            termsConfirmed
                ? 'not selected as active provider'
                : 'Research terms confirmation required',
          ),
          findsOneWidget,
        );
      },
    );
  }

  testWidgets('editing the prompt updates the draft request preview', (
    tester,
  ) async {
    await tester.pumpWidget(MyApp(marketDataService: _marketService()));

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

  testWidgets('history view is empty without fabricated outcomes', (
    tester,
  ) async {
    await tester.pumpWidget(MyApp(marketDataService: _marketService()));

    await tester.tap(find.text('History'));
    await tester.pumpAndSettle();

    expect(find.textContaining('No historical results yet'), findsOneWidget);
    expect(find.textContaining('hypothetical +4.2%'), findsNothing);
  });
}

http.Response httpResponse(Map<String, Object?> body) =>
    http.Response(jsonEncode(body), 200);
