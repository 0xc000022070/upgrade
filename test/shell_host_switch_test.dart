import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spectacle/app/spectacle_app.dart';
import 'package:spectacle/application/agents.dart';
import 'package:spectacle/application/providers.dart';
import 'package:spectacle/data/database.dart';
import 'package:spectacle/data/repositories/host_repository.dart';
import 'package:spectacle/features/shell/shell_sessions.dart';

import 'support/fake_shell.dart';
import 'support/platform_channels.dart';

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
      databaseProvider.overrideWithValue(db),
      hostRepositoryProvider.overrideWithValue(hosts),
      shellSessionsProvider.overrideWithValue(sessions),
    ],
    child: const MaterialApp(home: SpectacleShell()),
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

  /// The sheet up on whichever host the bar names.
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

    // The bar parked on the last host opened, so the sheet is on NYX.
    expect(find.text('NYX'), findsOneWidget);
    expect(switcher, findsOneWidget);

    await tester.tap(switcher);
    await ready(tester);

    // Every shell on every host, whichever one the sheet is holding.
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
    // The same sheet, handed another host: a second route would have stacked
    // one shell over the other.
    expect(ModalRoute.of(tester.element(header)), same(route));
    // And it is still the sheet, so the way out is the way it was.
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
      // The host already running is a session row, not an offer.
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
