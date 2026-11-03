import '../../support/launch_scan.dart';
import '../../support/native_plugins.dart';

import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/application/agents/agents.dart';
import 'package:upgrade/application/navigation.dart';
import 'package:upgrade/data/database.dart';
import 'package:upgrade/design/colors.dart';
import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/data/enums.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/data/repositories/key_repository.dart';
import 'package:upgrade/features/hosts/hosts_screen.dart';
import 'package:upgrade/features/hosts/link_probes.dart';
import 'package:upgrade/features/hosts/preview_tile.dart';
import 'package:upgrade/features/screen/screen_preview.dart';
import 'package:upgrade/features/shell/session/shell_sessions.dart';
import 'package:upgrade/features/shell/shell_status.dart';
import 'package:upgrade/features/settings/settings_screen.dart';
import 'package:upgrade/platform/herdr/herdr_client.dart';
import 'package:upgrade/platform/ssh/keys.dart';
import 'package:upgrade/platform/ssh/host_key_dial.dart';
import 'package:upgrade/platform/ssh/host_keys.dart';
import 'package:upgrade/platform/links/link_probe.dart';
import 'package:upgrade/platform/shell/shell_connection.dart';
import 'package:upgrade/platform/vnc/framebuffer.dart';
import 'package:flterm/flterm.dart';
import 'package:upgrade/application/providers.dart';

import '../../support/fake_shell.dart';
import '../../support/platform_channels.dart';
import '../../support/reasons.dart';
import '../../support/themed_app.dart';

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

/// What a phone hands over when the reader raises the text size: a curve, not a factor.
const _systemCurve = _SystemCurve();

class _SystemCurve implements TextScaler {
  const _SystemCurve();

  @override
  double scale(double fontSize) =>
      fontSize <= 20 ? fontSize * 2 : fontSize * 1.05;

  @override
  double get textScaleFactor => 2;

