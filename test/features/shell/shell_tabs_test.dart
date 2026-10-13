import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:upgrade/application/shell/launch_scan.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/design/colors.dart';
import 'package:upgrade/design/components/cell_divider.dart';
import 'package:upgrade/design/components/dot_spinner.dart';
import 'package:upgrade/design/components/scan_sweep.dart';
import 'package:upgrade/design/motion.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/features/shell/host_shell_screen.dart';
import 'package:upgrade/features/shell/shell_header.dart';
import 'package:upgrade/features/shell/session/shell_sessions.dart';
import 'package:upgrade/features/shell/shell_status.dart';
import 'package:upgrade/platform/herdr/herdr_client.dart';
import 'package:upgrade/platform/shell/shell_connection.dart';
import 'package:upgrade/platform/shell/shell_launch.dart';
import 'package:flterm/flterm.dart';

import '../../support/fake_shell.dart';
import '../../support/launch_scan.dart';
import '../../support/platform_channels.dart';
import '../../support/reasons.dart';
import '../../support/shell_route.dart';
import '../../support/themed_app.dart';

String labelOfTab(WidgetTester tester, int number) => tester
    .widget<Text>(
      find.descendant(
        of: find.byKey(ValueKey('shell-tab-h1-$number')),
        matching: find.byType(Text),
      ),
    )
    .data!;

Color? dotOfTab(WidgetTester tester, int number) =>
    (tester
                .widget<Container>(
                  find.descendant(
                    of: find.descendant(
                      of: find.byKey(ValueKey('shell-tab-h1-$number')),
                      matching: find.byType(ShellStateDot),
                    ),
                    matching: find.byType(Container),
                  ),
                )
                .decoration
            as BoxDecoration)
        .color;

Color? inkOfInfoMark(WidgetTester tester) => tester
    .widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('shell-tab-info')),
        matching: find.byType(Text),
      ),
    )
    .style
    ?.color;

/// The sheet's own transition and no more: a tab on a reconnect schedule moves on under a
/// longer pump.
Future<void> openInfo(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('shell-tab-info')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

List<String?> headerWords(WidgetTester tester) => tester
    .widgetList<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('shell-header')),
        matching: find.byType(Text),
      ),
    )
    .map((text) => text.data)
    .toList();

