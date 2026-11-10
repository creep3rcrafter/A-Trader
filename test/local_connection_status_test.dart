import 'dart:async';

import 'package:a_trade/main.dart';
import 'package:a_trade/providers/backend_process.dart';
import 'package:a_trade/providers/provider_health.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Health extends ProviderHealthService {
  int calls = 0;
  final List<Uri> urls = [];
  Future<ProviderHealthSnapshot> Function()? response;

  @override
  Future<ProviderHealthSnapshot> check(Uri uri) {
    calls++;
    urls.add(uri);
    return response?.call() ??
        Future.value(const ProviderHealthSnapshot(status: 'ok', providers: {}));
  }
}

class _Backend implements BackendProcessController {
  _Backend({this.available = true});
  @override
  final bool available;
  @override
  bool ownsBackend = false;
  int starts = 0;
  int stops = 0;
  String? failure;
  void Function()? onStart;

  @override
  Future<void> start(Uri uri) async {
    starts++;
    if (failure != null) throw BackendProcessException(failure!);
    ownsBackend = true;
    onStart?.call();
  }

  @override
  Future<void> stop() async {
    if (ownsBackend) {
      stops++;
      ownsBackend = false;
    }
  }

  @override
  void dispose() {}
}

Future<void> _open(
  WidgetTester tester,
  _Health health, {
  _Backend? backend,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: SettingsScreen(
        initialSettings: const AppSettings(),
        initialThemeMode: ThemeMode.system,
        onSave: (_, _) {},
        providerHealthService: health,
        backendProcessController: backend,
      ),
    ),
  );
  await tester.scrollUntilVisible(
    find.byKey(const Key('local_connection_status')),
    400,
    scrollable: find.byType(Scrollable).first,
  );
}

Icon _icon(WidgetTester tester) =>
    tester.widget<Icon>(find.byKey(const Key('local_connection_icon')));

