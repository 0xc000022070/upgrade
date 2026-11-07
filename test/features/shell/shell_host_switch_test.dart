import '../../support/native_plugins.dart';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/app/upgrade_app.dart';
import 'package:upgrade/application/agents/agents.dart';
import 'package:upgrade/data/database.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/features/shell/session/shell_sessions.dart';
import 'package:upgrade/features/shell/sheets/shell_sheet.dart';
import 'package:upgrade/application/providers.dart';

import '../../support/fake_shell.dart';
import '../../support/launch_scan.dart';
import '../../support/platform_channels.dart';
import '../../support/reasons.dart';
import '../../support/themed_app.dart';

const _pine = Host(
  id: 'h1',
  name: 'pine',
  address: '100.64.0.1',
  port: 22,
  user: 'alex',
  keyId: 'key-1',
);

const _oak = Host(
  id: 'h2',
  name: 'oak',
  address: '100.64.0.2',
  port: 22,
  user: 'alex',
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
    retry: noRetry,
    overrides: [
      ...featureTestOverrides(db),
      hostRepositoryProvider.overrideWithValue(hosts),
      shellSessionsProvider.overrideWithValue(sessions),
      noLaunchTargets,
    ],
    child: MaterialApp(theme: testTheme, home: UpgradeShell()),
  );

  Future<void> ready(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
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
  Finder tab(Host host, int number) =>
      find.byKey(ValueKey('shell-tab-${host.id}-$number'));
  Finder label(Host host) =>
      find.byKey(ValueKey('shell-group-label-${host.id}'));

  Future<void> raise(WidgetTester tester) async {
    await tester.tap(bar);
    await ready(tester);
  }

  Future<void> carry(WidgetTester tester, Finder what, Offset by) async {
    final gesture = await tester.startGesture(tester.getCenter(what));
    await tester.pump(const Duration(milliseconds: 600));
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(by / 10);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await ready(tester);
  }

  testWidgets('every host with a shell has a group, in the order opened', (
    tester,
  ) async {
    await hosts.save(_pine);
    await hosts.save(_oak);
    await tester.pumpWidget(app());
    await ready(tester);

    sessions.open(intent: testIntent(), _pine);
    sessions.open(intent: testIntent(), _oak);
    await ready(tester);
    await raise(tester);

    expect(header, findsOneWidget);
    expect(find.byKey(const ValueKey('shell-host-switch')), findsNothing);
    expect(label(_pine), findsOneWidget);
    expect(label(_oak), findsOneWidget);
    expect(tab(_pine, 1), findsOneWidget);
    expect(tab(_oak, 1), findsOneWidget);
    expect(
      tester.getCenter(tab(_pine, 1)).dx,
      lessThan(tester.getCenter(label(_oak)).dx),
    );
    expect(tester.takeException(), isNull);

    await unmount(tester);
  });

  testWidgets('a host with no shell has no group', (tester) async {
    await hosts.save(_pine);
    await hosts.save(_oak);
    await tester.pumpWidget(app());
    await ready(tester);

    sessions.open(intent: testIntent(), _pine);
    await ready(tester);
    await raise(tester);

    expect(label(_pine), findsOneWidget);
    expect(label(_oak), findsNothing);

    await unmount(tester);
  });

  testWidgets('a long host name stays within its label at phone width', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const named = Host(
      id: 'long',
      name: 'UPGRADE DEVELOPMENT HOST',
      address: '100.64.0.3',
      port: 22,
      user: 'dev',
      keyId: 'key-1',
    );
    await tester.pumpWidget(app());
    await ready(tester);
    sessions.open(intent: testIntent(), _pine);
    sessions.open(intent: testIntent(), named);
    await ready(tester);
    await raise(tester);

    expect(tester.getSize(label(named)).width, lessThanOrEqualTo(100));
    expect(tester.takeException(), isNull);

    await unmount(tester);
  });

  testWidgets('a tab on another host swaps the sheet without leaving it', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await ready(tester);

    sessions.open(intent: testIntent(), _pine);
    sessions.open(intent: testIntent(), _oak);
    await ready(tester);
    await raise(tester);
    final route = ModalRoute.of(tester.element(header));

    await tester.tap(tab(_pine, 1));
    await ready(tester);

    expect(ModalRoute.of(tester.element(header)), same(route));
    expect(sessions.parked!.host.id, _pine.id);
    await tester.drag(header, const Offset(0, 400));
    await ready(tester);
    expect(header, findsNothing);
    expect(
      find.byKey(ValueKey('parked-shell-host-${_pine.id}')),
      findsOneWidget,
    );

    await unmount(tester);
  });

  testWidgets('a tab on the host in front activates it', (tester) async {
    await tester.pumpWidget(app());
    await ready(tester);

    sessions.open(intent: testIntent(), _pine);
    sessions.open(intent: testIntent(), _oak);
    sessions.open(intent: testIntent(), _oak);
    await ready(tester);
    await raise(tester);
    expect(sessions.activeFor(_oak.id)!.number, 2);

    await tester.tap(tab(_oak, 1));
    await ready(tester);

    expect(sessions.activeFor(_oak.id)!.number, 1);

    await unmount(tester);
  });

  testWidgets('a label folds its group and a second tap unfolds it', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await ready(tester);

    sessions.open(intent: testIntent(), _pine);
    sessions.open(intent: testIntent(), _pine);
    sessions.open(intent: testIntent(), _oak);
    sessions.open(intent: testIntent(), _oak);
    await ready(tester);
    await raise(tester);

    await tester.tap(label(_pine));
    await ready(tester);
    expect(tab(_pine, 1), findsNothing);
    expect(tab(_pine, 2), findsNothing);
    expect(
      find.descendant(of: label(_pine), matching: find.text('+2')),
      findsOneWidget,
    );

    await tester.tap(label(_oak));
    await ready(tester);
    expect(tab(_oak, 1), findsNothing);
    expect(tab(_oak, 2), findsOneWidget, reason: 'the tab on screen stays');
    expect(
      find.descendant(of: label(_oak), matching: find.text('+1')),
      findsOneWidget,
    );

    await tester.tap(label(_pine));
    await ready(tester);
    expect(tab(_pine, 1), findsOneWidget);
    expect(tab(_pine, 2), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('a group that goes with its last tab forgets its fold', (
    tester,
  ) async {
    final pine = sessions.open(intent: testIntent(), _pine)!;
    sessions.fold(_pine.id, folded: true);
    await sessions.close(intent: testIntent(), _pine.id, pine);
    expect(sessions.isFolded(_pine.id), isFalse);
    expect(sessions.openHosts, isEmpty);
  });

  testWidgets('a long press carries a tab within its group', (tester) async {
    await tester.pumpWidget(app());
    await ready(tester);

    sessions.open(intent: testIntent(), _oak);
    sessions.open(intent: testIntent(), _oak);
    sessions.open(intent: testIntent(), _oak);
    await ready(tester);
    await raise(tester);

    final step =
        tester.getTopRight(tab(_oak, 3)) - tester.getTopLeft(tab(_oak, 1));
    await carry(tester, tab(_oak, 1), step + const Offset(20, 0));

    expect([for (final s in sessions.forHost(_oak.id)) s.number], [2, 3, 1]);

    await unmount(tester);
  });

  testWidgets('a long press on a label carries the whole group', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await ready(tester);

    sessions.open(intent: testIntent(), _pine);
    sessions.open(intent: testIntent(), _oak);
    sessions.open(intent: testIntent(), _oak);
    await ready(tester);
    await raise(tester);

    final step =
        tester.getTopRight(find.byKey(const ValueKey('shell-group-h2'))) -
        tester.getTopLeft(find.byKey(const ValueKey('shell-group-h1')));
    await carry(tester, label(_pine), step + const Offset(20, 0));

    expect(
      [for (final (host, _) in sessions.openHosts) host.id],
      [_oak.id, _pine.id],
    );
    expect([for (final s in sessions.forHost(_oak.id)) s.number], [1, 2]);

    await unmount(tester);
  });

  testWidgets('the plus menu opens a fresh shell on the selected host', (
    tester,
  ) async {
    await hosts.save(_pine);
    await hosts.save(_oak);
    await tester.pumpWidget(app());
    await ready(tester);

    sessions.open(intent: testIntent(), _oak);
    sessions.open(intent: testIntent(), _pine);
    await ready(tester);
    await raise(tester);
    final route = ModalRoute.of(tester.element(header));

    await tester.tap(find.byKey(const ValueKey('shell-tab-new')));
    await ready(tester);

    expect(find.byKey(const ValueKey('shell-new-host-h1')), findsOneWidget);
    expect(find.byKey(const ValueKey('shell-new-host-h2')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('shell-new-host-h2')));
    await ready(tester);
    expect(find.text('NEW SHELL ON OAK'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('launch-advanced')));
    await ready(tester);
    await tester.tap(find.byKey(const ValueKey('launch-connection-dedicated')));
    await tester.tap(find.byKey(const ValueKey('launch-advanced-back')));
    await ready(tester);
    await tester.tap(find.byKey(const ValueKey('launch-shell')));
    await ready(tester);

    expect(sessions.forHost(_oak.id), hasLength(2));
    expect(sessions.activeFor(_oak.id)!.number, 2);
    expect(sessions.activeFor(_oak.id)!.ownConnection, isTrue);
    expect(tab(_oak, 2), findsOneWidget);
    expect(ModalRoute.of(tester.element(header)), same(route));

    await unmount(tester);
  });

  testWidgets('a first shell from the plus menu starts its host\'s group', (
    tester,
  ) async {
    await hosts.save(_pine);
    await hosts.save(_oak);
    await tester.pumpWidget(app());
    await ready(tester);

    sessions.open(intent: testIntent(), _pine);
    await ready(tester);
    await raise(tester);
    final route = ModalRoute.of(tester.element(header));

    await tester.tap(find.byKey(const ValueKey('shell-tab-new')));
    await ready(tester);
    await tester.tap(find.byKey(const ValueKey('shell-new-host-h2')));
    await ready(tester);
    await tester.tap(find.byKey(const ValueKey('launch-shell')));
    await ready(tester);

    expect(sessions.forHost(_oak.id), hasLength(1));
    expect(label(_oak), findsOneWidget);
    expect(
      tester.getCenter(label(_pine)).dx,
      lessThan(tester.getCenter(label(_oak)).dx),
    );
    expect(ModalRoute.of(tester.element(header)), same(route));

    await unmount(tester);
  });

  testWidgets('back with the plus menu open closes the menu, not the shells', (
    tester,
  ) async {
    await hosts.save(_pine);
    await hosts.save(_oak);
    await tester.pumpWidget(app());
    await ready(tester);

    sessions.open(intent: testIntent(), _pine);
    await ready(tester);
    await raise(tester);
    final route = ModalRoute.of(tester.element(header));

    await tester.tap(find.byKey(const ValueKey('shell-tab-new')));
    await ready(tester);
    expect(find.byKey(const ValueKey('shell-new-host-h2')), findsOneWidget);

    await tester.binding.handlePopRoute();
    await ready(tester);

    expect(find.byKey(const ValueKey('shell-new-host-h2')), findsNothing);
    expect(ModalRoute.of(tester.element(header)), same(route));

    await tester.binding.handlePopRoute();
    await ready(tester);

    expect(header, findsNothing);

    await unmount(tester);
  });

  testWidgets('a host at the tab limit is left out of the plus menu', (
    tester,
  ) async {
    await hosts.save(_pine);
    await hosts.save(_oak);
    await tester.pumpWidget(app());
    await ready(tester);

    for (var i = 0; i < maxShellSessions; i++) {
      sessions.open(intent: testIntent(), _oak);
    }
    sessions.open(intent: testIntent(), _pine);
    await ready(tester);
    await raise(tester);

    await tester.tap(find.byKey(const ValueKey('shell-tab-new')));
    await ready(tester);

    expect(find.byKey(const ValueKey('shell-new-host-h1')), findsOneWidget);
    expect(find.byKey(const ValueKey('shell-new-host-h2')), findsNothing);

    await unmount(tester);
  });

  testWidgets('a command for a host at the tab limit says so and stays put', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await ready(tester);

    for (var i = 0; i < maxShellSessions; i++) {
      sessions.open(intent: testIntent(), _oak);
    }
    await ready(tester);

    openHostShell(
      tester.element(find.byType(UpgradeShell)),
      _oak,
      intent: testIntent(),
      command: 'cd /srv',
    );
    await ready(tester);

    expect(header, findsNothing);
    expect(sessions.forHost(_oak.id), hasLength(maxShellSessions));
    expect(find.text('TAB LIMIT'), findsOneWidget);
    expect(find.text('oak'), findsOneWidget);

    await unmount(tester);
  });
}
