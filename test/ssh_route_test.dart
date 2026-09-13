import 'support/native_plugins.dart';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/application/agents.dart';
import 'package:dazzle/data/database.dart';
import 'package:dazzle/data/repositories/host_repository.dart';
import 'package:dazzle/data/repositories/key_repository.dart';
import 'package:dazzle/design/colors.dart';
import 'package:dazzle/features/shell/shell_sessions.dart';
import 'package:dazzle/features/ssh/ssh_screen.dart';

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

  Widget app() => ProviderScope(
    overrides: [
      ...featureTestOverrides(db),
      keyRepositoryProvider.overrideWithValue(keys),
      hostRepositoryProvider.overrideWithValue(hosts),
      shellSessionsProvider.overrideWithValue(sessions),
    ],
    child: const MaterialApp(home: SshScreen()),
  );

  /// The background grain runs off a ticker that never settles, so a test that
  /// ends with the tree mounted leaves a pending timer and hangs the file.
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  Future<void> ready(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
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

  testWidgets('every host is a row saying what it is dialled as', (
    tester,
  ) async {
    sized(tester);
    await seed();
    await tester.pumpWidget(app());
    await ready(tester);

    expect(find.text('ROSE'), findsOneWidget);
    expect(find.text('NYX'), findsOneWidget);
    // The Termius line: what the row does with the host, not what the host is.
    // Its address, key and state are on HOSTS.
    expect(find.text('ssh, luis'), findsNWidgets(2));
    expect(find.text('100.64.0.1:22'), findsNothing);

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
    sessions.open(_rose);
    sessions.open(_nyx);
    sessions.open(_nyx);
    await tester.pumpWidget(app());
    await ready(tester);

    expect(find.text('ACTIVE SESSIONS'), findsOneWidget);
    expect(find.byKey(const ValueKey('shell-card-h1-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('shell-card-h2-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('shell-card-h2-2')), findsOneWidget);
    expect(find.text('ROSE 1'), findsOneWidget);
    expect(find.text('NYX 2'), findsOneWidget);
    // The host rows count what is open on them, so the list below the cards
    // says the same thing about a machine that the cards above it do.
    expect(find.text('1 OPEN'), findsOneWidget);
    expect(find.text('2 OPEN'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('the card carries the state of the session under it', (
    tester,
  ) async {
    sized(tester);
    await seed();
    shells.stall = false;
    sessions.open(_rose);
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

    expect(dot(), DazzleColors.accent);

    shells.opened.single.exit(1);
    await ready(tester);
    expect(dot(), DazzleColors.textMuted);

    await unmount(tester);
  });

  testWidgets('the card keeps its first line clear of the dot', (tester) async {
    sized(tester);
    await seed();
    shells.stall = false;
    sessions.open(_rose);
    await tester.pumpWidget(app());
    await ready(tester);

    // The output starts in the top leading corner now, so the mark sits in the
    // other one.
    final card = tester.getRect(find.byKey(const ValueKey('shell-card-h1-1')));
    final dot = tester.getRect(find.byKey(const ValueKey('shell-dot-h1-1')));

    expect(card.right - dot.right, lessThan(dot.left - card.left));

    await unmount(tester);
  });

  testWidgets('a card opens its own host on its own tab', (tester) async {
    sized(tester);
    await seed();
    shells.stall = false;
    sessions.open(_nyx);
    final second = sessions.open(_nyx)!;
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

  testWidgets('a host row with no session opens one', (tester) async {
    sized(tester);
    await seed();
    shells.stall = false;
    await tester.pumpWidget(app());
    await ready(tester);

    await tester.tap(find.byKey(const ValueKey('ssh-host-h2')));
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

  testWidgets('no host is the panel saying so, not an empty screen', (
    tester,
  ) async {
    sized(tester);
    await tester.pumpWidget(app());
    await ready(tester);

    expect(find.text('NO HOSTS REGISTERED'), findsOneWidget);

    await unmount(tester);
  });
}
