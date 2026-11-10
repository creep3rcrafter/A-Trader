import 'dart:async';

import 'package:a_trade/market_data/daily_candle_chart.dart';
import 'package:a_trade/market_data/live_ideas_view.dart';
import 'package:a_trade/market_data/local_market_data_service.dart';
import 'package:a_trade/market_data/market_data.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'market_data_fixtures.dart';

Widget cards(
  LocalMarketDataService service, {
  String url = 'http://localhost:8765',
  DateTime Function()? clock,
}) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      child: LiveIdeasView(
        backendUrl: url,
        service: service,
        requestClock: clock,
        savedOnly: false,
        savedTickers: const {},
        onToggleSaved: (_) {},
      ),
    ),
  ),
);

List<MarketBar> candles({bool flat = false, bool schwab = false}) {
  final now = DateTime.now().toUtc();
  return List.generate(
    3,
    (index) => MarketBar(
      symbol: 'AAPL',
      provider: schwab ? MarketDataProvider.schwab : MarketDataProvider.alpaca,
      feed: schwab ? MarketDataFeed.schwabEquity : MarketDataFeed.iex,
      timestamp: DateTime.utc(now.year, now.month, now.day - 3 + index),
      retrievedAt: now,
      adjustment: schwab ? PriceAdjustment.unknown : PriceAdjustment.raw,
      open: flat ? 0.0001 : 121,
      high: flat ? 0.0001 : 125,
      low: flat ? 0.0001 : 120,
      close: flat ? 0.0001 : [124.0, 120.0, 121.0][index],
      volume: flat ? 0 : (index + 1) * 1000,
      timestampSemantics: schwab ? 'utcDateProxy' : null,
    ),
  );
}

