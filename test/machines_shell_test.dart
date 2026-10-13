import 'support/launch_scan.dart';
import 'support/native_plugins.dart';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/application/agents/agents.dart';
import 'package:upgrade/data/database.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/data/repositories/key_repository.dart';
import 'package:upgrade/design/colors.dart';
import 'package:upgrade/features/devices/device_dock.dart';
import 'package:upgrade/features/shell/session/shell_sessions.dart';
import 'package:upgrade/features/hosts/hosts_screen.dart';

import 'support/fake_shell.dart';
import 'support/platform_channels.dart';
import 'support/reasons.dart';
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
  port: 357,
  user: 'luis',
  keyId: 'key-1',
);

void main() {
  late AppDatabase db;
  late InMemoryKeyRepository keys;
  late InMemoryHostRepository hosts;
  late FakeShellTransport shells;
  late ShellSessions sessions;

  setUp(() {
    stubDeviceChannels();
    db = AppDatabase(NativeDatabase.memory());
    keys = InMemoryKeyRepository();
    hosts = InMemoryHostRepository();
    shells = FakeShellTransport()..stall = true;
    sessions = fakeShellSessions(shells);
  });

  tearDown(() => db.close());

  Widget app({
    double textScale = 1,
    List<Host> desktops = const [],
    List<Host> devices = const [],
  }) => ProviderScope(
    overrides: [
      vncHostsProvider.overrideWith((ref) => Stream.value(desktops)),
      deviceHostsProvider.overrideWith((ref) => Stream.value(devices)),
      ...featureTestOverrides(db),
      keyRepositoryProvider.overrideWithValue(keys),
      hostRepositoryProvider.overrideWithValue(hosts),
      shellSessionsProvider.overrideWithValue(sessions),
      noLaunchTargets,
    ],
    child: MaterialApp(
      theme: testTheme,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: const HostsScreen(),
    ),
  );

  /// The grain runs off a ticker that never settles, so a test that ends with the tree
  /// mounted leaves a pending timer and hangs the file.
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  Future<void> ready(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
    }
    // Panel headers decode into their labels over a few frames.
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> seed() async {
    await hosts.save(_rose);
    await hosts.save(_nyx);
  }

  void sized(WidgetTester tester) {
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets('every host is a card saying where it is', (tester) async {
    sized(tester);
    await seed();
    await tester.pumpWidget(app());
    await ready(tester);

    expect(find.text('ROSE'), findsOneWidget);
    expect(find.text('NYX'), findsOneWidget);
    expect(find.text('100.64.0.1:22'), findsOneWidget);
    expect(find.text('100.64.0.2:357'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('no session means no panel of sessions', (tester) async {
    sized(tester);
    await seed();
    await tester.pumpWidget(app());
    await ready(tester);

    expect(find.text('ACTIVE SESSIONS'), findsNothing);
    expect(find.text('HOSTS'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('every open session is a card, in the order of the hosts', (
    tester,
  ) async {
    sized(tester);
    await seed();
    shells.stall = false;
    sessions.open(intent: testIntent(), _rose);
    sessions.open(intent: testIntent(), _nyx);
    sessions.open(intent: testIntent(), _nyx);
    await tester.pumpWidget(app());
    await ready(tester);

    expect(find.text('ACTIVE SESSIONS'), findsOneWidget);
    expect(find.byKey(const ValueKey('shell-card-h1-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('shell-card-h2-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('shell-card-h2-2')), findsOneWidget);
    expect(find.text('rose · shell 1'), findsOneWidget);
    expect(find.text('nyx · shell 2'), findsOneWidget);
    expect(find.text('SHELL · 1 OPEN'), findsOneWidget);
    expect(find.text('SHELL · 2 OPEN'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('the card carries the state of the session under it', (
    tester,
  ) async {
    sized(tester);
    await seed();
    shells.stall = false;
    sessions.open(intent: testIntent(), _rose);
    await tester.pumpWidget(app());
    await ready(tester);

    Color dot() =>
        (tester
                    .widget<Container>(
                      find.descendant(
                        of: find.byKey(const ValueKey('shell-dot-h1-1')),
                        matching: find.byType(Container),
                      ),
                    )
                    .decoration
                as BoxDecoration)
            .color!;

    expect(dot(), UpgradeColors.accent);

    shells.opened.single.exit(1);
    await ready(tester);
    expect(dot(), UpgradeColors.textMuted);

    await unmount(tester);
  });

  testWidgets(
    'session cards prefer task titles and fall back to their directory',
    (tester) async {
      sized(tester);
      await seed();
      shells.stall = false;
      final first = sessions.open(intent: testIntent(), _rose)!;
      first.title = 'Fix reconnect';
      final second = sessions.open(intent: testIntent(), _nyx)!;
      second.cwd = '/home/dev/Projects/upgrade';
      await tester.pumpWidget(app());
      await ready(tester);
      expect(find.text('Fix reconnect'), findsOneWidget);
      expect(find.text('upgrade'), findsOneWidget);
      expect(find.text('rose · shell 1'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await unmount(tester);
    },
  );

  testWidgets('the card keeps its first line clear of the dot', (tester) async {
    sized(tester);
    await seed();
    shells.stall = false;
    sessions.open(intent: testIntent(), _rose);
    await tester.pumpWidget(app());
    await ready(tester);

    final card = tester.getRect(find.byKey(const ValueKey('shell-card-h1-1')));
    final dot = tester.getRect(find.byKey(const ValueKey('shell-dot-h1-1')));

    expect(card.right - dot.right, lessThan(dot.left - card.left));

    await unmount(tester);
  });

  testWidgets('session captions use their natural height at large text sizes', (
    tester,
  ) async {
    sized(tester);
    await seed();
    shells.stall = false;
    sessions.open(intent: testIntent(), _rose)!.title =
        'A long terminal task title';
    await tester.pumpWidget(app(textScale: 2));
    await ready(tester);
    expect(find.text('A long terminal task title'), findsOneWidget);
    expect(find.text('rose · shell 1'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('a card opens its own host on its own tab', (tester) async {
    sized(tester);
    await seed();
    shells.stall = false;
    sessions.open(intent: testIntent(), _nyx);
    final second = sessions.open(intent: testIntent(), _nyx)!;
    sessions.activate(_nyx.id, sessions.forHost(_nyx.id).first);
    await tester.pumpWidget(app());
    await ready(tester);

    await tester.tap(find.byKey(const ValueKey('shell-card-h2-2')));
    await ready(tester);

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('shell-header')),
        matching: find.text('NYX'),
      ),
      findsOneWidget,
    );
    expect(sessions.activeFor(_nyx.id), same(second));

    await unmount(tester);
  });

  testWidgets('a card with no session opens one', (tester) async {
    sized(tester);
    await seed();
    shells.stall = false;
    await tester.pumpWidget(app());
    await ready(tester);

    await tester.tap(find.byKey(const ValueKey('ssh-host-h2')));
    await ready(tester);
    expect(find.text('NEW SHELL ON NYX'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('launch-shell')));
    await ready(tester);

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('shell-header')),
        matching: find.text('NYX'),
      ),
      findsOneWidget,
    );
    expect(sessions.forHost(_nyx.id), hasLength(1));

    await unmount(tester);
  });

  testWidgets(
    'a host whose only tab exited asks again and keeps the dead tab',
    (tester) async {
      sized(tester);
      await seed();
      shells.stall = false;
      final dead = sessions.open(intent: testIntent(), _nyx)!;
      await tester.pumpWidget(app());
      await ready(tester);
      shells.opened.last.exit(1);
      await ready(tester);
      expect(dead.state, isA<ShellExited>());

      await tester.tap(find.byKey(const ValueKey('ssh-host-h2')));
      await ready(tester);
      expect(find.text('NEW SHELL ON NYX'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('launch-shell')));
      await ready(tester);

      expect(sessions.forHost(_nyx.id), hasLength(2));
      expect(sessions.forHost(_nyx.id).first, same(dead));
      expect(sessions.activeFor(_nyx.id)?.number, 2);

      await unmount(tester);
    },
  );

  testWidgets('a card offers the screens its host has', (tester) async {
    sized(tester);
    await seed();
    await tester.pumpWidget(
      app(desktops: const [_rose], devices: const [_nyx]),
    );
    await ready(tester);

    expect(find.byKey(const ValueKey('desktop-host-h1')), findsOneWidget);
    expect(find.byKey(const ValueKey('devices-host-h1')), findsNothing);
    expect(find.byKey(const ValueKey('desktop-host-h2')), findsNothing);
    expect(find.byKey(const ValueKey('devices-host-h2')), findsOneWidget);

    final dock = ProviderScope.containerOf(
      tester.element(find.byType(HostsScreen)),
    ).read(deviceDockProvider);
    final asks = dock.asks;
    await tester.tap(find.byKey(const ValueKey('devices-host-h2')));
    await tester.pump();
    expect(dock.asks, asks + 1);

    await unmount(tester);
  });

  testWidgets('no host is the panel saying so, not an empty screen', (
    tester,
  ) async {
    sized(tester);
    await tester.pumpWidget(app());
    await ready(tester);

    expect(
      find.text('ADD A HOST TO CONNECT TO YOUR COMPUTER.'),
      findsOneWidget,
    );

    await unmount(tester);
  });
}
