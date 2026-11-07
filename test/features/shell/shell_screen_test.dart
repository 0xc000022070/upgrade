import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/design/components/sheet_route.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:upgrade/application/agents/agent_input.dart';
import 'package:upgrade/application/agents/agents.dart';
import 'package:upgrade/application/agents/agent_kind.dart';
import 'package:upgrade/features/shell/host_shell_screen.dart';
import 'package:upgrade/features/shell/session/shell_sessions.dart';
import 'package:upgrade/platform/shell/shell_connection.dart';
import 'package:upgrade/platform/herdr/herdr_client.dart';
import 'package:flterm/flterm.dart';

import '../../support/fake_shell.dart';
import '../../support/platform_channels.dart';
import '../../support/reasons.dart';
import '../../support/shell_route.dart';

/// A double tap on the tab on screen, then the sheet's own transition and no more: a tab
/// on a reconnect schedule moves on under a longer pump.
Future<void> openInfo(WidgetTester tester) async {
  final tab = find.byKey(const ValueKey('shell-tab-active'));
  await tester.tap(tab);
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tap(tab);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  setUp(stubDeviceChannels);

  testWidgets('terminal keeps pinch without a font settings control', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    await tester.pumpWidget(app(fakeShellSessions(transport)));
    await ready(tester);
    expect(find.byKey(const ValueKey('shell-text-size')), findsNothing);
    expect(find.text('Aa'), findsNothing);
    expect(find.byKey(const ValueKey('shell-pinch')), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('a voice draft sends from the shell bar without the keyboard', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions));
    await ready(tester);
    final session = sessions.activeFor(pine.id)!;

    expect(find.byKey(const ValueKey('bar-send')), findsNothing);
    session.voiceDraft = (agent: const CodexKind(), text: 'check this');
    session.changed();
    await tester.pump();
    expect(find.byKey(const ValueKey('bar-send')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('bar-send')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(session.voiceDraft, isNull);
    expect(find.byKey(const ValueKey('bar-send')), findsNothing);
    expect(transport.opened.single.writes.last, [0x0d]);
    await unmount(tester);
  });

  for (final (agent, process) in [
    ('Codex', 'codex\t/nix/store/codex/bin/.codex-wrapped\t\n'),
    ('Claude', 'claude\t/nix/store/claude/bin/.claude-wrapped\t\n'),
  ]) {
    testWidgets('typed input in $agent offers SEND after a pause', (
      tester,
    ) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions));
      await ready(tester);
      final session = sessions.activeFor(pine.id)!;
      final connection = transport.opened.single..answerWith(process);

      session.terminal.sendText('check this');
      await tester.pump(agentInputPause);
      await tester.pump();
      expect(find.byKey(const ValueKey('bar-send')), findsOneWidget);

      final before = connection.writes.length;
      await tester.tap(find.byKey(const ValueKey('bar-send')));
      await tester.pump();
      expect(connection.writes.length, before + 1);
      expect(connection.writes.last, [0x0d]);
      expect(find.byKey(const ValueKey('bar-send')), findsNothing);
      await unmount(tester);
    });
  }

  testWidgets('Engine foreground context offers SEND without an SSH probe', (
    tester,
  ) async {
    final transport = FakeShellTransport()..transport = ShellTransport.engine;
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions));
    await ready(tester);
    final session = sessions.activeFor(pine.id)!;
    final connection = transport.opened.single;
    connection.emitForeground('codex\t/usr/bin/codex\t\n');
    await tester.pump();
    expect(session.engineForegroundKnown, isTrue);

    session.terminal.sendText('check this');
    await tester.pump(agentInputPause);
    await tester.pump();
    expect(find.byKey(const ValueKey('bar-send')), findsOneWidget);
    expect(connection.timedProbes, isEmpty);

    connection.emitForeground('');
    await tester.pump();
    await tester.pump();
    expect(session.engineForegroundKnown, isTrue);
    expect(session.engineAgent, isNull);
    expect(find.byKey(const ValueKey('bar-send')), findsNothing);
    session.clearAgentInput();
    await unmount(tester);
  });

  testWidgets('older Engine falls back to the existing SSH host', (
    tester,
  ) async {
    final transport = FakeShellTransport()..transport = ShellTransport.engine;
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions));
    await ready(tester);
    final session = sessions.activeFor(pine.id)!;
    final connection = transport.opened.single
      ..answerWith('codex\t/usr/bin/codex\t\n');

    session.terminal.sendText('check this');
    await tester.pump(agentInputPause);
    await tester.pump();
    expect(find.byKey(const ValueKey('bar-send')), findsOneWidget);
    expect(connection.timedProbes, hasLength(1));
    await unmount(tester);
  });

  testWidgets('Engine keeps foreground context across a transient rehome', (
    tester,
  ) async {
    final transport = FakeShellTransport()..transport = ShellTransport.engine;
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions));
    await ready(tester);
    final session = sessions.activeFor(pine.id)!;
    final connection = transport.opened.single;
    connection.emitForeground('codex\t/usr/bin/codex\t\n');
    await tester.pump();
    connection.setHealth(ShellConnectionHealth.reconnecting);
    await tester.pump();
    connection.setHealth(ShellConnectionHealth.connected);
    await tester.pump();
    expect(session.engineForegroundKnown, isTrue);

    session.terminal.sendText('check this');
    await tester.pump(agentInputPause);
    await tester.pump();
    expect(find.byKey(const ValueKey('bar-send')), findsOneWidget);
    expect(connection.timedProbes, isEmpty);
    await unmount(tester);
  });

  testWidgets('a Herdr pane does not start agent polling for SEND', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions));
    await ready(tester);
    final session = sessions.activeFor(pine.id)!
      ..pane = (session: 'development', pane: 'p1');
    final container = ProviderScope.containerOf(
      tester.element(find.byType(HostShellRoute)),
    );
    expect(container.exists(agentsFeedProvider), isFalse);

    session.terminal.sendText('check this');
    await tester.pump(agentInputPause);
    await tester.pump();
    expect(find.byKey(const ValueKey('bar-send')), findsNothing);
    expect(container.exists(agentsFeedProvider), isFalse);
    expect(transport.opened.single.timedProbes, isEmpty);
    await unmount(tester);
  });

  testWidgets('a pane rechecks its live agent before SEND', (tester) async {
    const pane = (session: 'lab', pane: 'wQ:p2');
    final response = File('test/fixtures/herdr_agent_list.json')
        .readAsStringSync();
    final agents = HerdrClient.parseCliAgentList(
      response,
      session: pane.session,
    );
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(
      app(
        sessions,
        overrides: [
          agentsFeedProvider.overrideWith(
            (ref) => Stream.value(
              AgentPanelState([
                HostOutcome(
                  host: pine,
                  kind: AgentOutcomeKind.snapshot,
                  agents: agents,
                  lastGoodAt: DateTime.now(),
                ),
              ]),
            ),
          ),
        ],
      ),
    );
    await ready(tester);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(HostShellRoute)),
    );
    container.listen(agentsFeedProvider, (_, _) {});
    await tester.pump();
    final session = sessions.activeFor(pine.id)!..pane = pane;
    final connection = transport.opened.single
      ..answerWith('{"result":{"type":"agent_list","agents":[]}}');

    session.terminal.sendText('check this');
    await tester.pump(agentInputPause);
    await tester.pump();
    expect(find.byKey(const ValueKey('bar-send')), findsOneWidget);
    final before = connection.writes.length;
    await tester.tap(find.byKey(const ValueKey('bar-send')));
    await tester.pump();
    expect(connection.writes.length, before);
    expect(connection.timedProbes.last, HerdrCommands.agents(pane.session));
    expect(find.byKey(const ValueKey('bar-send')), findsNothing);

    connection.answerWith(response);
    session.terminal.sendText('check again');
    await tester.pump(agentInputPause);
    await tester.pump();
    expect(find.byKey(const ValueKey('bar-send')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('bar-send')));
    await tester.pump();
    expect(connection.writes.last, [0x0d]);
    expect(transport.opened, hasLength(1));
    await unmount(tester);
  });

  testWidgets('unknown or erased input offers no SEND', (tester) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions));
    await ready(tester);
    final session = sessions.activeFor(pine.id)!;
    final connection = transport.opened.single;

    session.terminal.sendText('ls');
    await tester.pump(agentInputPause);
    await tester.pump();
    expect(find.byKey(const ValueKey('bar-send')), findsNothing);

    sessions.send(session, Uint8List.fromList([0x0d]));
    connection.answerWith('codex\t/nix/store/codex/bin/.codex-wrapped\t\n');
    session.terminal.sendText('x');
    sessions.send(session, Uint8List.fromList([0x7f]));
    await tester.pump(agentInputPause);
    await tester.pump();
    expect(find.byKey(const ValueKey('bar-send')), findsNothing);
    await unmount(tester);
  });

  testWidgets('SEND refuses a tab whose agent exited', (tester) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions));
    await ready(tester);
    final session = sessions.activeFor(pine.id)!;
    final connection = transport.opened.single
      ..answerWith('codex\t/nix/store/codex/bin/.codex-wrapped\t\n');

    session.terminal.sendText('check this');
    await tester.pump(agentInputPause);
    await tester.pump();
    expect(find.byKey(const ValueKey('bar-send')), findsOneWidget);

    final before = connection.writes.length;
    connection.answerWith('');
    await tester.tap(find.byKey(const ValueKey('bar-send')));
    await tester.pump();
    expect(connection.writes.length, before);
    expect(find.byKey(const ValueKey('bar-send')), findsNothing);
    await unmount(tester);
  });

  testWidgets('SEND does not submit input typed during its agent check', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions));
    await ready(tester);
    final session = sessions.activeFor(pine.id)!;
    final connection = transport.opened.single
      ..answerWith('codex\t/nix/store/codex/bin/.codex-wrapped\t\n');

    session.terminal.sendText('first');
    await tester.pump(agentInputPause);
    await tester.pump();
    final delayed = Completer<ExecResult?>();
    connection.holdTimedProbe = delayed;
    await tester.tap(find.byKey(const ValueKey('bar-send')));
    await tester.pump();

    sessions.send(session, Uint8List.fromList([0x0d]));
    session.terminal.sendText('second');
    final writes = connection.writes.length;
    delayed.complete(
      ExecResult(
        exitCode: 0,
        stdout: Uint8List.fromList(
          'codex\t/nix/store/codex/bin/.codex-wrapped\t\n'.codeUnits,
        ),
        stderr: Uint8List(0),
      ),
    );
    connection.holdTimedProbe = null;
    await tester.pump();

    expect(connection.writes.length, writes);
    expect(session.agentInput.hasText, isTrue);
    session.clearAgentInput();
    await unmount(tester);
  });

  testWidgets('later input waits for an in-flight agent probe', (tester) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions));
    await ready(tester);
    final session = sessions.activeFor(pine.id)!;
    final connection = transport.opened.single;
    final delayed = Completer<ExecResult?>();
    connection.holdTimedProbe = delayed;

    session.terminal.sendText('first');
    await tester.pump(agentInputPause);
    expect(connection.timedProbes.length, 1);
    session.terminal.sendText('second');
    await tester.pump(agentInputPause);
    expect(connection.timedProbes.length, 1);

    connection.holdTimedProbe = null;
    delayed.complete(
      ExecResult(
        exitCode: 0,
        stdout: Uint8List.fromList(
          'codex\t/nix/store/codex/bin/.codex-wrapped\t\n'.codeUnits,
        ),
        stderr: Uint8List(0),
      ),
    );
    await tester.pump();
    expect(connection.timedProbes.length, 2);
    await unmount(tester);
  });

  testWidgets('a shell that has not answered is marked, and the mark says '
      'CONNECTING', (tester) async {
    final transport = FakeShellTransport()..stall = true;
    await tester.pumpWidget(app(fakeShellSessions(transport)));
    await ready(tester);

    expect(find.text('PINE'), findsOneWidget);
    expect(find.text('CONNECTING'), findsNothing);
    expect(find.byKey(const ValueKey('shell-reason')), findsNothing);
    expect(find.text('RETRY'), findsNothing);

    await openInfo(tester);

    expect(find.text('CONNECTING'), findsOneWidget);
    expect(find.text('—'), findsOneWidget);
    expect(find.text('STOP'), findsNothing);

    await unmount(tester);
  });

  testWidgets('a live session is one header row and no crumb', (tester) async {
    final transport = FakeShellTransport();
    await tester.pumpWidget(app(fakeShellSessions(transport)));
    await ready(tester);

    expect(find.text('PINE'), findsOneWidget);
    expect(find.textContaining('SSH'), findsNothing);
    expect(find.textContaining('/'), findsNothing);
    expect(find.text('CONNECTING'), findsNothing);
    expect(find.text('RETRY'), findsNothing);
    expect(
      tester.getSize(find.byKey(const ValueKey('shell-header'))).height,
      44,
    );
    expect(find.byKey(const ValueKey('shell-reason')), findsNothing);

    await unmount(tester);
  });

  testWidgets('an exit becomes EXITED in the sheet and nothing else', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions));
    await ready(tester);

    transport.opened.single.exit(130);
    await ready(tester);
    await tester.tap(find.text('KEEP'));
    await ready(tester);

    expect(find.text('EXITED 130'), findsNothing);

    await openInfo(tester);
    expect(find.text('EXITED 130'), findsOneWidget);
    expect(find.text('RETRY'), findsNothing);
    expect(find.text('STOP'), findsNothing);
    expect(transport.opened, hasLength(1));

    await tester.tapAt(Offset.zero);
    await ready(tester);
    expect(find.byKey(const ValueKey('shell-reason')), findsNothing);
    expect(
      tester.getSize(find.byKey(const ValueKey('shell-header'))).height,
      44,
    );

    await unmount(tester);
  });

  testWidgets('a refused shell draws its reason line, and only its readout '
      'dials it again', (tester) async {
    final transport = FakeShellTransport()
      ..refuse = const ShellFailure(ShellFailureKind.shellRefused);
    await tester.pumpWidget(app(fakeShellSessions(transport)));
    await ready(tester);

    expect(find.text('DISCONNECTED'), findsNothing);
    expect(find.text('shell refused'), findsOneWidget);
    expect(find.byKey(const ValueKey('shell-reason')), findsOneWidget);
    expect(find.text('RETRY'), findsNothing);
    expect(transport.opened, isEmpty);

    await openInfo(tester);
    expect(find.text('FAILED'), findsOneWidget);
    expect(find.text('STOP'), findsNothing);
    expect(find.byKey(const ValueKey('shell-info-reconnect')), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('the reason row opens on what the transport said', (
    tester,
  ) async {
    String? copied;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        });

    final transport = FakeShellTransport()
      ..refuse = const ShellFailure(
        ShellFailureKind.shellRefused,
        detail: 'SSHChannelRequestError: pty-req denied',
      );
    await tester.pumpWidget(app(fakeShellSessions(transport)));
    await ready(tester);

    expect(find.text('shell refused'), findsOneWidget);
    expect(find.textContaining('pty-req denied'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('shell-reason')));
    await ready(tester);

    expect(find.text('SSHChannelRequestError: pty-req denied'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('shell-detail-copy')));
    await ready(tester);

    expect(copied, 'SSHChannelRequestError: pty-req denied');

    await tester.tap(find.byKey(const ValueKey('shell-reason')));
    await ready(tester);

    expect(find.textContaining('pty-req denied'), findsNothing);

    await unmount(tester);
  });

  testWidgets('a failure with nothing more to say is not a button', (
    tester,
  ) async {
    final transport = FakeShellTransport()
      ..refuse = const ShellFailure(ShellFailureKind.shellRefused);
    await tester.pumpWidget(app(fakeShellSessions(transport)));
    await ready(tester);

    final closed = tester.getSize(find.byKey(const ValueKey('shell-reason')));
    await tester.tap(find.byKey(const ValueKey('shell-reason')));
    await ready(tester);

    expect(tester.getSize(find.byKey(const ValueKey('shell-reason'))), closed);
    expect(find.byKey(const ValueKey('shell-detail-copy')), findsNothing);

    await unmount(tester);
  });

  testWidgets('a lost link reads RECONNECTING in the sheet, with STOP under '
      'it and the cause under the header', (tester) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions));
    await ready(tester);

    transport.opened.single.drop();
    await ready(tester);

    expect(find.textContaining('RECONNECTING'), findsNothing);
    expect(find.byKey(const ValueKey('shell-reason')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('shell-reason')));
    await tester.pump();
    expect(find.textContaining('link lost'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('shell-reason')));
    await tester.pump();

    await openInfo(tester);

    expect(find.text('RECONNECTING 1/6'), findsOneWidget);
    expect(find.text('RETRY'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('shell-info-stop')));
    await ready(tester);

    expect(find.textContaining('RECONNECTING'), findsNothing);
    expect(find.byKey(const ValueKey('shell-reason')), findsOneWidget);
    expect(transport.opened, hasLength(1));

    await unmount(tester);
  });

  testWidgets('a single tap on the tab opens nothing, and a double tap reads '
      'LIVE with nothing to press', (tester) async {
    final transport = FakeShellTransport();
    await tester.pumpWidget(app(fakeShellSessions(transport)));
    await ready(tester);

    await tester.tap(find.byKey(const ValueKey('shell-tab-active')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const ValueKey('shell-tab-active')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('shell-info-state')), findsNothing);

    await openInfo(tester);
    expect(find.text('LIVE'), findsOneWidget);
    expect(find.text('SSH'), findsOneWidget);
    expect(find.byKey(const ValueKey('shell-info-reconnect')), findsNothing);
    expect(find.byKey(const ValueKey('shell-info-stop')), findsNothing);

    await unmount(tester);
  });

  testWidgets('a stopped tab reads FAILED, and RECONNECT dials it again', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions));
    await ready(tester);

    transport.opened.single.drop();
    await ready(tester);
    await openInfo(tester);
    await tester.tap(find.byKey(const ValueKey('shell-info-stop')));
    await ready(tester);

    await openInfo(tester);
    expect(find.text('FAILED'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('shell-info-reconnect')));
    await ready(tester);

    expect(transport.opened, hasLength(2));

    await unmount(tester);
  });

  testWidgets('a host that stopped being dialled reads RECONNECT FAILED with '
      'its reason under it, and RECONNECT stays', (tester) async {
    final transport = FakeShellTransport()..transport = ShellTransport.mosh;
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions));
    await ready(tester);
    final connection = transport.opened.single
      ..setHealth(ShellConnectionHealth.connected)
      ..setControlDown(true);
    await ready(tester);

    await openInfo(tester);
    expect(find.text('STALE · HOST RECONNECTING'), findsOneWidget);
    expect(find.byKey(const ValueKey('shell-reason')), findsNothing);

    connection.setControlGaveUp(const SocketException('Connection refused'));
    await ready(tester);

    expect(find.text('STALE · RECONNECT FAILED'), findsOneWidget);
    expect(
      find.text(ShellFailureKind.unreachable.line.on(pine.name)),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('shell-reason')));
    await tester.pump();
    expect(find.textContaining('connection refused'), findsOneWidget);
    expect(find.byKey(const ValueKey('shell-detail-copy')), findsOneWidget);
    expect(find.byKey(const ValueKey('shell-info-reconnect')), findsOneWidget);

    connection.setControlDown(false);
    await ready(tester);
    expect(find.textContaining('STALE'), findsNothing);
    expect(find.byKey(const ValueKey('shell-reason')), findsNothing);

    await unmount(tester);
  });

  testWidgets('a spent schedule reads WAITING with STOP in the sheet, '
      'FAILED after it, and a reason under the header', (tester) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions));
    await ready(tester);

    transport.refuse = const ShellFailure(ShellFailureKind.unreachable);
    transport.opened.single.drop();
    await ready(tester);
    for (final delay in shellReconnectDelays) {
      await tester.pump(delay);
      await ready(tester);
    }

    expect(find.byKey(const ValueKey('shell-reason')), findsOneWidget);

    await openInfo(tester);
    expect(find.text('WAITING'), findsOneWidget);
    expect(find.textContaining('RECONNECTING'), findsNothing);
    expect(find.byKey(const ValueKey('shell-info-stop')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('shell-info-stop')));
    await ready(tester);

    await openInfo(tester);
    expect(find.text('FAILED'), findsOneWidget);
    expect(find.byKey(const ValueKey('shell-reason')), findsNWidgets(2));

    await unmount(tester);
  });

  testWidgets('a shell that exits clean takes its tab with it', (tester) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions));
    await ready(tester);
    await openNewShell(tester);
    expect(sessions.forHost(pine.id), hasLength(2));

    transport.opened.last.exit(0);
    await ready(tester);

    expect(sessions.forHost(pine.id), hasLength(1));
    expect(sessions.forHost(pine.id).single.number, 1);
    expect(find.textContaining('EXITED'), findsNothing);

    await unmount(tester);
  });

  testWidgets('the last shell exiting clean pops the route', (tester) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions, home: const Launcher()));
    await tester.pump();
    await tester.tap(find.text('OPEN'));
    await ready(tester);
    expect(find.text('PINE'), findsOneWidget);

    transport.opened.single.exit(0);
    await ready(tester);

    expect(sessions.forHost(pine.id), isEmpty);
    expect(find.text('PINE'), findsNothing);
    expect(find.text('OPEN'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('the last shell exiting under another route takes only its own', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions, home: const Launcher()));
    await tester.pump();
    await tester.tap(find.text('OPEN'));
    await ready(tester);
    unawaited(
      Navigator.of(tester.element(find.text('PINE').first))
          .push(MaterialPageRoute<void>(builder: (_) => const Text('ON TOP'))),
    );
    await ready(tester);

    transport.opened.single.exit(0);
    await ready(tester);
    expect(sessions.forHost(pine.id), isEmpty);
    expect(find.text('ON TOP'), findsOneWidget);

    Navigator.of(tester.element(find.text('ON TOP'))).pop();
    await ready(tester);
    expect(find.text('PINE'), findsNothing);
    expect(find.text('OPEN'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('the last shell exiting takes the sheet over it along', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions, home: const Launcher()));
    await tester.pump();
    await tester.tap(find.text('OPEN'));
    await ready(tester);
    unawaited(
      showSheetRoute<void>(
        tester.element(find.text('PINE').first),
        title: 'SHEET',
        child: const Text('IN A SHEET'),
      ),
    );
    await ready(tester);

    transport.opened.single.exit(0);
    await ready(tester);

    expect(find.text('IN A SHEET'), findsNothing);
    expect(find.text('PINE'), findsNothing);
    expect(find.text('OPEN'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('a shell that exits on anything else says so in a sheet', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions));
    await ready(tester);

    transport.opened.single.exit(3);
    await ready(tester);

    expect(find.text('SHELL 1 EXITED 3'), findsOneWidget);
    await tester.tap(find.text('KEEP'));
    await ready(tester);

    expect(find.text('SHELL 1 EXITED 3'), findsNothing);
    expect(sessions.forHost(pine.id), hasLength(1));
    expect(find.text('EXITED 3'), findsNothing);

    await openInfo(tester);
    expect(find.text('EXITED 3'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('CLOSE on the sheet drops the tab the shell died in', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions));
    await ready(tester);
    await openNewShell(tester);

    transport.opened.last.exit(3);
    await ready(tester);
    await tester.tap(find.text('CLOSE'));
    await ready(tester);

    expect(sessions.forHost(pine.id), hasLength(1));
    expect(sessions.forHost(pine.id).single.number, 1);

    await unmount(tester);
  });

  testWidgets('a shell that lost its connection has no code and says so', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions));
    await ready(tester);

    await transport.opened.single.close(UserClosed(testIntent()));
    await ready(tester);

    expect(find.text('SHELL 1 EXITED —'), findsOneWidget);

    await tester.tap(find.text('KEEP'));
    await ready(tester);
    expect(sessions.forHost(pine.id), hasLength(1));

    await unmount(tester);
  });

  testWidgets('a bad exit is put up once, not on every notify', (tester) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions));
    await ready(tester);

    transport.opened.first.exit(3);
    await ready(tester);
    await tester.tap(find.text('KEEP'));
    await ready(tester);

    await openNewShell(tester);

    expect(find.text('SHELL 1 EXITED 3'), findsNothing);

    await unmount(tester);
  });

  testWidgets('the title the shell sets reaches the tab and nowhere else', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    await tester.pumpWidget(app(fakeShellSessions(transport)));
    await ready(tester);

    transport.opened.single.emit('\x1b]0;luis@oak: ~\x07');
    await ready(tester);

    expect(find.text('~'), findsOneWidget);
    expect(find.text('luis@oak: ~'), findsNothing);

    transport.opened.single.exit(1);
    await ready(tester);
    await tester.tap(find.text('KEEP'));
    await ready(tester);

    expect(find.text('EXITED 1'), findsNothing);

    await openInfo(tester);
    expect(find.text('EXITED 1'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('a tap on the terminal is a look, not a call for the keyboard', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions));
    await ready(tester);

    bool raised() => tester.testTextInput.isVisible;

    await tester.tap(find.byType(TerminalView));
    await ready(tester);
    expect(raised(), isFalse);

    transport.opened.single.emit('selectme\r\n');
    await ready(tester);
    final session = sessions.activeFor(pine.id)!;
    session.terminal.selectRange(
      start: const Position(row: 0, col: 0),
      end: const Position(row: 0, col: 7),
    );
    await tester.pump();
    expect(session.terminal.hasSelection, isTrue);

    await tester.tap(find.byType(TerminalView));
    await ready(tester);
    expect(session.terminal.hasSelection, isFalse);
    expect(raised(), isFalse);

    await tester.tap(find.byKey(const ValueKey('bar-keyboard')));
    await ready(tester);
    expect(raised(), isTrue);

    await unmount(tester);
  });

  testWidgets('nothing on the route offers SUPER', (tester) async {
    final transport = FakeShellTransport();
    await tester.pumpWidget(app(fakeShellSessions(transport)));
    await ready(tester);

    expect(find.text('SUPER'), findsNothing);
    expect(find.byKey(const ValueKey('key-SUPER')), findsNothing);
    expect(find.text('CTRL'), findsOneWidget);

    await unmount(tester);
  });
}