void main() {
  testWidgets('automatic neutral, green, red and recovery every 30 seconds', (
    tester,
  ) async {
    final pending = Completer<ProviderHealthSnapshot>();
    final health = _Health()..response = () => pending.future;
    await _open(tester, health);
    expect(health.calls, 1);
    expect(_icon(tester).icon, Icons.pending);
    expect(_icon(tester).color, isNot(Colors.red));
    expect(find.byKey(const Key('check_provider_connections')), findsNothing);
    pending.complete(const ProviderHealthSnapshot(status: 'ok', providers: {}));
    await tester.pump();
    expect(_icon(tester).icon, Icons.check_circle);
    expect(_icon(tester).color, Colors.green);
    health.response = () async =>
        throw const ProviderHealthException('Offline');
    await tester.pump(const Duration(seconds: 29));
    expect(health.calls, 1);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(health.calls, 2);
    expect(_icon(tester).icon, Icons.cancel);
    expect(_icon(tester).color, Colors.red);
    health.response = null;
    await tester.pump(const Duration(seconds: 30));
    await tester.pump();
    expect(health.calls, 3);
    expect(_icon(tester).icon, Icons.check_circle);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
    expect(health.calls, 3);
    health.close();
  });

  testWidgets('no overlapping checks; URL edits discard old results', (
    tester,
  ) async {
    final pending = Completer<ProviderHealthSnapshot>();
    final health = _Health()..response = () => pending.future;
    await _open(tester, health);
    await tester.pump(const Duration(seconds: 60));
    expect(health.calls, 1);
    await tester.scrollUntilVisible(
      find.byKey(const Key('backend_url')),
      -200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(
      find.byKey(const Key('backend_url')),
      'http://localhost:8765',
    );
    health.response = () async =>
        throw const ProviderHealthException('New URL');
    pending.complete(const ProviderHealthSnapshot(status: 'ok', providers: {}));
    await tester.pump();
    await tester.pump();
    expect(health.calls, 2);
    expect(health.urls.last.host, 'localhost');
    await tester.scrollUntilVisible(
      find.byKey(const Key('local_connection_status')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(_icon(tester).icon, Icons.cancel);
    expect(find.text('New URL'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    health.close();
  });

  testWidgets('disposing pending health ignores completion', (tester) async {
    final pending = Completer<ProviderHealthSnapshot>();
    final health = _Health()..response = () => pending.future;
    await _open(tester, health);
    await tester.pumpWidget(const SizedBox());
    pending.complete(const ProviderHealthSnapshot(status: 'ok', providers: {}));
    await tester.pump(const Duration(seconds: 30));
    expect(health.calls, 1);
    expect(tester.takeException(), isNull);
    health.close();
  });

  testWidgets('unavailable platforms never render process controls', (
    tester,
  ) async {
    final health = _Health();
    await _open(tester, health, backend: _Backend(available: false));
    await tester.pump();
    expect(find.byKey(const Key('start_backend')), findsNothing);
    expect(find.byKey(const Key('stop_backend')), findsNothing);
    expect(_icon(tester).icon, Icons.check_circle);
    await tester.pumpWidget(const SizedBox());
    health.close();
  });

  testWidgets('external backend is observed but cannot be stopped', (
    tester,
  ) async {
    final health = _Health();
    final backend = _Backend();
    await _open(tester, health, backend: backend);
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('start_backend')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('stop_backend')))
          .onPressed,
      isNull,
    );
    expect(backend.starts, 0);
    expect(backend.stops, 0);
    await tester.pumpWidget(const SizedBox());
    health.close();
  });

  testWidgets('start rechecks health and stop only controls owned backend', (
    tester,
  ) async {
    final health = _Health()
      ..response = () async => throw const ProviderHealthException('Offline');
    final backend = _Backend()..onStart = () => health.response = null;
    await _open(tester, health, backend: backend);
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('start_backend')));
    await tester.tap(find.byKey(const Key('start_backend')));
    await tester.pump();
    expect(backend.starts, 1);
    expect(health.calls, 2);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    await tester.scrollUntilVisible(
      find.byKey(const Key('local_connection_status')),
      -100,
      scrollable: find.byType(Scrollable).first,
    );
    expect(_icon(tester).icon, Icons.check_circle);
    health.response = () async =>
        throw const ProviderHealthException('Offline');
    await tester.ensureVisible(find.byKey(const Key('stop_backend')));
    await tester.tap(find.byKey(const Key('stop_backend')));
    await tester.pump();
    await tester.pump();
    expect(backend.stops, 1);
    await tester.scrollUntilVisible(
      find.byKey(const Key('local_connection_status')),
      -100,
      scrollable: find.byType(Scrollable).first,
    );
    expect(_icon(tester).icon, Icons.cancel);
    await tester.pumpWidget(const SizedBox());
    health.close();
  });

  testWidgets('start refuses a backend that appears during preflight', (
    tester,
  ) async {
    final health = _Health()
      ..response = () async => throw const ProviderHealthException('Offline');
    final backend = _Backend();
    await _open(tester, health, backend: backend);
    await tester.pump();
    health.response = null;
    await tester.ensureVisible(find.byKey(const Key('start_backend')));
    await tester.tap(find.byKey(const Key('start_backend')));
    await tester.pump();
    expect(backend.starts, 0);
    expect(find.textContaining('Existing backend detected'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    health.close();
  });

  testWidgets('safe launch errors appear without changing ownership', (
    tester,
  ) async {
    final health = _Health()
      ..response = () async => throw const ProviderHealthException('Offline');
    final backend = _Backend()..failure = 'Source checkout required';
    await _open(tester, health, backend: backend);
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('start_backend')));
    await tester.tap(find.byKey(const Key('start_backend')));
    await tester.pump();
    expect(find.text('Source checkout required'), findsOneWidget);
    expect(backend.ownsBackend, false);
    expect(backend.stops, 0);
    await tester.pumpWidget(const SizedBox());
    health.close();
  });
}