void main() {
  testWidgets('price wicks and candle bodies map exact OHLC coordinates', (
    tester,
  ) async {
    final bars = candles();
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: CustomPaint(
            key: const Key('exact_plot'),
            size: const Size(400, 290),
            painter: DailyCandlePainter(
              bars: bars,
              selected: 2,
              foreground: Colors.black,
              grid: Colors.grey,
            ),
          ),
        ),
      ),
    );
    final step = (400 - 72) / 3;
    final x = 64 + step / 2;
    double y(double value) => 14 + (125.625 - value) / 6.25 * 180;
    expect(
      find.byKey(const Key('exact_plot')),
      paints
        ..line()
        ..line()
        ..line()
        ..line()
        ..line()
        ..line(
          p1: Offset(x, y(125)),
          p2: Offset(x, y(120)),
          color: const Color(0xFF21894B),
        )
        ..rect(
          rect: Rect.fromCenter(
            center: Offset(x, (y(121) + y(124)) / 2),
            width: 16,
            height: (y(121) - y(124)).abs(),
          ),
          color: const Color(0xFF21894B),
        ),
    );
  });

  testWidgets(
    'collapsed cards automatically finish quote then bounded history in order',
    (tester) async {
      final calls = <String>[];
      final service = LocalMarketDataService(
        client: MockClient((request) async {
          final symbol = request.url.queryParameters['symbol']!;
          final route = request.url.path.split('/').last;
          calls.add('$symbol/$route');
          if (route == 'quote') {
            return fixtureResponse(cardRequestFixture(request));
          }
          expect(request.url.queryParameters['adjustment'], 'raw');
          expect(
            DateTime.parse(
              request.url.queryParameters['end']!,
            ).difference(DateTime.parse(request.url.queryParameters['start']!)),
            const Duration(days: 30),
          );
          return fixtureResponse(cardRequestFixture(request));
        }),
      );
      await tester.pumpWidget(cards(service));
      await tester.pumpAndSettle();
      expect(calls, [
        for (final stock in temporaryStocks) ...[
          '${stock.$1}/quote',
          '${stock.$1}/bars',
        ],
      ]);
      expect(find.byKey(const Key('daily_candle_plot')), findsNWidgets(10));
      expect(find.byKey(const Key('expanded_SOFI')), findsNothing);
      expect(find.textContaining('not a prediction'), findsNWidgets(10));
      expect(find.textContaining('Volume 1000 shares'), findsNWidgets(10));
      expect(find.textContaining('Adjustment: raw'), findsNWidgets(10));
      expect(find.textContaining('Retrieved (UTC)'), findsNWidgets(10));
      await tester.pump(const Duration(seconds: 31));
      expect(calls.length, 20);
      await tester.tap(find.byKey(const Key('refresh_ideas')));
      await tester.pumpAndSettle();
      expect(calls.length, 40);
    },
  );

  testWidgets('expansion never fetches history or opens a modal', (
    tester,
  ) async {
    var historyCalls = 0;
    final service = LocalMarketDataService(
      client: MockClient((request) async {
        final symbol = request.url.queryParameters['symbol']!;
        if (request.url.path.endsWith('/bars')) {
          historyCalls++;
          return fixtureResponse(barsFixture(symbol: symbol));
        }
        expect(request.url.path.endsWith('/quote'), isTrue);
        return fixtureResponse(quoteFixture(symbol: symbol));
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
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
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('expand_SOFI')));
    await tester.pumpAndSettle();
    expect(historyCalls, 10);
    expect(find.byKey(const Key('daily_chart_SOFI')), findsNothing);
    expect(find.text('SOFI daily candles'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
  });

  for (final status in [200, 429, 503]) {
    testWidgets('empty/error history $status never shows synthetic candles', (
      tester,
    ) async {
      final body = status == 200
          ? (barsFixture()
              ..['data'] = []
              ..['count'] = 0)
          : <String, Object?>{'error': 'private credential must not display'};
      final service = LocalMarketDataService(
        client: MockClient(
          (request) async => request.url.path.endsWith('/quote')
              ? fixtureResponse(cardRequestFixture(request))
              : fixtureResponse(body, status),
        ),
      );
      await tester.pumpWidget(cards(service));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('daily_candle_plot')), findsNothing);
      expect(
        find.byKey(
          Key(status == 200 ? 'daily_chart_empty' : 'daily_chart_error'),
        ),
        findsNWidgets(10),
      );
      expect(find.textContaining('private credential'), findsNothing);
    });
  }

  testWidgets('disposal while history loading discards late results', (
    tester,
  ) async {
    final response = Completer<http.Response>();
    final service = LocalMarketDataService(
      client: MockClient(
        (request) async => request.url.path.endsWith('/quote')
            ? fixtureResponse(cardRequestFixture(request))
            : response.future,
      ),
    );
    await tester.pumpWidget(cards(service));
    await tester.pump();
    expect(find.textContaining('Loading daily candles'), findsOneWidget);
    expect(find.textContaining('waiting for earlier cards'), findsNWidgets(9));
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('refresh_ideas')))
          .onPressed,
      isNull,
    );
    await tester.pumpWidget(const SizedBox());
    response.complete(fixtureResponse(barsFixture(symbol: 'SOFI')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  for (final schwab in [false, true]) {
    final seconds = schwab ? 7 : 11;
    final cap = schwab ? 10 : 7;
    testWidgets(
      'quote and history share $seconds-second pacing and $cap/minute budget',
      (tester) async {
        final calls = <(DateTime, String, String)>[];
        final clock = tester.binding.clock.now;
        final service = LocalMarketDataService(
          client: MockClient((request) async {
            calls.add((
              clock(),
              request.url.queryParameters['symbol']!,
              request.url.path.split('/').last,
            ));
            return fixtureResponse(
              cardRequestFixture(request, schwab: schwab, twelve: !schwab),
            );
          }),
        );
        await tester.pumpWidget(cards(service, clock: clock));
        await tester.pump();
        expect(calls.length, 1);
        for (var index = 1; index < 20; index++) {
          await tester.pump(Duration(seconds: seconds - 1));
          expect(calls.length, index);
          await tester.pump(const Duration(seconds: 1));
          await tester.pump();
          expect(calls.length, index + 1);
          if (index == 1) {
            expect(
              find.descendant(
                of: find.byKey(const Key('idea_SOFI')),
                matching: find.byKey(const Key('daily_candle_plot')),
              ),
              findsOneWidget,
            );
            expect(find.byKey(const Key('price_RKLB')), findsNothing);
          }
        }
        expect(calls.map((entry) => '${entry.$2}/${entry.$3}'), [
          for (final stock in temporaryStocks) ...[
            '${stock.$1}/quote',
            '${stock.$1}/bars',
          ],
        ]);
        for (final start in calls) {
          expect(
            calls
                .where(
                  (entry) =>
                      !entry.$1.isBefore(start.$1) &&
                      entry.$1.difference(start.$1) <
                          const Duration(minutes: 1),
                )
                .length,
            lessThanOrEqualTo(cap),
          );
        }
        expect(
          calls.last.$1.difference(calls.first.$1),
          Duration(seconds: 19 * seconds),
        );
        await tester.tap(find.byKey(const Key('refresh_ideas')));
        await tester.pump();
        expect(calls.length, 20);
        await tester.pump(Duration(seconds: seconds - 1));
        expect(calls.length, 20);
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        expect(calls.length, 21);
        // Disposing during the next queued request must cancel its effects.
        await tester.pumpWidget(const SizedBox());
        await tester.pump(Duration(seconds: seconds));
        expect(calls.length, 21);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'backend/service changes invalidate old $seconds-second waits',
      (tester) async {
        var oldCalls = 0;
        final oldService = LocalMarketDataService(
          client: MockClient((request) async {
            oldCalls++;
            return fixtureResponse(
              cardRequestFixture(request, schwab: schwab, twelve: !schwab),
            );
          }),
        );
        var newCalls = 0;
        final newService = LocalMarketDataService(
          client: MockClient((request) async {
            newCalls++;
            expect(request.url.port, 8766);
            return fixtureResponse(cardRequestFixture(request));
          }),
        );
        await tester.pumpWidget(
          cards(oldService, clock: tester.binding.clock.now),
        );
        await tester.pump();
        expect(oldCalls, 1);
        await tester.pumpWidget(
          cards(
            newService,
            url: 'http://localhost:8766',
            clock: tester.binding.clock.now,
          ),
        );
        await tester.pump(Duration(seconds: seconds));
        await tester.pumpAndSettle();
        expect(oldCalls, 1);
        expect(newCalls, 20);
        expect(find.byKey(const Key('daily_candle_plot')), findsNWidgets(10));
      },
    );
  }

  testWidgets(
    'first card completes and renders before next ticker is requested',
    (tester) async {
      final history = Completer<http.Response>();
      final calls = <String>[];
      final service = LocalMarketDataService(
        client: MockClient((request) async {
          final symbol = request.url.queryParameters['symbol']!;
          final route = request.url.path.split('/').last;
          calls.add('$symbol/$route');
          if (symbol == 'SOFI' && route == 'bars') return history.future;
          if (symbol == 'RKLB' && route == 'quote') {
            expect(
              find.descendant(
                of: find.byKey(const Key('idea_SOFI')),
                matching: find.byKey(const Key('daily_candle_plot')),
              ),
              findsOneWidget,
            );
          }
          return fixtureResponse(cardRequestFixture(request));
        }),
      );
      await tester.pumpWidget(cards(service));
      await tester.pump();
      expect(calls, ['SOFI/quote', 'SOFI/bars']);
      expect(find.byKey(const Key('price_SOFI')), findsOneWidget);
      expect(find.byKey(const Key('price_RKLB')), findsNothing);
      history.complete(fixtureResponse(barsFixture(symbol: 'SOFI')));
      await tester.pumpAndSettle();
      expect(calls.length, 20);
      for (final stock in temporaryStocks) {
        final chart = tester.widget<DailyCandleChart>(
          find.descendant(
            of: find.byKey(Key('idea_${stock.$1}')),
            matching: find.byType(DailyCandleChart),
          ),
        );
        expect(chart.bars.single.symbol, stock.$1);
      }
    },
  );

  testWidgets(
    'history 404 keeps quote and continues; terminal history stops the queue',
    (tester) async {
      for (final status in [404, 429, 503]) {
        var calls = 0;
        final service = LocalMarketDataService(
          client: MockClient((request) async {
            calls++;
            if (request.url.queryParameters['symbol'] == 'SOFI' &&
                request.url.path.endsWith('/bars')) {
              return fixtureResponse({
                'error': 'secret backend details',
              }, status);
            }
            return fixtureResponse(cardRequestFixture(request));
          }),
        );
        await tester.pumpWidget(cards(service));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('price_SOFI')), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(const Key('idea_SOFI')),
            matching: find.byKey(const Key('daily_candle_plot')),
          ),
          findsNothing,
        );
        expect(calls, status == 404 ? 20 : 2);
        expect(
          find.byKey(const Key('daily_candle_plot')),
          status == 404 ? findsNWidgets(9) : findsNothing,
        );
        expect(find.textContaining('secret backend'), findsNothing);
        await tester.pumpWidget(const SizedBox());
      }
    },
  );

  testWidgets('backend changes discard stale history response', (tester) async {
    final old = Completer<http.Response>();
    final service = LocalMarketDataService(
      client: MockClient(
        (request) =>
            request.url.port == 8765 && request.url.path.endsWith('/bars')
            ? old.future
            : Future.value(fixtureResponse(cardRequestFixture(request))),
      ),
    );
    await tester.pumpWidget(cards(service));
    await tester.pump();
    await tester.pumpWidget(cards(service, url: 'http://localhost:8766'));
    await tester.pumpAndSettle();
    old.complete(
      fixtureResponse(
        barsFixture(symbol: 'SOFI')
          ..['data'] = []
          ..['count'] = 0,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('SOFI daily candles'), findsOneWidget);
    expect(find.byKey(const Key('daily_candle_plot')), findsNWidgets(10));
    expect(find.byKey(const Key('daily_chart_empty')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final width in [320.0, 1024.0]) {
    for (final brightness in Brightness.values) {
      for (final flat in [false, true]) {
        testWidgets('chart paints $width $brightness flat=$flat and selects', (
          tester,
        ) async {
          tester.view.physicalSize = Size(width, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final semantics = tester.ensureSemantics();
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(brightness: brightness),
              home: Scaffold(
                body: SingleChildScrollView(
                  child: DailyCandleChart(
                    bars: candles(flat: flat, schwab: true),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final slider = tester.widget<Slider>(
            find.byKey(const Key('daily_candle_selector')),
          );
          expect(slider.value, 2);
          expect(
            find.textContaining('Volume ${flat ? 0 : 3000} shares'),
            findsOneWidget,
          );
          final plot = find.byKey(const Key('daily_candle_plot'));
          await tester.tapAt(tester.getTopLeft(plot) + const Offset(76, 80));
          await tester.pump();
          expect(
            find.textContaining('Volume ${flat ? 0 : 1000} shares'),
            findsOneWidget,
          );
          expect(find.textContaining('Adjustment: unknown'), findsOneWidget);
          expect(find.textContaining('UTC date proxy'), findsOneWidget);
          expect(
            find.textContaining('Forecast overlay not implemented'),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
          semantics.dispose();
        });
      }
    }
  }
}
