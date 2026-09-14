import 'support/native_plugins.dart';

import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/application/agents.dart';
import 'package:dazzle/application/navigation.dart';
import 'package:dazzle/data/database.dart';
import 'package:dazzle/design/spacing.dart';
import 'package:dazzle/data/enums.dart';
import 'package:dazzle/data/repositories/host_repository.dart';
import 'package:dazzle/data/repositories/key_repository.dart';
import 'package:dazzle/features/hosts/hosts_screen.dart';
import 'package:dazzle/features/hosts/link_probes.dart';
import 'package:dazzle/features/hosts/preview_tile.dart';
import 'package:dazzle/features/screen/screen_preview.dart';
import 'package:dazzle/features/shell/shell_sessions.dart';
import 'package:dazzle/features/shell/shell_status.dart';
import 'package:dazzle/features/settings/settings_screen.dart';
import 'package:dazzle/platform/keys.dart';
import 'package:dazzle/platform/host_key_dial.dart';
import 'package:dazzle/platform/host_keys.dart';
import 'package:dazzle/platform/link_probe.dart';
import 'package:dazzle/platform/shell/shell_connection.dart';
import 'package:dazzle/platform/vnc/framebuffer.dart';
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

/// What a phone hands over when the reader raises the text size: a curve, not
/// a factor. A label's size doubles, a size the app never paints text at is
/// left where it was.
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
    root = Directory.systemTemp.createTempSync('dazzle-access');
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
    // Nothing here dials, so the default is a dial that opens nothing and
    // comes back; the tests that care hand their own in.
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

  Widget app(Widget child, {int index = 0, List<Override> extra = const []}) =>
      ProviderScope(
        overrides: [
          ...extra,
          navIndexProvider.overrideWith((ref) => index),
          ...featureTestOverrides(db),
          keyRepositoryProvider.overrideWithValue(keys),
          hostRepositoryProvider.overrideWithValue(hosts),
          privateKeyStoreProvider.overrideWithValue(privateKeys),
          screenPreviewsProvider.overrideWith((ref) async => previews),
          shellSessionsProvider.overrideWithValue(sessions),
          linkProbesProvider.overrideWithValue(probes),
          hostKeyDialProvider.overrideWith((ref) => dial),
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
    await tester.pumpWidget(app(const HostsScreen()));
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

  /// The width `_MetaRow` gives the label column, which the screen keeps to
  /// itself.
  const labelColumn = 96.0;

  testWidgets('a metadata label is given the width its words take', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await seed();

    /// How far the value sits from the start of the label beside it. Measured
    /// from the two left edges, which are box positions rather than ink, so the
    /// fallback font a test renders with cannot move them.
    Future<double> reach([TextScaler? scaler]) async {
      await tester.pumpWidget(
        app(
          scaler == null
              ? const HostsScreen()
              : Builder(
                  builder: (context) => MediaQuery(
                    data: MediaQuery.of(context).copyWith(textScaler: scaler),
                    child: const HostsScreen(),
                  ),
                ),
        ),
      );
      await ready(tester);
      final label = tester.getRect(find.text('INTEGRATIONS').first).left;
      final value = tester.getRect(find.text('HERDR')).left;
      await unmount(tester);
      return value - label;
    }

    final reached = await reach();
    // A phone does not raise every size by the same factor: the curve gives a
    // small one most of the rise and a large one almost none. A column derived
    // from the label's own size follows the label; one derived from its width
    // hardly moves, and the longest label broke across two lines in the middle
    // of a word.
    final curved = await reach(_systemCurve);

    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final bigReach = await reach();

    // The column is the longest label and nothing else, so the value has to
    // start a gutter past the end of it at every text size. Held at the width
    // it was drawn at, the column was one the longest label ran out of and
    // into its own value; given no gutter, the two still touched.
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

  testWidgets('the sessions are not on this screen any more', (tester) async {
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await seed();
    shells.stall = false;
    sessions.open(_rose);
    await tester.pumpWidget(app(const HostsScreen()));
    await ready(tester);

    // The cards are the SSH tab's. What a host keeps here is the row that
    // starts one, which still counts what is open on it.
    expect(find.text('SHELLS'), findsNothing);
    expect(find.text('ACTIVE SESSIONS'), findsNothing);
    expect(find.byKey(const ValueKey('shell-card-h1-1')), findsNothing);
    expect(find.text('SHELL · 1 OPEN'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('the link row says what answered, and what did not', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // The hosts without their integrations: HOSTS in front starts the agents
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

    // The probes go out when HOSTS is the tab in front, not when the widget
    // happens to be built, so the route has to be the one on screen.
    await tester.pumpWidget(
      app(const HostsScreen(), index: HostsScreen.navIndex),
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
          agentRetryProvider.overrideWithValue((host) {
            requested = host;
            return retried.future;
          }),
        ],
      ),
    );
    await ready(tester);

    expect(find.text('HERDR STATUS'), findsNWidgets(2));
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

    // One machine the app can recognise and one it cannot. The offer to look
    // stands only on the second.
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
    // The dial is held open, which is what the machine on the other end does
    // while a user reads a fingerprint.
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
    await tester.tap(find.text('VERIFY'));
    await ready(tester);

    // The row says the dial is out. Nothing else on the screen does, and a
    // silent one is the failure the user reported.
    expect(find.text('VERIFYING'), findsOneWidget);
    expect(find.text('VERIFY'), findsNothing);

    answered.completeError(const HostKeySilent());
    await ready(tester);

    // A machine that took the connection and never presented a key. The word
    // stands until the next tap rather than being written to a log nobody on a
    // handset can read.
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
    // The state the user reported from: the key is pinned and the last poll
    // still says it is not. The affordance is drawn off that poll, so the row
    // offers a dial whose answer it then has nowhere to put.
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

    // Both hosts offer it: rose off the stale poll, nyx because nothing is
    // pinned to it at all. The tap is rose's.
    expect(find.text('VERIFY'), findsNWidgets(2));
    await tester.tap(find.text('VERIFY').first);
    await ready(tester);

    // The machine answered with the key the app already trusts. That is an
    // answer, and the row stops asking for one rather than dropping back to
    // `VERIFY` as though the tap had never happened.
    expect(asked, 1);
    expect(find.text('VERIFYING'), findsNothing);
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

    await tester.pumpWidget(app(const HostsScreen()));
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
    await tester.pumpWidget(app(const HostsScreen()));
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
