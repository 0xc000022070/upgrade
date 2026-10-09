import 'support/native_plugins.dart';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/app/nav_shell.dart';
import 'package:upgrade/app/upgrade_app.dart';
import 'package:upgrade/application/agent_state.dart';
import 'package:upgrade/application/agents.dart';
import 'package:upgrade/application/navigation.dart';
import 'package:upgrade/data/database.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/features/shell/parked_shell_bar.dart';
import 'package:upgrade/features/shell/shell_sessions.dart';
import 'package:upgrade/platform/herdr_client.dart';

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
  port: 22,
  user: 'luis',
  keyId: 'key-1',
);

void main() {
  late AppDatabase db;
  late ShellSessions sessions;

  setUp(() {
    stubDeviceChannels();
    db = AppDatabase(NativeDatabase.memory());
    sessions = fakeShellSessions(FakeShellTransport());
  });

  tearDown(() => db.close());

  Widget app({List<Override> extra = const []}) => ProviderScope(
    overrides: [
      ...featureTestOverrides(db),
      shellSessionsProvider.overrideWithValue(sessions),
      ...extra,
    ],
    child: MaterialApp(theme: testTheme, home: UpgradeShell()),
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
          tester.getTopRight(find.text('TAP TO RESUME')).dx,
          closeTo(width - Spacing.screenEdge, 0.01),
        );
        expect(tester.takeException(), isNull);

        await tester.tap(find.text('TAP TO RESUME'));
        await ready(tester);
        expect(header, findsOneWidget);
        await unmount(tester);
      });
    }
  }

  testWidgets('nothing open, no bar', (tester) async {
    await tester.pumpWidget(app());
    await ready(tester);

    expect(find.byType(ParkedShellBar), findsOneWidget);
    expect(bar, findsNothing);

    await unmount(tester);
  });

  testWidgets('an open session parks over the nav bar', (tester) async {
    await tester.pumpWidget(app());
    await ready(tester);

    sessions.open(intent: testIntent(), _rose);
    await ready(tester);

    expect(bar, findsOneWidget);
    expect(find.text('ROSE 1'), findsOneWidget);
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
                      cwd: '/workspace/upgrade',
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
      ProviderScope.containerOf(tester.element(find.byType(UpgradeShell)))
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
    expect(find.text('ROSE'), findsOneWidget);

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
    expect(find.text('NYX 2'), findsNothing);
    expect(find.text('NYX 1'), findsOneWidget);

    sessions.activate(_rose.id, first);
    await ready(tester);
    expect(find.text('ROSE 1'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('tabs running behind the named one are counted', (tester) async {
    await tester.pumpWidget(app());
    await ready(tester);

    sessions.open(intent: testIntent(), _rose);
    await ready(tester);
    expect(find.text('+1'), findsNothing);

    sessions.open(intent: testIntent(), _rose);
    sessions.open(intent: testIntent(), _nyx);
    await ready(tester);

    expect(find.text('NYX 1'), findsOneWidget);
    expect(find.text('+2'), findsOneWidget);

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
    expect(find.text('NYX 1'), findsOneWidget);

    await sessions.close(intent: testIntent(), _nyx.id, second);
    await ready(tester);

    expect(find.text('ROSE 1'), findsOneWidget);

    await unmount(tester);
  });
}