void main() {
  setUp(stubDeviceChannels);

  testWidgets('a live Mosh tab says nothing about its transport on the row', (
    tester,
  ) async {
    final transport = FakeShellTransport()..transport = ShellTransport.mosh;
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions));
    await ready(tester);

    expect(find.text('MOSH'), findsNothing);
    expect(find.byKey(const ValueKey('shell-tab-info')), findsNothing);

    await unmount(tester);
  });

  testWidgets('a live tab whose host is down says its background reads are '
      'stale, and a tap dials it', (tester) async {
    final transport = FakeShellTransport()..transport = ShellTransport.mosh;
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions));
    await ready(tester);
    final connection = transport.opened.single;
    connection.emit('\$ ');
    await ready(tester);
    expect(find.byKey(const ValueKey('shell-tab-info')), findsNothing);

    connection.setControlDown(true);
    await ready(tester);
    expect(find.byKey(const ValueKey('shell-tab-info')), findsOneWidget);
    expect(inkOfInfoMark(tester), UpgradeColors.warning);

    await openInfo(tester);
    expect(find.byKey(const ValueKey('shell-info-background')), findsOneWidget);
    final opens = connection.opens.length;
    await tester.tap(find.byKey(const ValueKey('shell-info-reconnect')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(connection.opens, hasLength(opens + 1));

    connection.setControlDown(false);
    await ready(tester);
    expect(find.byKey(const ValueKey('shell-tab-info')), findsNothing);

    await unmount(tester);
  });

  testWidgets('a tab the host has not drawn on sweeps until it does', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions));
    await ready(tester);

    final sweep = find.descendant(
      of: find.byKey(const ValueKey('shell-tab-h1-1')),
      matching: find.byType(ScanSweep),
    );
    expect(sweep, findsOneWidget);

    transport.opened.single.emit('\$ ');
    await ready(tester);
    expect(sweep, findsNothing);
    expect(labelOfTab(tester, 1), '1');

    await unmount(tester);
  });

  testWidgets('a tab sweeps in the warning ink while its link comes back', (
    tester,
  ) async {
    final transport = FakeShellTransport()..transport = ShellTransport.mosh;
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions));
    await ready(tester);
    transport.opened.single.emit('\$ ');
    await ready(tester);

    final sweep = find.descendant(
      of: find.byKey(const ValueKey('shell-tab-h1-1')),
      matching: find.byType(ScanSweep),
    );
    expect(sweep, findsNothing);

    for (final health in const [
      ShellConnectionHealth.reconnecting,
      ShellConnectionHealth.disconnected,
    ]) {
      transport.opened.single.setHealth(health);
      await tester.pump();
      await tester.pump();
      expect(tester.widget<ScanSweep>(sweep).lit, UpgradeColors.warning);
      final band = find.descendant(
        of: sweep,
        matching: find.byType(ShaderMask),
      );
      if (health == ShellConnectionHealth.reconnecting) {
        expect(band, findsNothing);
        await tester.pump(Effects.spinnerThreshold);
      }
      expect(band, findsOneWidget);
      expect(find.byType(DelayedSpinner), findsNothing);
    }

    transport.opened.single.setHealth(ShellConnectionHealth.connected);
    await tester.pump();
    await tester.pump();
    expect(sweep, findsNothing);

    transport.opened.single.drop();
    await tester.pump();
    await tester.pump();
    expect(tester.widget<ScanSweep>(sweep).lit, UpgradeColors.warning);
    expect(find.byType(DelayedSpinner), findsNothing);

    await tester.pump(shellReconnectDelays.first);
    await ready(tester);
    expect(sweep, findsNothing);

    await unmount(tester);
  });

  testWidgets('a live SSH tab puts no word in the middle of the header', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions));
    await ready(tester);

    expect(headerWords(tester), ['ROSE', '1', '+', '×']);

    await unmount(tester);
  });

  testWidgets('a tab off the air marks the row and names its state in the '
      'sheet', (tester) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions));
    await ready(tester);

    transport.opened.single.exit(1);
    await ready(tester);
    await tester.tap(find.text('KEEP'));
    await ready(tester);

    expect(headerWords(tester), contains('(i)'));
    expect(find.text('EXITED 1'), findsNothing);
    expect(inkOfInfoMark(tester), UpgradeColors.warning);

    await openInfo(tester);

    expect(find.text('STATE'), findsOneWidget);
    expect(find.text('EXITED 1'), findsOneWidget);
    expect(find.text('TRANSPORT'), findsOneWidget);
    expect(find.text('SSH'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('the plus menu opens a numbered tab on the selected host', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions));
    await ready(tester);

    expect(find.byKey(const ValueKey('shell-tab-h1-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('shell-tab-h1-2')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('shell-tab-new')));
    await ready(tester);

    expect(find.byKey(const ValueKey('shell-new-host-h1')), findsOneWidget);
    expect(find.text('NEW SHELL ON'), findsOneWidget);
    expect(find.text('CURRENT'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('CURRENT')).dx -
          tester.getTopRight(find.text('ROSE').last).dx,
      greaterThanOrEqualTo(Spacing.md),
    );

    await tester.tap(find.byKey(const ValueKey('shell-new-host-h1')));
    await ready(tester);
    await tester.tap(find.byKey(const ValueKey('launch-shell')));
    await ready(tester);

    expect(find.byKey(const ValueKey('shell-tab-h1-2')), findsOneWidget);
    expect(sessions.activeFor(rose.id)?.number, 2);

    await tester.tap(find.byKey(const ValueKey('shell-tab-h1-1')));
    await ready(tester);
    expect(sessions.activeFor(rose.id)?.number, 1);

    await unmount(tester);
  });

  testWidgets('the sheet offers the live herdr hub once and runs a tmux pick', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          shellSessionsProvider.overrideWithValue(sessions),
          noWorkspaces,
          ...noSettings,
          launchScannerProvider.overrideWithValue(
            FixedLaunchScanner(
              const LaunchScanFound(
                LaunchTargets(
                  herdrSessions: [
                    SessionEntry(
                      name: 'hub',
                      running: true,
                      isDefault: false,
                      socketPath: '/h/hub.sock',
                    ),
                    SessionEntry(
                      name: 'hyprland',
                      running: false,
                      isDefault: false,
                      socketPath: '/h/hyprland.sock',
                    ),
                  ],
                  workspaces: [
                    HerdrWorkspaceEntry(
                      session: 'hub',
                      id: 'w1',
                      label: 'repbit',
                      status: 'idle',
                      focused: false,
                    ),
                    HerdrWorkspaceEntry(
                      session: 'hub',
                      id: 'w2',
                      label: 'upgrade',
                      status: 'working',
                      focused: true,
                    ),
                  ],
                  tmux: [
                    TmuxSessionEntry(name: '0', windows: 2, attached: 1),
                    TmuxSessionEntry(
                      name: 'drop',
                      windows: 1,
                      attached: 0,
                      socket: '/tmp/tmux-1000/default',
                    ),
                  ],
                  hasHerdr: true,
                  hasTmux: true,
                ),
              ),
            ),
          ),
        ],
        child: MaterialApp(
          theme: testTheme,
          home: HostShellRoute(host: rose, intent: testIntent()),
        ),
      ),
    );
    await ready(tester);

    await tester.tap(find.byKey(const ValueKey('shell-tab-new')));
    await ready(tester);
    await tester.tap(find.byKey(const ValueKey('shell-new-host-h1')));
    await ready(tester);

    expect(find.byKey(const ValueKey('launch-herdr-hub')), findsOneWidget);
    expect(find.text('2 spaces · 1 working'), findsOneWidget);
    expect(find.text('hyprland'), findsNothing);
    expect(find.text('upgrade'), findsNothing);
    expect(find.text('ATTACHED'), findsOneWidget);
    expect(find.text('tmux 1'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('launch-tmux:drop@/tmp/tmux-1000/default')),
      findsOneWidget,
    );
    expect(find.text('1 window · /tmp'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('launch-tmux-new')));
    await ready(tester);

    expect(sessions.activeFor(rose.id)?.number, 2);
    expect(transport.commands.last, contains("tmux new-session -A -s '1'"));

    await unmount(tester);
  });

  testWidgets('a host with neither tool still opens a login shell', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions));
    await ready(tester);

    await tester.tap(find.byKey(const ValueKey('shell-tab-new')));
    await ready(tester);
    await tester.tap(find.byKey(const ValueKey('shell-new-host-h1')));
    await ready(tester);

    expect(find.text('HERDR'), findsOneWidget);
    expect(find.text('TMUX'), findsOneWidget);
    expect(find.text('not on this host'), findsNWidgets(2));
    await tester.tap(find.byKey(const ValueKey('launch-herdr-absent')));
    await tester.tap(find.byKey(const ValueKey('launch-tmux-absent')));
    await ready(tester);
    expect(find.text('LOGIN SHELL'), findsOneWidget);
    expect(find.byKey(const ValueKey('launch-herdr-default')), findsNothing);
    expect(find.byKey(const ValueKey('launch-tmux-new')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('launch-shell')));
    await ready(tester);

    expect(sessions.activeFor(rose.id)?.number, 2);
    expect(transport.commands.last, isNot(contains('tmux')));
    expect(transport.commands.last, isNot(contains('herdr')));

    await unmount(tester);
  });

  testWidgets(
    'the plus menu keeps CURRENT off its edge at a large text scale',
    (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final sessions = fakeShellSessions(FakeShellTransport());
      await tester.pumpWidget(app(sessions));
      await ready(tester);

      await tester.tap(find.byKey(const ValueKey('shell-tab-new')));
      await ready(tester);

      final item = find.byKey(const ValueKey('shell-new-host-h1'));
      final current = find.text('CURRENT');
      expect(
        tester.getTopRight(item).dx - tester.getTopRight(current).dx,
        greaterThanOrEqualTo(Spacing.lg),
      );

      await unmount(tester);
    },
  );

  group('a tab says which shell it is', () {
    test('a shell with no title reads its number', () {
      expect(shellTabLabel(null, 3), '3');
      expect(shellTabLabel('   ', 3), '3');
    });

    test('a login shell reads where it is, not who it is', () {
      expect(shellTabLabel('luis@nyx: ~/Projects/upgrade', 1), 'upgrade');
      expect(shellTabLabel('luis@nyx: ~', 1), '~');
      expect(shellTabLabel('~/Projects/upgrade', 1), 'upgrade');
    });

    test('a title with a space in it is a sentence and is kept whole', () {
      expect(shellTabLabel('vim design/SPEC.md', 2), 'vim design/SPEC.md');
      expect(shellTabLabel('htop', 2), 'htop');
    });

    testWidgets('the title a shell sets lands on its tab', (tester) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions));
      await ready(tester);
      expect(labelOfTab(tester, 1), '1');

      transport.opened.first.emit('\x1b]0;luis@rose: ~/Projects/upgrade\x07');
      await ready(tester);

      expect(labelOfTab(tester, 1), 'upgrade');

      await unmount(tester);
    });

    testWidgets('a long title cannot take the header', (tester) async {
      tester.view.physicalSize = const Size(411, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions));
      await ready(tester);

      transport.opened.first.emit(
        '\x1b]0;a title far wider than any phone has room for\x07',
      );
      await ready(tester);

      expect(
        tester.getSize(find.byKey(const ValueKey('shell-tab-h1-1'))).width,
        lessThan(411 * 0.55),
      );
      expect(tester.takeException(), isNull);

      await unmount(tester);
    });

    testWidgets('a tab carries the state of the shell in it', (tester) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions));
      await ready(tester);

      expect(dotOfTab(tester, 1), UpgradeColors.accent);

      transport.opened.first.drop();
      await ready(tester);

      expect(dotOfTab(tester, 1), isNot(UpgradeColors.accent));

      expect(find.text('STOP'), findsNothing);
      await openInfo(tester);
      await tester.tap(find.byKey(const ValueKey('shell-info-stop')));
      await ready(tester);

      await unmount(tester);
    });

    testWidgets('a numbered tab takes no more room than its number', (
      tester,
    ) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions));
      await ready(tester);

      expect(
        tester.getSize(find.byKey(const ValueKey('shell-tab-h1-1'))).width,
        lessThan(60),
      );

      await unmount(tester);
    });

    testWidgets('a tmux or herdr tab wears its logo where the dot was', (
      tester,
    ) async {
      const named = Host(
        id: 'h1',
        name: 'NYX',
        address: '100.64.0.1',
        port: 22,
        user: 'luis',
        keyId: 'key-1',
      );
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      sessions.open(intent: testIntent(), named, launch: TmuxLaunch('main'));
      sessions.open(
        intent: testIntent(),
        named,
        launch: HerdrLaunch('default'),
      );
      sessions.open(intent: testIntent(), named);
      await tester.pumpWidget(
        app(
          sessions,
          home: HostShellRoute(host: named, intent: testIntent()),
        ),
      );
      await ready(tester);

      Finder inTab(int number, Type type) => find.descendant(
        of: find.byKey(ValueKey('shell-tab-h1-$number')),
        matching: find.byType(type),
      );
      for (final number in [1, 2]) {
        expect(inTab(number, SvgPicture), findsOneWidget);
        expect(inTab(number, ShellStateDot), findsNothing);
      }
      expect(inTab(3, SvgPicture), findsNothing);
      expect(inTab(3, ShellStateDot), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('a long host name leaves the strip its cells', (tester) async {
      tester.view.physicalSize = const Size(411, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const named = Host(
        id: 'h1',
        name: 'UPGRADE HOST VM',
        address: '100.64.0.1',
        port: 22,
        user: 'luis',
        keyId: 'key-1',
      );
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      sessions.open(intent: testIntent(), named);
      sessions.open(intent: testIntent(), named);
      await tester.pumpWidget(
        app(
          sessions,
          home: HostShellRoute(host: named, intent: testIntent()),
        ),
      );
      await ready(tester);

      // Against the strip's own viewport and not the screen — a cell the strip has clipped is
      // still inside the phone.
      final strip = tester.getRect(find.byKey(const ValueKey('shell-strip')));
      expect(strip.right, lessThanOrEqualTo(411.0));
      for (final cell in const [
        'shell-tab-h1-1',
        'shell-tab-h1-2',
        'shell-tab-new',
      ]) {
        final rect = tester.getRect(find.byKey(ValueKey(cell)));
        expect(rect.left, greaterThanOrEqualTo(strip.left), reason: cell);
        expect(rect.right, lessThanOrEqualTo(strip.right), reason: cell);
      }

      await unmount(tester);
    });

    testWidgets('a tab opened past the edge is brought into view', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(411, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      for (var i = 0; i < 8; i++) {
        sessions.open(intent: testIntent(), rose);
      }
      await tester.pumpWidget(app(sessions));
      await ready(tester);

      // Through the store: the plus itself is off the right edge here.
      sessions.open(intent: testIntent(), rose);
      await ready(tester);

      final ninth = tester.getRect(
        find.byKey(const ValueKey('shell-tab-h1-9')),
      );
      expect(ninth.left, greaterThanOrEqualTo(0));
      expect(ninth.right, lessThanOrEqualTo(411));

      await unmount(tester);
    });
  });

  testWidgets('the plus is gone once nine tabs are open', (tester) async {
    tester.view.physicalSize = const Size(411, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    for (var i = 0; i < 9; i++) {
      sessions.open(intent: testIntent(), rose);
    }
    await tester.pumpWidget(app(sessions));
    await ready(tester);

    expect(find.byKey(const ValueKey('shell-tab-h1-9')), findsOneWidget);
    expect(find.byKey(const ValueKey('shell-tab-new')), findsNothing);
    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byKey(const ValueKey('shell-header'))).height,
      44,
    );
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('shell-tab-close'))).dx,
      lessThan(411),
    );
    final rule = find.descendant(
      of: find.byKey(const ValueKey('shell-header')),
      matching: find.byType(CellDivider),
    );
    expect(
      tester.getRect(rule.last).right,
      lessThanOrEqualTo(
        tester.getRect(find.byKey(const ValueKey('shell-tab-close'))).left,
      ),
    );

    await unmount(tester);
  });

  testWidgets('closing a live session asks before it closes', (tester) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions));
    await ready(tester);
    await openNewShell(tester);

    await tester.tap(find.byKey(const ValueKey('shell-tab-close')));
    await ready(tester);

    expect(find.text('CLOSE SHELL 2?'), findsOneWidget);
    expect(sessions.forHost(rose.id), hasLength(2));

    await tester.tap(find.text('CLOSE'));
    await ready(tester);

    expect(sessions.forHost(rose.id), hasLength(1));
    expect(sessions.forHost(rose.id).single.number, 1);

    await unmount(tester);
  });

  testWidgets('a session that already ended closes without asking', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions));
    await ready(tester);
    await openNewShell(tester);

    transport.opened.last.exit(1);
    await ready(tester);
    await tester.tap(find.text('KEEP'));
    await ready(tester);

    await tester.tap(find.byKey(const ValueKey('shell-tab-close')));
    await ready(tester);

    expect(find.text('CLOSE SHELL 2?'), findsNothing);
    expect(sessions.forHost(rose.id), hasLength(1));

    await unmount(tester);
  });

  testWidgets('closing the last tab pops the route', (tester) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions, home: const Launcher()));
    await tester.pump();

    await tester.tap(find.text('OPEN'));
    await ready(tester);
    expect(find.text('ROSE'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('shell-tab-close')));
    await ready(tester);
    await tester.tap(find.text('CLOSE'));
    await ready(tester);

    expect(sessions.forHost(rose.id), isEmpty);
    expect(find.byKey(const ValueKey('shell-sheet')), findsNothing);

    await unmount(tester);
  });

  testWidgets('closing the last tab pops a route that opened on it', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions, home: const Launcher()));
    await tester.pump();

    await tester.tap(find.text('OPEN'));
    await ready(tester);
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await ready(tester);
    expect(find.text('ROSE'), findsNothing);
    expect(sessions.forHost(rose.id), hasLength(1));

    await tester.tap(find.text('OPEN'));
    await ready(tester);
    expect(find.text('ROSE'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('shell-tab-close')));
    await ready(tester);
    await tester.tap(find.text('CLOSE'));
    await ready(tester);

    expect(sessions.forHost(rose.id), isEmpty);
    expect(find.byKey(const ValueKey('shell-sheet')), findsNothing);

    await unmount(tester);
  });

  group('the keyboard follows the tab', () {
    /// The view opens a text input connection when its focus node takes focus and closes it
    /// when the view goes; a node held with no connection under it is a keyboard that types
    /// into nothing.
    bool connected(WidgetTester tester) => tester.testTextInput.hasAnyClients;

    Future<void> type(WidgetTester tester, String text) async {
      tester.testTextInput.enterText(text);
      await ready(tester);
    }

    testWidgets('a tab opened with the keyboard up keeps it, and typing lands '
        'in the new shell', (tester) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions));
      await ready(tester);

      await tester.tap(find.byKey(const ValueKey('bar-keyboard')));
      await ready(tester);
      expect(connected(tester), isTrue);
      await type(tester, 'a');
      expect(transport.opened[0].written, 'a');

      await openNewShell(tester);
      expect(sessions.activeFor(rose.id)?.number, 2);
      expect(connected(tester), isTrue);
      await type(tester, 'b');
      expect(transport.opened[1].written, 'b');
      expect(transport.opened[0].written, 'a');

      await tester.tap(find.byKey(const ValueKey('shell-tab-h1-1')));
      await ready(tester);
      expect(connected(tester), isTrue);
      await type(tester, 'c');
      expect(transport.opened[0].written, 'ac');
      expect(transport.opened[1].written, 'b');

      await unmount(tester);
    });

    testWidgets('a tab opened with the keyboard down leaves it down', (
      tester,
    ) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions));
      await ready(tester);
      expect(connected(tester), isFalse);

      await openNewShell(tester);

      expect(connected(tester), isFalse);
      expect(
        tester
            .widget<TerminalView>(find.byType(TerminalView))
            .focusNode!
            .hasFocus,
        isFalse,
      );

      await unmount(tester);
    });

    testWidgets('the keyboard cell reaches a shell after a tab closed under '
        'it', (tester) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions));
      await ready(tester);
      await openNewShell(tester);
      await tester.tap(find.byKey(const ValueKey('bar-keyboard')));
      await ready(tester);
      expect(connected(tester), isTrue);

      transport.opened[1].exit(0);
      await ready(tester);
      expect(sessions.activeFor(rose.id)?.number, 1);

      if (!connected(tester)) {
        await tester.tap(find.byKey(const ValueKey('bar-keyboard')));
        await ready(tester);
      }
      expect(connected(tester), isTrue);
      await type(tester, 'x');
      expect(transport.opened[0].written, 'x');

      await unmount(tester);
    });

    testWidgets('every tab has its own focus node', (tester) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions));
      await ready(tester);
      final first = tester
          .widget<TerminalView>(find.byType(TerminalView))
          .focusNode;

      await openNewShell(tester);
      final second = tester
          .widget<TerminalView>(find.byType(TerminalView))
          .focusNode;

      // Two views sharing one node hand focus over without a change of focus, and a view that
      // never sees the change never opens its input.
      expect(first, isNotNull);
      expect(second, isNot(same(first)));

      await unmount(tester);
    });
  });
}
