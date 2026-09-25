import 'support/native_plugins.dart';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/app/dazzle_app.dart';
import 'package:dazzle/application/agents.dart';
import 'package:dazzle/data/database.dart';
import 'package:dazzle/data/repositories/host_repository.dart';
import 'package:dazzle/features/shell/shell_sessions.dart';

import 'support/fake_shell.dart';
import 'support/platform_channels.dart';
import 'support/themed_app.dart';

const _rose = Host(
  id: 'h1',
  name: 'rose',
  address: '100.64.0.1',
  port: 22,
  user: 'luis',
  keyId: 'key-1',
);

const _nyx = Host(
  id: 'h2',
  name: 'nyx',
  address: '100.64.0.2',
  port: 22,
  user: 'luis',
  keyId: 'key-1',
);

void main() {
  late AppDatabase db;
  late ShellSessions sessions;
  late InMemoryHostRepository hosts;

  setUp(() {
    stubDeviceChannels();
    db = AppDatabase(NativeDatabase.memory());
    sessions = fakeShellSessions(FakeShellTransport());
    hosts = InMemoryHostRepository();
  });

  tearDown(() => db.close());

  Widget app() => ProviderScope(
    overrides: [
      ...featureTestOverrides(db),
      hostRepositoryProvider.overrideWithValue(hosts),
      shellSessionsProvider.overrideWithValue(sessions),
    ],
    child: MaterialApp(theme: testTheme, home: DazzleShell()),
  );

  Future<void> ready(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  final bar = find.byKey(const ValueKey('parked-shell'));
  final header = find.byKey(const ValueKey('shell-header'));
  final switcher = find.byKey(const ValueKey('shell-host-switch'));

  Future<void> raise(WidgetTester tester) async {
    await tester.tap(bar);
    await ready(tester);
  }

  testWidgets('one host with shells leaves the name a label', (tester) async {
    await tester.pumpWidget(app());
    await ready(tester);

    sessions.open(_rose);
    await ready(tester);
    await raise(tester);

    expect(header, findsOneWidget);
    expect(find.text('ROSE'), findsOneWidget);
    expect(switcher, findsNothing);

    await unmount(tester);
  });

  testWidgets('a second host makes the name a way to it', (tester) async {
    await tester.pumpWidget(app());
    await ready(tester);

    sessions.open(_rose);
    sessions.open(_nyx);
    await ready(tester);
    await raise(tester);

    expect(find.text('NYX'), findsOneWidget);
    expect(switcher, findsOneWidget);
    expect(
      find.descendant(of: switcher, matching: find.text('ALL SHELLS')),
      findsOneWidget,
    );

    await tester.tap(switcher);
    await ready(tester);

    expect(find.text('SHELLS'), findsOneWidget);
    expect(find.byKey(const ValueKey('shell-switch-h1-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('shell-switch-h2-1')), findsOneWidget);
    expect(find.text('ON SCREEN'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('picking another host swaps the sheet without leaving it', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await ready(tester);

    sessions.open(_rose);
    sessions.open(_nyx);
    await ready(tester);
    await raise(tester);
    final route = ModalRoute.of(tester.element(header));

    await tester.tap(switcher);
    await ready(tester);
    await tester.tap(find.byKey(const ValueKey('shell-switch-h1-1')));
    await ready(tester);

    expect(find.text('ROSE'), findsOneWidget);
    expect(find.text('NYX'), findsNothing);
    expect(ModalRoute.of(tester.element(header)), same(route));
    await tester.drag(header, const Offset(0, 400));
    await ready(tester);
    expect(header, findsNothing);
    expect(bar, findsOneWidget);

    await unmount(tester);
  });

  testWidgets('picking a tab on the host in front activates it', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await ready(tester);

    sessions.open(_rose);
    sessions.open(_nyx);
    sessions.open(_nyx);
    await ready(tester);
    await raise(tester);
    expect(find.byKey(const ValueKey('shell-tab-2')), findsOneWidget);

    await tester.tap(switcher);
    await ready(tester);
    await tester.tap(find.byKey(const ValueKey('shell-switch-h2-1')));
    await ready(tester);

    expect(find.text('NYX'), findsOneWidget);
    expect(sessions.activeFor(_nyx.id)!.number, 1);

    await unmount(tester);
  });

  testWidgets('the plus menu opens a fresh shell on the selected host', (
    tester,
  ) async {
    await hosts.save(_rose);
    await hosts.save(_nyx);
    await tester.pumpWidget(app());
    await ready(tester);

    sessions.open(_nyx);
    sessions.open(_rose);
    await ready(tester);
    await raise(tester);
    final route = ModalRoute.of(tester.element(header));

    await tester.tap(find.byKey(const ValueKey('shell-tab-new')));
    await ready(tester);

    expect(find.byKey(const ValueKey('shell-new-host-h1')), findsOneWidget);
    expect(find.byKey(const ValueKey('shell-new-host-h2')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('shell-new-host-h2')));
    await ready(tester);

    expect(sessions.forHost(_nyx.id), hasLength(2));
    expect(sessions.activeFor(_nyx.id)!.number, 2);
    expect(find.text('NYX'), findsOneWidget);
    expect(ModalRoute.of(tester.element(header)), same(route));

    await unmount(tester);
  });

  group('a host with no shell yet', () {
    testWidgets('a second host on the list makes the name a cell and is '
        'offered under TAKE OVER', (tester) async {
      await hosts.save(_rose);
      await hosts.save(_nyx);
      await tester.pumpWidget(app());
      await ready(tester);

      sessions.open(_rose);
      await ready(tester);
      await raise(tester);

      expect(switcher, findsOneWidget);
      await tester.tap(switcher);
      await ready(tester);

      expect(find.text('TAKE OVER'), findsOneWidget);
      expect(find.byKey(const ValueKey('shell-take-h2')), findsOneWidget);
      expect(find.byKey(const ValueKey('shell-switch-h1-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('shell-take-h1')), findsNothing);

      await unmount(tester);
    });

    testWidgets('taking one over opens its shell in the same sheet', (
      tester,
    ) async {
      await hosts.save(_rose);
      await hosts.save(_nyx);
      await tester.pumpWidget(app());
      await ready(tester);

      sessions.open(_rose);
      await ready(tester);
      await raise(tester);
      final route = ModalRoute.of(tester.element(header));

      await tester.tap(switcher);
      await ready(tester);
      await tester.tap(find.byKey(const ValueKey('shell-take-h2')));
      await ready(tester);

      expect(sessions.forHost(_nyx.id), hasLength(1));
      expect(find.text('NYX'), findsOneWidget);
      expect(ModalRoute.of(tester.element(header)), same(route));

      await tester.drag(header, const Offset(0, 400));
      await ready(tester);
      expect(header, findsNothing);
      expect(bar, findsOneWidget);

      await unmount(tester);
    });

    testWidgets('one host and nothing else leaves the name a label', (
      tester,
    ) async {
      await hosts.save(_rose);
      await tester.pumpWidget(app());
      await ready(tester);

      sessions.open(_rose);
      await ready(tester);
      await raise(tester);

      expect(switcher, findsNothing);

      await unmount(tester);
    });
  });

  testWidgets('the host the sheet switched to is the one the bar names', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await ready(tester);

    sessions.open(_rose);
    sessions.open(_nyx);
    await ready(tester);
    await raise(tester);
    await tester.tap(switcher);
    await ready(tester);
    await tester.tap(find.byKey(const ValueKey('shell-switch-h1-1')));
    await ready(tester);
    await tester.drag(header, const Offset(0, 400));
    await ready(tester);

    expect(find.text('ROSE 1'), findsOneWidget);
    expect(find.text('+1'), findsOneWidget);

    await unmount(tester);
  });
}
