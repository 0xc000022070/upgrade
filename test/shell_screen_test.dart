import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/features/shell/shell_sessions.dart';
import 'package:dazzle/platform/shell/shell_connection.dart';
import 'package:xterm/xterm.dart';

import 'support/fake_shell.dart';
import 'support/platform_channels.dart';
import 'support/shell_route.dart';

void main() {
  setUp(stubDeviceChannels);

  testWidgets('the header says CONNECTING until the shell answers', (
    tester,
  ) async {
    final transport = FakeShellTransport()..stall = true;
    await tester.pumpWidget(app(fakeShellSessions(transport)));
    await ready(tester);

    expect(find.text('ROSE'), findsOneWidget);
    expect(find.text('CONNECTING'), findsOneWidget);
    // Nothing has gone wrong yet, so nothing is taken from the terminal.
    expect(find.byKey(const ValueKey('shell-reason')), findsNothing);
    expect(find.text('RETRY'), findsNothing);

    await unmount(tester);
  });

  testWidgets('a live session is one header row and no crumb', (tester) async {
    final transport = FakeShellTransport();
    await tester.pumpWidget(app(fakeShellSessions(transport)));
    await ready(tester);

    expect(find.text('ROSE'), findsOneWidget);
    expect(find.text('CONNECTED · SSH'), findsOneWidget);
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

  testWidgets('an exit becomes EXITED in the header and nothing else', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions));
    await ready(tester);

    transport.opened.single.exit(130);
    await ready(tester);

    expect(find.text('EXITED 130'), findsOneWidget);
    // A shell the user walked out of is not a link that broke, so it is not
    // dialled again and there is nothing to press: another shell is another
    // tab.
    expect(find.text('RETRY'), findsNothing);
    expect(find.text('STOP'), findsNothing);
    expect(transport.opened, hasLength(1));
    // A shell that ran and stopped is not a failure, so it costs the terminal
    // no row.
    expect(find.byKey(const ValueKey('shell-reason')), findsNothing);
    expect(
      tester.getSize(find.byKey(const ValueKey('shell-header'))).height,
      44,
    );

    await unmount(tester);
  });

  testWidgets('a refused shell draws its reason line and no way back', (
    tester,
  ) async {
    final transport = FakeShellTransport()
      ..refuse = const ShellFailure(ShellFailureKind.shellRefused);
    await tester.pumpWidget(app(fakeShellSessions(transport)));
    await ready(tester);

    expect(find.text('DISCONNECTED'), findsOneWidget);
    expect(find.text('shell refused'), findsOneWidget);
    expect(find.byKey(const ValueKey('shell-reason')), findsOneWidget);
    // The host answered and said no. Dialling again would get the same answer,
    // so the row is a sentence and nothing more.
    expect(find.text('RETRY'), findsNothing);
    expect(transport.opened, isEmpty);

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

    // Closed: one line, the words the header has room for.
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

  testWidgets('a lost link reads RECONNECTING with STOP beside it', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions));
    await ready(tester);

    transport.opened.single.drop();
    await ready(tester);

    // The count, so a wait that is getting long says so, and the one control:
    // the dialling is the app's, the giving up is the user's.
    expect(find.text('RECONNECTING 1/6'), findsOneWidget);
    expect(find.text('RETRY'), findsNothing);
    expect(find.byKey(const ValueKey('shell-reason')), findsNothing);

    await tester.tap(find.text('STOP'));
    await ready(tester);

    expect(find.textContaining('RECONNECTING'), findsNothing);
    expect(find.byKey(const ValueKey('shell-reason')), findsOneWidget);
    expect(transport.opened, hasLength(1));

    await unmount(tester);
  });

  testWidgets('a spent schedule reads DISCONNECTED with STOP and a reason', (
    tester,
  ) async {
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

    // One word, muted, where the count was, and no spinner: the app is not
    // working, it is waiting. The row underneath says what the last dial hit,
    // and `STOP` is the same way out it offers mid-schedule.
    expect(find.text('DISCONNECTED'), findsOneWidget);
    expect(find.textContaining('RECONNECTING'), findsNothing);
    expect(find.byKey(const ValueKey('shell-reason')), findsOneWidget);
    expect(find.text('STOP'), findsOneWidget);

    await tester.tap(find.text('STOP'));
    await ready(tester);

    expect(find.text('DISCONNECTED'), findsOneWidget);
    expect(find.byKey(const ValueKey('shell-reason')), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('a shell that exits clean takes its tab with it', (tester) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions));
    await ready(tester);
    await openNewShell(tester);
    expect(sessions.forHost(rose.id), hasLength(2));

    transport.opened.last.exit(0);
    await ready(tester);

    // Nothing to say and nothing to read: the tab is gone and the one left is
    // the one still running.
    expect(sessions.forHost(rose.id), hasLength(1));
    expect(sessions.forHost(rose.id).single.number, 1);
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
    expect(find.text('ROSE'), findsOneWidget);

    transport.opened.single.exit(0);
    await ready(tester);

    expect(sessions.forHost(rose.id), isEmpty);
    expect(find.text('ROSE'), findsNothing);
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

    // The output is the only place the error is written down, so KEEP is the
    // tab staying exactly as the shell left it.
    expect(find.text('SHELL 1 EXITED 3'), findsNothing);
    expect(sessions.forHost(rose.id), hasLength(1));
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

    expect(sessions.forHost(rose.id), hasLength(1));
    expect(sessions.forHost(rose.id).single.number, 1);

    await unmount(tester);
  });

  testWidgets('a shell that lost its connection has no code and says so', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions));
    await ready(tester);

    await transport.opened.single.close();
    await ready(tester);

    expect(find.text('SHELL 1 EXITED —'), findsOneWidget);

    await tester.tap(find.text('KEEP'));
    await ready(tester);
    expect(sessions.forHost(rose.id), hasLength(1));

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

    transport.opened.single.emit('\x1b]0;luis@nyx: ~\x07');
    await ready(tester);

    expect(find.text('~'), findsOneWidget);
    expect(find.text('luis@nyx: ~'), findsNothing);

    // Once the shell is gone the state is what the row is for.
    transport.opened.single.exit(1);
    await ready(tester);

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

    bool focused() => tester
        .widget<TerminalView>(find.byType(TerminalView))
        .focusNode!
        .hasFocus;

    await tester.tap(find.byType(TerminalView));
    await ready(tester);
    expect(focused(), isFalse);
    expect(tester.testTextInput.hasAnyClients, isFalse);

    // The tap still does the one thing it is for: dropping a selection.
    transport.opened.single.emit('selectme\r\n');
    await ready(tester);
    final session = sessions.activeFor(rose.id)!;
    final buffer = session.terminal.buffer;
    session.controller.setSelection(
      buffer.createAnchor(0, 0),
      buffer.createAnchor(8, 0),
    );
    await tester.pump();
    expect(session.controller.selection, isNotNull);

    await tester.tap(find.byType(TerminalView));
    await ready(tester);
    expect(session.controller.selection, isNull);
    expect(focused(), isFalse);

    // The bar is still the way in.
    await tester.tap(find.byKey(const ValueKey('bar-keyboard')));
    await ready(tester);
    expect(focused(), isTrue);
    expect(tester.testTextInput.hasAnyClients, isTrue);

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
