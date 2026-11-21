import 'dart:ui' show PointerDeviceKind;

import 'package:atrader/copyable_text.dart';
import 'package:atrader/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  String? copied;
  setUp(() {
    copied = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets(
    'the application selects ordinary labels and includes dialog routes',
    (tester) async {
      await tester.pumpWidget(const MyApp());
      await tester.pump();
      final area = find.byType(SelectionArea).first;
      expect(
        find.ancestor(of: area, matching: find.byType(Navigator)),
        findsWidgets,
      );
      final selection = tester.state<SelectionAreaState>(area).selectableRegion;
      selection.selectAll(SelectionChangedCause.keyboard);
      await tester.pump();
      Actions.invoke(
        tester.element(find.text('Live dashboard')),
        CopySelectionTextIntent.copy,
      );
      await tester.pump();
      expect(copied, contains('A-Trader'));
      expect(copied, contains('Live dashboard'));
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsDialog), findsOneWidget);
      expect(
        find.ancestor(
          of: find.byType(SettingsDialog),
          matching: find.byType(SelectionArea),
        ),
        findsWidgets,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('copy error preserves the complete multiline message', (
    tester,
  ) async {
    const message =
        'Research cycle failed\nPathAccessException: C:\\example\\progress.json\nGeneration 96 → 100';
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: CopyableError(message))),
    );
    expect(find.byType(SelectableText), findsOneWidget);
    await tester.tap(find.byTooltip('Copy error'));
    await tester.pumpAndSettle();
    expect(copied, message);
    expect(find.text('Copied to clipboard.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'selecting Win rate with setup scrolled away keeps the dashboard responsive',
    (tester) async {
      final controller = DashboardController()
        ..status = {'runId': 'one', 'workspaceMode': true, 'workspaceId': 'one'}
        ..snapshot = {
          'accounts': [
            {
              'label': 'Alpha',
              'startingCash': 10000.0,
              'equity': 10500.0,
              'closedPnl': [25, -5],
            },
          ],
        };
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SelectionArea(child: DashboardView(controller: controller)),
          ),
        ),
      );
      await tester.tap(find.text('Simulation controls'));
      await tester.pumpAndSettle();
      expect(find.byType(RunSetupView), findsOneWidget);
      final winRate = find.text('Win rate');
      await tester.scrollUntilVisible(
        winRate,
        420,
        scrollable: find.byType(Scrollable).first,
      );
      await Scrollable.ensureVisible(tester.element(winRate), alignment: .5);
      await tester.pumpAndSettle();

      final value = find.text('50.0% (1/2)');
      await Scrollable.ensureVisible(tester.element(value), alignment: .5);
      await tester.pumpAndSettle();
      final bounds = tester.getRect(value);
      final mouse = await tester.startGesture(
        Offset(bounds.left + 1, bounds.center.dy),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump(const Duration(milliseconds: 500));
      await mouse.moveBy(const Offset(4, 0));
      await mouse.moveBy(const Offset(12, 0));
      await mouse.moveTo(Offset(bounds.right - 1, bounds.center.dy));
      await mouse.up();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      tester
          .state<SelectionAreaState>(find.byType(SelectionArea))
          .selectableRegion
          .selectAll(SelectionChangedCause.keyboard);
      await tester.pump();
      Actions.invoke(tester.element(value), CopySelectionTextIntent.copy);
      await tester.pump();
      expect(copied, contains('50.0%'));
    },
  );

  testWidgets('a failed training run can copy its entire error', (
    tester,
  ) async {
    const message =
        'Research cycle failed: Windows blocked progress file replacement.';
    final controller = DashboardController()
      ..status = {
        'research': {
          'phase': 'error',
          'message': message,
          'cycles': 96,
          'evolutionLimit': 100,
        },
      };
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DashboardView(controller: controller)),
      ),
    );
    await tester.ensureVisible(find.byTooltip('Copy error'));
    await tester.tap(find.byTooltip('Copy error'));
    await tester.pumpAndSettle();
    expect(copied, message);
    expect(tester.takeException(), isNull);
  });

  testWidgets('error snackbars offer a copy action', (tester) async {
    const message = 'Could not export run data: permission denied.';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => ScaffoldMessenger.of(
                context,
              ).showSnackBar(copyableErrorSnackBar(context, message)),
              child: const Text('Show error'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Show error'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy error'));
    await tester.pumpAndSettle();
    expect(copied, message);
    expect(tester.takeException(), isNull);
  });
}
