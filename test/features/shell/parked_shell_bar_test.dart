import '../../support/native_plugins.dart';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:striked/app/nav_shell.dart';
import 'package:striked/app/striked_app.dart';
import 'package:striked/application/agents/agent_state.dart';
import 'package:striked/application/agents/agents.dart';
import 'package:striked/application/navigation.dart';
import 'package:striked/data/database.dart';
import 'package:striked/data/repositories/host_repository.dart';
import 'package:striked/data/repositories/key_repository.dart';
import 'package:striked/design/spacing.dart';
import 'package:striked/features/shell/parked_shell_bar.dart';
import 'package:striked/features/shell/session/shell_sessions.dart';
import 'package:striked/features/shell/shell_status.dart';
import 'package:striked/platform/shell/shell_connection.dart';
import 'package:striked/platform/herdr/herdr_client.dart';

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
  port: 22,
  user: 'luis',
  keyId: 'key-1',
);

final _key = ManagedKey(
  id: 'key-1',
  name: 'faraday',
  publicKey: 'ssh-ed25519 AAAATEST faraday',
  fingerprint: 'SHA256:key-1',
  createdAt: DateTime(2026),
);

void main() {
  late AppDatabase db;
  late ShellSessions sessions;
  late FakeShellTransport transport;

  setUp(() {
    stubDeviceChannels();
    db = AppDatabase(NativeDatabase.memory());
    transport = FakeShellTransport();
    sessions = fakeShellSessions(transport);
  });

  tearDown(() => db.close());

  Widget app({List<Override> extra = const []}) => ProviderScope(
    overrides: [
      ...featureTestOverrides(db),
      shellSessionsProvider.overrideWithValue(sessions),
      ...extra,
    ],
    child: MaterialApp(theme: testTheme, home: StrikedShell()),
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
  final label = find.byKey(const ValueKey('parked-shell-label'));
  final more = find.byKey(const ValueKey('parked-shell-more'));
  final verb = find.byKey(const ValueKey('parked-shell-verb'));
  Override registered() =>
      hostRepositoryProvider.overrideWithValue(DriftHostRepository(db));
  final fresh = find.byKey(const ValueKey('parked-shell-new'));
  Finder freshHost(Host host) =>
      find.byKey(ValueKey('parked-shell-new-host-${host.id}'));
  Finder cell(Host host) =>
      find.byKey(ValueKey('parked-shell-host-${host.id}'));
  Finder count(Host host, int tabs) =>
      find.descendant(of: cell(host), matching: find.text('$tabs'));

  for (final width in [360.0, 900.0]) {
    for (final scale in [1.0, 1.5]) {
      testWidgets('resume aligns with bar edge at width $width scale $scale', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 1200);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.pumpWidget(app());
        await ready(tester);
        sessions.open(intent: testIntent(), _rose);
        await ready(tester);

        expect(tester.getSize(bar).width, width);
        expect(
          tester.getTopRight(verb).dx,
          closeTo(width - Spacing.screenEdge, 0.01),
        );
        if (scale == 1) {
          expect(tester.widget<Text>(verb).data, 'TAP TO RESUME');
        }
        expect(tester.takeException(), isNull);

        await tester.tap(verb);
        await ready(tester);
        expect(header, findsOneWidget);
        await unmount(tester);
      });
    }
  }

  testWidgets('no host, no bar', (tester) async {
    await tester.pumpWidget(app());
    await ready(tester);

    expect(find.byType(ParkedShellBar), findsOneWidget);
    expect(bar, findsNothing);
    expect(fresh, findsNothing);

    await unmount(tester);
  });

  testWidgets('a host with nothing open offers its first shell', (
    tester,
  ) async {
    await DriftKeyRepository(db).save(_key);
    await DriftHostRepository(db).save(_rose);
    await tester.pumpWidget(app(extra: [registered()]));
    await ready(tester);

    expect(bar, findsNothing);
    expect(fresh, findsOneWidget);
    expect(freshHost(_rose), findsOneWidget);
    expect(tester.widget<Text>(verb).data, 'NEW SHELL');

    await tester.tap(fresh);
    await ready(tester);
    expect(find.text('NEW SHELL ON ROSE'), findsWidgets);
    expect(sessions.forHost(_rose.id), isEmpty);

    await tester.tap(find.byKey(const ValueKey('launch-shell')));
    await ready(tester);
    expect(header, findsOneWidget);
    expect(sessions.forHost(_rose.id), hasLength(1));

    await unmount(tester);
  });

  testWidgets('with more than one host the bar asks which one', (tester) async {
    await DriftKeyRepository(db).save(_key);
    await DriftHostRepository(db).save(_rose);
    await DriftHostRepository(db).save(_nyx);
    await tester.pumpWidget(app(extra: [registered()]));
    await ready(tester);
    expect(freshHost(_nyx), findsOneWidget);

    await tester.tap(fresh);
    await ready(tester);
    expect(find.text('NEW SHELL ON'), findsOneWidget);
    expect(find.text('CURRENT'), findsOneWidget);

    await tester.tap(find.byKey(ValueKey('parked-shell-new-pick-${_rose.id}')));
    await ready(tester);
    expect(find.text('NEW SHELL ON ROSE'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('launch-shell')));
    await ready(tester);
    expect(sessions.forHost(_rose.id), hasLength(1));
    expect(sessions.forHost(_nyx.id), isEmpty);

    await unmount(tester);
  });

  testWidgets('the host menu opens on the side the bar was tapped', (
    tester,
  ) async {
    await DriftKeyRepository(db).save(_key);
    await DriftHostRepository(db).save(_rose);
    await DriftHostRepository(db).save(_nyx);
    await tester.pumpWidget(app(extra: [registered()]));
    await ready(tester);
    final row = find.byKey(ValueKey('parked-shell-new-pick-${_rose.id}'));
    final width = tester.getSize(fresh).width;
    final y = tester.getCenter(fresh).dy;

    await tester.tapAt(Offset(width - 8, y));
    await ready(tester);
    expect(tester.getRect(row).right, greaterThan(width * 0.75));

    await tester.tapAt(Offset(width - 8, y));
    await ready(tester);
    expect(row, findsNothing);

    await tester.tapAt(Offset(8, y));
    await ready(tester);
    expect(tester.getRect(row).left, lessThan(width * 0.25));

    await unmount(tester);
  });

  testWidgets('the last tab closing offers a new shell on its host', (
    tester,
  ) async {
    await DriftKeyRepository(db).save(_key);
    await DriftHostRepository(db).save(_rose);
    await DriftHostRepository(db).save(_nyx);
    await tester.pumpWidget(app(extra: [registered()]));
    await ready(tester);
    expect(freshHost(_nyx), findsOneWidget);

    final session = sessions.open(intent: testIntent(), _rose)!;
    await ready(tester);
    expect(bar, findsOneWidget);
    expect(fresh, findsNothing);

    await sessions.close(intent: testIntent(), _rose.id, session);
    await ready(tester);

    expect(bar, findsNothing);
    expect(freshHost(_rose), findsOneWidget);

    await DriftHostRepository(db).delete(_rose.id);
    await ready(tester);
    expect(freshHost(_nyx), findsOneWidget);

    await DriftHostRepository(db).delete(_nyx.id);
    await ready(tester);
    expect(fresh, findsNothing);

    await unmount(tester);
  });

  testWidgets('an open session parks over the nav bar', (tester) async {
    await tester.pumpWidget(app());
    await ready(tester);

    sessions.open(intent: testIntent(), _rose);
    await ready(tester);

    expect(bar, findsOneWidget);
    expect(count(_rose, 1), findsOneWidget);
    expect(find.text('TAP TO RESUME'), findsOneWidget);
    expect(
      tester.getBottomLeft(bar).dy,
      moreOrLessEquals(tester.getTopLeft(find.byType(NavBar)).dy),
    );

    await unmount(tester);
  });

  testWidgets('the agent line stacks on it without taking the window', (
    tester,
  ) async {
    // Two bars and the nav bar are three rows at the foot of one window. A column that ran
    // out of window throws here rather than quietly taking the bottom off the labels.
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(
      app(
        extra: [
          navIndexProvider.overrideWith((ref) => 1),
          // The strip draws a count only while something is keeping the count current.
          agentsFeedLiveProvider.overrideWithValue(true),
          agentsFeedProvider.overrideWith(
            (ref) => Stream.value(
              AgentPanelState([
                HostOutcome(
                  host: _rose,
                  kind: AgentOutcomeKind.snapshot,
                  agents: [
                    AgentSnapshot(
                      session: 'default',
                      paneId: 'wQ:p1',
                      agent: 'claude',
                      state: AgentState.of('blocked'),
                      terminalTitleStripped: 'work',
                      workspaceId: 'wQ',
                      cwd: '/workspace/striked',
                      stateChangeSeq: 1,
                    ),
                  ],
                ),
              ]),
            ),
          ),
        ],
      ),
    );
    await ready(tester);

    sessions.open(intent: testIntent(), _rose);
    await ready(tester);

    final line = find.byKey(const ValueKey('agent-status'));
    expect(
      ProviderScope.containerOf(tester.element(find.byType(StrikedShell)))
          .read(navIndexProvider),
      1,
      reason: 'Loading plugin placements must not reset the selected page',
    );
    expect(line, findsOneWidget);
    expect(bar, findsOneWidget);

    expect(
      tester.getBottomLeft(line).dy,
      moreOrLessEquals(tester.getTopLeft(bar).dy),
    );
    expect(
      tester.getBottomLeft(bar).dy,
      moreOrLessEquals(tester.getTopLeft(find.byType(NavBar)).dy),
    );

    await unmount(tester);
  });

  testWidgets('a tap on the bar raises the shell it names', (tester) async {
    await tester.pumpWidget(app());
    await ready(tester);

    sessions.open(intent: testIntent(), _rose);
    await ready(tester);
    await tester.tap(bar);
    await ready(tester);

    expect(header, findsOneWidget);
    expect(
      find.descendant(of: header, matching: find.text('ROSE')),
      findsOneWidget,
    );

    await unmount(tester);
  });

  testWidgets('the sheet goes down onto the bar and the bar brings it back', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await ready(tester);

    sessions.open(intent: testIntent(), _rose);
    await ready(tester);
    await tester.tap(bar);
    await ready(tester);
    expect(header, findsOneWidget);

    await tester.drag(header, const Offset(0, 400));
    await ready(tester);

    expect(header, findsNothing);
    expect(bar, findsOneWidget);

    await tester.tap(bar);
    await ready(tester);
    expect(header, findsOneWidget);

    await unmount(tester);
  });

  testWidgets('the bar names the tab last brought forward', (tester) async {
    await tester.pumpWidget(app());
    await ready(tester);

    final first = sessions.open(intent: testIntent(), _rose)!;
    sessions.open(intent: testIntent(), _nyx);
    await ready(tester);
    expect(
      tester.getTopLeft(cell(_nyx)).dx,
      lessThan(tester.getTopLeft(cell(_rose)).dx),
    );

    sessions.activate(_rose.id, first);
    await ready(tester);
    expect(
      tester.getTopLeft(cell(_rose)).dx,
      lessThan(tester.getTopLeft(cell(_nyx)).dx),
    );

    await unmount(tester);
  });

  testWidgets('every host is counted by its tabs', (tester) async {
    await tester.pumpWidget(app());
    await ready(tester);

    sessions.open(intent: testIntent(), _rose);
    sessions.open(intent: testIntent(), _rose);
    sessions.open(intent: testIntent(), _nyx);
    await ready(tester);

    expect(count(_rose, 2), findsOneWidget);
    expect(count(_nyx, 1), findsOneWidget);
    expect(more, findsNothing);

    await unmount(tester);
  });

  testWidgets('a renamed host is renamed on the bar', (tester) async {
    await tester.pumpWidget(app());
    await ready(tester);

    sessions.open(intent: testIntent(), _rose);
    sessions.open(intent: testIntent(), _nyx);
    await ready(tester);
    expect(
      find.descendant(of: cell(_rose), matching: find.text('ROSE')),
      findsOneWidget,
    );

    sessions.syncHosts(const [
      Host(
        id: 'h1',
        name: 'mark',
        address: '100.64.0.1',
        port: 22,
        user: 'luis',
        keyId: 'key-1',
      ),
      _nyx,
    ]);
    await ready(tester);

    expect(
      find.descendant(of: cell(_rose), matching: find.text('MARK')),
      findsOneWidget,
    );
    expect(find.text('ROSE'), findsNothing);

    await unmount(tester);
  });

  testWidgets('the last session closing takes the bar with it', (tester) async {
    await tester.pumpWidget(app());
    await ready(tester);

    final session = sessions.open(intent: testIntent(), _rose)!;
    await ready(tester);
    expect(bar, findsOneWidget);

    await sessions.close(intent: testIntent(), _rose.id, session);
    await ready(tester);

    expect(bar, findsNothing);

    await unmount(tester);
  });

  testWidgets('a host whose last tab closed falls to a host that has one', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await ready(tester);

    sessions.open(intent: testIntent(), _rose);
    final second = sessions.open(intent: testIntent(), _nyx)!;
    await ready(tester);
    expect(cell(_nyx), findsOneWidget);

    await sessions.close(intent: testIntent(), _nyx.id, second);
    await ready(tester);

    expect(cell(_nyx), findsNothing);
    expect(count(_rose, 1), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('one host names its tab, and only by its label', (tester) async {
    await tester.pumpWidget(app());
    await ready(tester);

    sessions.open(intent: testIntent(), _rose);
    await ready(tester);
    expect(label, findsNothing);

    transport.opened.single.emit('\x1b]0;luis@rose: ~/Projects/striked\x07');
    await ready(tester);
    expect(find.text('striked'), findsOneWidget);

    sessions.open(intent: testIntent(), _nyx);
    await ready(tester);
    expect(label, findsNothing);
    expect(find.text('striked'), findsNothing);

    await unmount(tester);
  });

  testWidgets('a host with a tab that is not live carries a dot', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await ready(tester);

    sessions.open(intent: testIntent(), _rose);
    sessions.open(intent: testIntent(), _nyx);
    await ready(tester);
    final dots = find.descendant(of: bar, matching: find.byType(ShellStateDot));
    expect(dots, findsNothing);

    transport.opened.first.setHealth(ShellConnectionHealth.reconnecting);
    await ready(tester);
    expect(
      find.descendant(of: cell(_rose), matching: find.byType(ShellStateDot)),
      findsOneWidget,
    );
    expect(dots, findsOneWidget);

    await unmount(tester);
  });

  for (final width in [320.0, 360.0, 400.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('hosts that do not fit are counted at $width x$scale', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 1200);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.pumpWidget(app());
        await ready(tester);

        final hosts = [
          for (var i = 0; i < 6; i++)
            Host(
              id: 'many-$i',
              name: 'machine-$i',
              address: '100.64.1.$i',
              port: 22,
              user: 'luis',
              keyId: 'key-1',
            ),
        ];
        for (final host in hosts) {
          sessions.open(intent: testIntent(), host);
        }
        await ready(tester);

        expect(tester.takeException(), isNull);
        final front = hosts.last;
        expect(cell(front), findsOneWidget);
        expect(count(front, 1), findsOneWidget);
        final drawn = hosts.where((host) => cell(host).evaluate().isNotEmpty);
        final left = hosts.length - drawn.length;
        expect(left, greaterThan(0));
        if (scale == 1) {
          expect(tester.widget<Text>(verb).data, 'TAP TO RESUME');
          expect(
            tester.widget<Text>(more).data,
            anyOf('+$left HOSTS', '+$left'),
          );
        }
        if (more.evaluate().isNotEmpty) {
          expect(
            tester.getTopRight(more).dx,
            lessThanOrEqualTo(tester.getTopLeft(verb).dx),
          );
        }
        await unmount(tester);
      });
    }
  }
}
