import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotline/application/agents.dart';
import 'package:hotline/application/navigation.dart';
import 'package:hotline/application/providers.dart';
import 'package:hotline/data/database.dart';
import 'package:hotline/data/enums.dart';
import 'package:hotline/data/repositories/host_repository.dart';
import 'package:hotline/data/repositories/key_repository.dart';
import 'package:hotline/design/colors.dart';
import 'package:hotline/features/access/access_screen.dart';
import 'package:hotline/features/access/link_probes.dart';
import 'package:hotline/features/access/preview_tile.dart';
import 'package:hotline/features/screen/screen_preview.dart';
import 'package:hotline/features/shell/shell_sessions.dart';
import 'package:hotline/features/settings/settings_screen.dart';
import 'package:hotline/platform/keys.dart';
import 'package:hotline/platform/host_keys.dart';
import 'package:hotline/platform/link_probe.dart';
import 'package:hotline/platform/shell/shell_connection.dart';
import 'package:hotline/platform/vnc/framebuffer.dart';
import 'package:xterm/xterm.dart';

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

ManagedKey _key(String id, String name) => ManagedKey(
  id: id,
  name: name,
  publicKey: 'ssh-ed25519 AAAATEST $name',
  fingerprint: 'SHA256:$id-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  createdAt: DateTime(2026),
);