  @override
  TextScaler clamp({double minScaleFactor = 0, double maxScaleFactor = 1}) =>
      this;
}

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
  late HostKeyDial dial;

  setUp(() {
    stubDeviceChannels();
    db = AppDatabase(NativeDatabase.memory());
    keys = InMemoryKeyRepository();
    hosts = InMemoryHostRepository();
    privateKeys = MemoryPrivateKeyStore();
    root = Directory.systemTemp.createTempSync('upgrade-access');
    previews = ScreenPreviews(Directory('${root.path}/screens'));
    shells = FakeShellTransport()..stall = true;
    sessions = fakeShellSessions(shells);
    // No socket in a test. Without this the panel knocks on the addresses the fixtures name,
    // which are somebody's machines.
    answers = {};
    probed = [];
    probes = LinkProbes(
      probe: (address, port) async {
        probed.add('$address:$port');
        return answers['$address:$port'] ?? const LinkResult.unknown();
      },
    );
    dial = ({
      required address,
      required port,
      required user,
      required privateKey,
      required verifier,
    }) async {};
    addTearDown(previews.dispose);
  });

  tearDown(() {
    root.deleteSync(recursive: true);
    return db.close();
  });

  Widget app(
    Widget child, {
    int index = 0,
    List<Override> extra = const [],
    TextScaler? scaler,
  }) => ProviderScope(
    retry: noRetry,
    overrides: [
      ...extra,
      navIndexProvider.overrideWith((ref) => index),
      ...featureTestOverrides(db),
      keyRepositoryProvider.overrideWithValue(keys),
      hostRepositoryProvider.overrideWithValue(hosts),
      privateKeyStoreProvider.overrideWithValue(privateKeys),
      screenPreviewsProvider.overrideWith((ref) async => previews),
      shellSessionsProvider.overrideWithValue(sessions),
      noLaunchTargets,
      linkProbesProvider.overrideWithValue(probes),
      hostKeyDialProvider.overrideWith((ref) => dial),
    ],
    child: MaterialApp(
      theme: testTheme,
      home: child,
      builder: scaler == null
          ? null
          : (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: scaler),
              child: child!,
            ),
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
    await keys.save(_key('key-1', 'faraday'));
    await keys.save(_key('key-2', 'workstation'));
    await hosts.save(_rose);
    await hosts.save(_nyx);
    await hosts.setIntegration(_rose.id, IntegrationKind.herdr, true);
    await hosts.setIntegration(_nyx.id, IntegrationKind.herdr, true);
    await hosts.setIntegration(_nyx.id, IntegrationKind.vnc, true);
  }

  Future<void> details(WidgetTester tester, String host) async {
    await tester.tap(find.text(host));
    await ready(tester);
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('every host is listed with its metadata and tokens', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await seed();
    await tester.pumpWidget(app(const HostsScreen()));
    await ready(tester);

    expect(find.text('NYX'), findsOneWidget);
    expect(find.text('ROSE'), findsOneWidget);
    expect(find.text('luis@100.64.0.1'), findsOneWidget);
    expect(find.text('luis@100.64.0.2:357'), findsOneWidget);
    expect(find.text('DETAILS'), findsNWidgets(2));
    expect(find.text('INTEGRATIONS'), findsNothing);
    expect(find.byType(ScreenPreviewTile), findsNothing);
    expect(find.text('ADD HOST'), findsOneWidget);

    await unmount(tester);
  });

  const labelColumn = 96.0;

  testWidgets('wide hosts keep list and selected details side by side', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await seed();
    await tester.pumpWidget(app(const HostsScreen()));
    await ready(tester);
    expect(find.text('DETAILS'), findsNWidgets(2));
    expect(find.text('INTEGRATIONS'), findsOneWidget);
    expect(find.byType(ScreenPreviewTile), findsNothing);
    expect(tester.getTopLeft(find.text('INTEGRATIONS')).dx, greaterThan(350));
    await tester.tap(find.text('NYX'));
    await ready(tester);
    expect(find.byType(ScreenPreviewTile), findsOneWidget);
    expect(
      Navigator.of(tester.element(find.text('ADD HOST'))).canPop(),
      isFalse,
    );
    await unmount(tester);
  });

  testWidgets('narrow details return to the compact host list', (tester) async {
    tester.view.physicalSize = const Size(400, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await seed();
    await tester.pumpWidget(app(const HostsScreen()));
    await ready(tester);
    await details(tester, 'NYX');
    expect(find.text('INTEGRATIONS'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await ready(tester);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(find.text('DETAILS'), findsNWidgets(2));
    expect(find.text('INTEGRATIONS'), findsNothing);
    await unmount(tester);
  });

  testWidgets('a metadata label is given the width its words take', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await seed();

    /// Measured from the two left edges, which are box positions rather than ink, so the
    /// fallback font a test renders with cannot move them.
    Future<double> reach([TextScaler? scaler]) async {
      await tester.pumpWidget(app(const HostsScreen(), scaler: scaler));
      await ready(tester);
      await details(tester, 'ROSE');
      final label = tester.getRect(find.text('INTEGRATIONS').first).left;
      final value = tester.getRect(find.text('HERDR')).left;
      await unmount(tester);
      return value - label;
    }

    final reached = await reach();
    final curved = await reach(_systemCurve);

    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final bigReach = await reach();

    expect(reached, closeTo(labelColumn + Spacing.md, 0.01));
    expect(bigReach, closeTo(labelColumn * 1.3 + Spacing.md, 0.01));
    expect(curved, closeTo(labelColumn * 2 + Spacing.md, 0.01));
  });

  testWidgets('every host panel offers a shell and the row is the hit', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await seed();
    await tester.pumpWidget(app(const HostsScreen()));
    await ready(tester);

    await details(tester, 'ROSE');
    expect(find.text('SHELL'), findsOneWidget);

    final row = find.ancestor(
      of: find.text('SHELL').first,
      matching: find.byType(GestureDetector),
    );
    await tester.tapAt(tester.getCenter(row.first));
    await ready(tester);
    expect(find.text('NEW SHELL ON ROSE'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('launch-shell')));
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

  testWidgets('the sessions are counted on their card, with no shelf', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await seed();
    shells.stall = false;
    sessions.open(intent: testIntent(), _rose);
    await tester.pumpWidget(app(const HostsScreen()));
    await ready(tester);

    expect(find.text('ACTIVE SESSIONS'), findsNothing);
    expect(find.text('SHELL · 1 OPEN'), findsOneWidget);
    await details(tester, 'ROSE');
    expect(find.text('SHELL · 1 OPEN'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('the link row says what answered, and what did not', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // HOSTS in front starts the agents poll, and its ten-second tick would outlive the test.
    await keys.save(_key('key-1', 'faraday'));
    await hosts.save(_rose);
    await hosts.save(_nyx);
    answers['100.64.0.1:22'] = const LinkResult(
      LinkStatus.up,
      software: 'OpenSSH_9.9',
      latency: Duration(milliseconds: 120),
    );
    answers['100.64.0.2:357'] = const LinkResult(LinkStatus.refused);

    // The probes go out when HOSTS is the tab in front, not when the widget happens to be
    // built.
    await tester.pumpWidget(
      app(const HostsScreen(), index: HostsScreen.navIndex),
    );
    await ready(tester);

    expect(find.text('OPENSSH_9.9 · 120 MS'), findsOneWidget);
    expect(find.text('REFUSED'), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('host-link-h2')))
          .style
          ?.color,
      UpgradeColors.warning,
    );
    expect(probed, ['100.64.0.1:22', '100.64.0.2:357']);
    await details(tester, 'NYX');

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

  testWidgets('HERDR failure retries without changing shell state', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await seed();
    final retried = Completer<HostOutcome>();
    Host? requested;
    final failed = AgentPanelState([
      const HostOutcome(host: _rose, kind: AgentOutcomeKind.unreachable),
    ]);

    await tester.pumpWidget(
      app(
        const HostsScreen(),
        index: HostsScreen.navIndex,
        extra: [
          agentsFeedProvider.overrideWith((ref) => Stream.value(failed)),
          agentRetryProvider.overrideWithValue((
            host, {
            source = AgentSource.herdr,
          }) {
            requested = host;
            return retried.future;
          }),
        ],
      ),
    );
    await ready(tester);

    await details(tester, 'ROSE');
    expect(find.text('HERDR STATUS'), findsOneWidget);
    expect(find.text('rose unreachable'), findsOneWidget);
    expect(find.text('RETRY'), findsOneWidget);
    expect(find.byKey(const ValueKey('shell-row-dot-h1')), findsNothing);

    await tester.tap(find.text('RETRY'));
    await tester.pump();

    expect(requested, _rose);
    expect(find.text('RETRYING'), findsOneWidget);
    expect(find.byKey(const ValueKey('shell-row-dot-h1')), findsNothing);

    retried.complete(
      const HostOutcome(host: _rose, kind: AgentOutcomeKind.snapshot),
    );
    await ready(tester);

    expect(find.text('0 agents · 0 blocked'), findsOneWidget);
    expect(find.text('RETRY'), findsNothing);
    expect(find.byKey(const ValueKey('shell-row-dot-h1')), findsNothing);

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

    await tester.pumpWidget(app(const HostsScreen()));
    await ready(tester);

    await details(tester, 'NYX');
    expect(find.text('VERIFY'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('VERIFY says it is dialling, and says what the dial hit', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await seed();
    await privateKeys.write('key-1', 'PEM');
    await hosts.pinHostKey(
      _rose.id,
      PinnedHostKey(
        type: 'ssh-ed25519',
        fingerprint: 'SHA256:rose',
        pinnedAt: DateTime(2026, 9, 3),
      ),
    );
    final answered = Completer<void>();
    dial = ({
      required address,
      required port,
      required user,
      required privateKey,
      required verifier,
    }) => answered.future;

    await tester.pumpWidget(app(const HostsScreen()));
    await ready(tester);
    await details(tester, 'NYX');
    await tester.tap(find.text('VERIFY'));
    await ready(tester);

    expect(find.text('VERIFYING'), findsOneWidget);
    expect(find.text('VERIFY'), findsNothing);

    answered.completeError(const HostKeySilent());
    await ready(tester);

    expect(find.text('NO ANSWER'), findsOneWidget);
    expect(find.text('VERIFYING'), findsNothing);

    await unmount(tester);
  });

  testWidgets('VERIFY on a host that is already trusted says so and stops', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await seed();
    await privateKeys.write('key-1', 'PEM');
    final pin = PinnedHostKey(
      type: 'ssh-ed25519',
      fingerprint: 'SHA256:rose',
      pinnedAt: DateTime(2026, 9, 3),
    );
    await hosts.pinHostKey(_rose.id, pin);
    final stale = AgentPanelState([
      HostOutcome(
        host: Host(
          id: _rose.id,
          name: _rose.name,
          address: _rose.address,
          port: _rose.port,
          user: _rose.user,
          keyId: _rose.keyId,
          hostKey: pin,
        ),
        kind: AgentOutcomeKind.hostKeyUnverified,
      ),
    ]);
    var asked = 0;
    dial =
        ({
          required address,
          required port,
          required user,
          required privateKey,
          required verifier,
        }) async {
          asked++;
          await verifier.verifyFingerprint('ssh-ed25519', 'SHA256:rose');
        };

    await tester.pumpWidget(
      app(
        const HostsScreen(),
        extra: [agentsFeedProvider.overrideWith((ref) => Stream.value(stale))],
      ),
    );
    await ready(tester);

    await details(tester, 'ROSE');
    expect(find.text('VERIFY'), findsOneWidget);
    await tester.tap(find.text('VERIFY').first);
    await ready(tester);

    expect(asked, 1);
    expect(find.text('VERIFYING'), findsNothing);
    expect(find.text('VERIFY'), findsNothing);

    await unmount(tester);
  });

  testWidgets('the shell row counts what is open on its own host', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await seed();
    sessions.open(intent: testIntent(), _rose);
    sessions.open(intent: testIntent(), _rose);

    await tester.pumpWidget(app(const HostsScreen()));
    await ready(tester);

    await details(tester, 'ROSE');
    expect(find.text('SHELL · 2 OPEN'), findsOneWidget);
    expect(find.text('SHELL'), findsNothing);

    await unmount(tester);
  });

  testWidgets('the shell row is the last one, under every readout', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await seed();
    shells.stall = false;
    sessions.open(intent: testIntent(), _rose);

    await tester.pumpWidget(app(const HostsScreen()));
    await ready(tester);

    await details(tester, 'ROSE');
    final panel = find
        .ancestor(of: find.text('CLIPBOARD'), matching: find.byType(Panel))
        .first;
    final shell = tester.getTopLeft(find.text('SHELL · 1 OPEN')).dy;

    for (final label in const [
      'ADDRESS',
      'USER',
      'KEY',
      'LINK',
      'INTEGRATIONS',
      'HERDR STATUS',
      'CLIPBOARD',
    ]) {
      expect(
        tester
            .getTopLeft(find.descendant(of: panel, matching: find.text(label)))
            .dy,
        lessThan(shell),
        reason: label,
      );
    }

    await unmount(tester);
  });

  testWidgets('a host with no integration reads NONE', (tester) async {
    await keys.save(_key('key-1', 'faraday'));
    await hosts.save(_rose);
    await tester.pumpWidget(app(const HostsScreen()));
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
    await tester.pumpWidget(app(const HostsScreen()));
    await ready(tester);

    await details(tester, 'NYX');
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
    await tester.pumpWidget(app(const HostsScreen()));
    await ready(tester);
    await details(tester, 'NYX');

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
    await tester.pumpWidget(app(const HostsScreen()));
    await ready(tester);
    await details(tester, 'NYX');
    expect(find.text('NO FRAME YET'), findsOneWidget);

    await tester.runAsync(() => previews.write(_nyx.id, Framebuffer(640, 360)));
    await ready(tester);
    expect(find.text('NO FRAME YET'), findsNothing);
    expect(find.byType(Image), findsOneWidget);
    expect(aspect(), closeTo(320 / 180, 0.001));

    await tester.runAsync(() => previews.write(_nyx.id, Framebuffer(800, 800)));
    await ready(tester);
    expect(aspect(), closeTo(1, 0.001));

    await tester.runAsync(() => previews.delete(_nyx.id));
    await ready(tester);
    expect(find.text('NO FRAME YET'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('the hosts toolbar opens SSH key management', (tester) async {
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await seed();
    await tester.pumpWidget(app(const HostsScreen()));
    await ready(tester);

    expect(find.text('KEYS'), findsNothing);
    expect(find.text('ADD KEY'), findsNothing);
    await tester.tap(find.byTooltip('MANAGE SSH KEYS'));
    await ready(tester);

    expect(find.text('SSH KEYS'), findsOneWidget);
    expect(find.text('workstation'), findsOneWidget);
    expect(find.text('SHA256:key-1-${'a' * 15}…'), findsOneWidget);
    expect(find.text('ADD KEY'), findsOneWidget);

    expect(
      Navigator.of(tester.element(find.text('SSH KEYS'))).canPop(),
      isTrue,
    );
    await tester.tap(find.text('/ PERSONAL CONTROL PLANE / HOSTS'));
    await tester.pump(const Duration(milliseconds: 600));
    await ready(tester);
    expect(
      Navigator.of(tester.element(find.text('SSH KEYS'))).canPop(),
      isFalse,
    );
    expect(find.text('ADD HOST'), findsOneWidget);

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
    expect(find.text('[ BACKGROUND ]'), findsOneWidget);
    expect(find.text('[ BUILD ]'), findsOneWidget);

    await unmount(tester);
  });

  group('the dot on the shell row', () {
    test('takes the worst state of the sessions under it', () {
      final live = ShellSession(
        number: 1,
        terminal: TerminalController(),
        host: _rose,
      )..state = const ShellLive();
      final connecting = ShellSession(
        number: 2,
        terminal: TerminalController(),
        host: _rose,
      )..state = const ShellConnecting();
      final failed = ShellSession(
        number: 3,
        terminal: TerminalController(),
        host: _rose,
      )..state = const ShellFailed(ShellFailureKind.streamClosed);

      expect(worstShellState([]), isNull);
      expect(worstShellState([connecting]), isA<ShellConnecting>());
      expect(worstShellState([connecting, live]), isA<ShellLive>());
      expect(worstShellState([live, connecting, failed]), isA<ShellFailed>());
    });
  });
}