void main() {
  late AppDatabase db;
  late InMemoryKeyRepository keys;
  late InMemoryHostRepository hosts;
  late MemoryPrivateKeyStore privateKeys;
  late Directory root;
  late ScreenPreviews previews;
  late FakeShellTransport shells;
  late ShellSessions sessions;
  late Map<String, LinkResult> answers;
  late List<String> probed;
  late LinkProbes probes;

  setUp(() {
    stubDeviceChannels();
    db = AppDatabase(NativeDatabase.memory());
    keys = InMemoryKeyRepository();
    hosts = InMemoryHostRepository();
    privateKeys = MemoryPrivateKeyStore();
    root = Directory.systemTemp.createTempSync('hotline-access');
    previews = ScreenPreviews(Directory('${root.path}/screens'));
    shells = FakeShellTransport()..stall = true;
    sessions = fakeShellSessions(shells);
    // No socket in a test. Without this the panel knocks on the addresses the
    // fixtures name, which are somebody's machines.
    answers = {};
    probed = [];
    probes = LinkProbes(
      probe: (address, port) async {
        probed.add('$address:$port');
        return answers['$address:$port'] ?? const LinkResult.unknown();
      },
    );
    addTearDown(previews.dispose);
  });

  tearDown(() {
    root.deleteSync(recursive: true);
    return db.close();
  });

  Widget app(Widget child, {int index = 0}) => ProviderScope(
    overrides: [
      navIndexProvider.overrideWith((ref) => index),
      databaseProvider.overrideWithValue(db),
      keyRepositoryProvider.overrideWithValue(keys),
      hostRepositoryProvider.overrideWithValue(hosts),
      privateKeyStoreProvider.overrideWithValue(privateKeys),
      screenPreviewsProvider.overrideWith((ref) async => previews),
      shellSessionsProvider.overrideWithValue(sessions),
      linkProbesProvider.overrideWithValue(probes),
    ],
    child: MaterialApp(home: child),
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
    await keys.save(_key('key-1', 'faraday'));
    await keys.save(_key('key-2', 'workstation'));
    await hosts.save(_rose);
    await hosts.save(_nyx);
    await hosts.setIntegration(_rose.id, IntegrationKind.herdr, true);
    await hosts.setIntegration(_nyx.id, IntegrationKind.herdr, true);
    await hosts.setIntegration(_nyx.id, IntegrationKind.vnc, true);
  }

  testWidgets('every host is listed with its metadata and tokens', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await seed();
    await tester.pumpWidget(app(const AccessScreen()));
    await ready(tester);

    expect(find.text('NYX'), findsOneWidget);
    expect(find.text('ROSE'), findsOneWidget);
    expect(find.text('100.64.0.1:22'), findsOneWidget);
    expect(find.text('100.64.0.2:357'), findsOneWidget);
    expect(find.text('luis'), findsNWidgets(2));
    // Once as each host's KEY, and once as its own row in the KEYS panel.
    expect(find.text('faraday'), findsNWidgets(3));
    expect(find.text('HERDR'), findsOneWidget);
    expect(find.text('HERDR  VNC'), findsOneWidget);
    expect(find.text('ADD HOST'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('every host panel offers a shell and the row is the hit', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await seed();
    await tester.pumpWidget(app(const AccessScreen()));
    await ready(tester);

    // Both hosts, not just the one with a screen: ssh is what a host already
    // is, so it is not behind an integration.
    expect(find.text('SHELL'), findsNWidgets(2));

    // The whole row, which is wider than the words in it.
    final row = find.ancestor(
      of: find.text('SHELL').first,
      matching: find.byType(GestureDetector),
    );
    await tester.tapAt(tester.getCenter(row.first));
    await ready(tester);

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('shell-header')),
        matching: find.text('ROSE'),
      ),
      findsOneWidget,
    );

    await unmount(tester);
  });

  testWidgets('no shell means no panel for shells', (tester) async {
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await seed();
    await tester.pumpWidget(app(const AccessScreen()));
    await ready(tester);

    expect(find.text('SHELLS'), findsNothing);

    await unmount(tester);
  });

  testWidgets('every open session is a card, in the order of the hosts', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await seed();
    shells.stall = false;
    sessions.open(_rose);
    sessions.open(_nyx);
    sessions.open(_nyx);
    await tester.pumpWidget(app(const AccessScreen()));
    await ready(tester);

    expect(find.text('SHELLS'), findsOneWidget);
    expect(find.byKey(const ValueKey('shell-card-h1-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('shell-card-h2-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('shell-card-h2-2')), findsOneWidget);
    expect(find.text('ROSE 1'), findsOneWidget);
    expect(find.text('NYX 2'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('the card carries the state of the session under it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await seed();
    shells.stall = false;
    sessions.open(_rose);
    await tester.pumpWidget(app(const AccessScreen()));
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

    expect(dot(), HotlineColors.accent);

    shells.opened.single.exit(0);
    await ready(tester);
    expect(dot(), HotlineColors.textMuted);

    await unmount(tester);
  });

  testWidgets('a card opens its own host on its own tab', (tester) async {
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await seed();
    shells.stall = false;
    sessions.open(_nyx);
    final second = sessions.open(_nyx)!;
    sessions.activate(_nyx.id, sessions.forHost(_nyx.id).first);
    await tester.pumpWidget(app(const AccessScreen()));
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

  testWidgets('the link row says what answered, and what did not', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // The hosts without their integrations: ACCESS in front starts the agents
    // poll, and its ten-second tick would outlive the test.
    await keys.save(_key('key-1', 'faraday'));
    await hosts.save(_rose);
    await hosts.save(_nyx);
    answers['100.64.0.1:22'] = const LinkResult(
      LinkStatus.up,
      software: 'OpenSSH_9.9',
      latency: Duration(milliseconds: 120),
    );
    answers['100.64.0.2:357'] = const LinkResult(LinkStatus.refused);

    // The probes go out when ACCESS is the tab in front, not when the widget
    // happens to be built, so the route has to be the one on screen.
    await tester.pumpWidget(
      app(const AccessScreen(), index: AccessScreen.navIndex),
    );
    await ready(tester);

    // What the machine calls itself and how long it took to say so, which is
    // the difference between a host that is up and a port that is open.
    expect(find.text('OPENSSH_9.9 · 120 MS'), findsOneWidget);
    expect(find.text('REFUSED'), findsOneWidget);
    expect(probed, ['100.64.0.1:22', '100.64.0.2:357']);

    // The whole row is the hit, and a tap asks again however fresh the answer.
    final row = find.ancestor(
      of: find.text('REFUSED'),
      matching: find.byType(GestureDetector),
    );
    await tester.tapAt(tester.getCenter(row.first));
    await ready(tester);

    expect(probed, hasLength(3));
    expect(probed.last, '100.64.0.2:357');

    await unmount(tester);
  });

  testWidgets('VERIFY stands on the hosts with no key pinned to them', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await seed();
    await hosts.pinHostKey(
      _rose.id,
      PinnedHostKey(
        type: 'ssh-ed25519',
        fingerprint: 'SHA256:rose',
        pinnedAt: DateTime(2026, 9, 3),
      ),
    );

    await tester.pumpWidget(app(const AccessScreen()));
    await ready(tester);

    // One machine the app can recognise and one it cannot. The offer to look
    // stands only on the second.
    expect(find.text('VERIFY'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('the shell row counts what is open on its own host', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await seed();
    sessions.open(_rose);
    sessions.open(_rose);

    await tester.pumpWidget(app(const AccessScreen()));
    await ready(tester);

    expect(find.text('SHELL · 2 OPEN'), findsOneWidget);
    // The host with nothing open is not counted at zero: it reads as the way
    // in, which is what it is.
    expect(find.text('SHELL'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('a host with no integration reads NONE', (tester) async {
    await keys.save(_key('key-1', 'faraday'));
    await hosts.save(_rose);
    await tester.pumpWidget(app(const AccessScreen()));
    await ready(tester);

    expect(find.text('NONE'), findsOneWidget);
    expect(find.byType(ScreenPreviewTile), findsNothing);

    await unmount(tester);
  });

  testWidgets('only a VNC host gets a tile, and it says so before a frame', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await seed();
    await tester.pumpWidget(app(const AccessScreen()));
    await ready(tester);

    expect(find.byType(ScreenPreviewTile), findsOneWidget);
    expect(find.text('NO FRAME YET'), findsOneWidget);
    expect(find.text('SCREEN'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('a stored frame replaces the empty tile', (tester) async {
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await seed();
    await tester.runAsync(() => previews.write(_nyx.id, Framebuffer(640, 360)));
    await tester.pumpWidget(app(const AccessScreen()));
    await ready(tester);

    expect(find.byType(ScreenPreviewTile), findsOneWidget);
    expect(find.text('NO FRAME YET'), findsNothing);
    expect(find.byType(Image), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('the tile follows the writer while the route is on screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    double aspect() => tester
        .widget<AspectRatio>(
          find
              .descendant(
                of: find.byType(ScreenPreviewTile),
                matching: find.byType(AspectRatio),
              )
              .first,
        )
        .aspectRatio;

    await seed();
    await tester.pumpWidget(app(const AccessScreen()));
    await ready(tester);
    expect(find.text('NO FRAME YET'), findsOneWidget);

    await tester.runAsync(() => previews.write(_nyx.id, Framebuffer(640, 360)));
    await ready(tester);
    expect(find.text('NO FRAME YET'), findsNothing);
    expect(find.byType(Image), findsOneWidget);
    expect(aspect(), closeTo(320 / 180, 0.001));

    // A second frame of another shape: the tile has to take the new file, not
    // the one it already read off the same path.
    await tester.runAsync(() => previews.write(_nyx.id, Framebuffer(800, 800)));
    await ready(tester);
    expect(aspect(), closeTo(1, 0.001));

    await tester.runAsync(() => previews.delete(_nyx.id));
    await ready(tester);
    expect(find.text('NO FRAME YET'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('the keys come after the hosts, each with its name', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await seed();
    await tester.pumpWidget(app(const AccessScreen()));
    await ready(tester);

    expect(find.text('KEYS'), findsOneWidget);
    expect(find.text('workstation'), findsOneWidget);
    // The fingerprint is cut to the 28 characters a reader compares.
    expect(find.text('SHA256:key-1-${'a' * 15}…'), findsOneWidget);
    expect(find.text('ADD KEY'), findsOneWidget);
    expect(
      tester.getCenter(find.text('ADD HOST')).dy,
      lessThan(tester.getCenter(find.text('ADD KEY')).dy),
    );

    await unmount(tester);
  });

  testWidgets('SYS carries no host or key block', (tester) async {
    await seed();
    await tester.pumpWidget(app(const SettingsScreen()));
    await ready(tester);

    expect(find.text('[ HOSTS ]'), findsNothing);
    expect(find.text('[ KEYS ]'), findsNothing);
    expect(find.text('nyx'), findsNothing);
    expect(find.text('faraday'), findsNothing);
    expect(find.text('[ ALERTS ]'), findsOneWidget);
    expect(find.text('[ STATIC ]'), findsOneWidget);
    expect(find.text('[ BUILD ]'), findsOneWidget);

    await unmount(tester);
  });

  group('the dot on the shell row', () {
    test('takes the worst state of the sessions under it', () {
      final live = ShellSession(number: 1, terminal: Terminal(), host: _rose)
        ..state = const ShellLive();
      final connecting = ShellSession(
        number: 2,
        terminal: Terminal(),
        host: _rose,
      )..state = const ShellConnecting();
      final failed = ShellSession(number: 3, terminal: Terminal(), host: _rose)
        ..state = const ShellFailed(ShellFailureKind.streamClosed);

      expect(worstShellState([]), isNull);
      expect(worstShellState([connecting]), isA<ShellConnecting>());
      // A shell that is up is worth saying so beside one still dialling, and
      // one tab in trouble is what the panel has to say however many are fine
      // next to it.
      expect(worstShellState([connecting, live]), isA<ShellLive>());
      expect(worstShellState([live, connecting, failed]), isA<ShellFailed>());
    });
  });
}
