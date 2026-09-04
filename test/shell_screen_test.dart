import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotline/data/repositories/host_repository.dart';
import 'package:hotline/features/shell/host_shell_screen.dart';
import 'package:hotline/features/shell/shell_bar.dart';
import 'package:hotline/features/shell/shell_sessions.dart';
import 'package:hotline/platform/shell/shell_connection.dart';
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

void main() {
  setUp(stubDeviceChannels);

  Widget app(ShellSessions sessions, {Widget? home}) => ProviderScope(
    overrides: [shellSessionsProvider.overrideWithValue(sessions)],
    child: MaterialApp(home: home ?? const HostShellRoute(host: _rose)),
  );

  /// The store dials off a microtask and the panels decode their headers over
  /// a few frames, so nothing is on screen after a single pump.
  Future<void> ready(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// The route holds a terminal that never settles on its own, so the tree is
  /// taken down by hand rather than left mounted at the end of a test.
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

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

    expect(find.text('SHELL REFUSED'), findsOneWidget);
    expect(find.text('shell refused'), findsOneWidget);
    expect(find.byKey(const ValueKey('shell-reason')), findsOneWidget);
    // The host answered and said no. Dialling again would get the same answer,
    // so the row is a sentence and nothing more.
    expect(find.text('RETRY'), findsNothing);
    expect(transport.opened, isEmpty);

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

  testWidgets('the plus opens a numbered tab and it becomes the active one', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions));
    await ready(tester);

    expect(find.byKey(const ValueKey('shell-tab-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('shell-tab-2')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('shell-tab-new')));
    await ready(tester);

    expect(find.byKey(const ValueKey('shell-tab-2')), findsOneWidget);
    expect(sessions.activeFor(_rose.id)?.number, 2);

    // And the first tab takes the user back to the shell it holds.
    await tester.tap(find.byKey(const ValueKey('shell-tab-1')));
    await ready(tester);
    expect(sessions.activeFor(_rose.id)?.number, 1);

    await unmount(tester);
  });

  testWidgets('the plus is gone once nine tabs are open', (tester) async {
    // A phone's width, where nine tabs are wider than the row they are in.
    tester.view.physicalSize = const Size(411, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    for (var i = 0; i < 9; i++) {
      sessions.open(_rose);
    }
    await tester.pumpWidget(app(sessions));
    await ready(tester);

    expect(find.byKey(const ValueKey('shell-tab-9')), findsOneWidget);
    expect(find.byKey(const ValueKey('shell-tab-new')), findsNothing);
    // The tabs scroll inside the header rather than running off it.
    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byKey(const ValueKey('shell-header'))).height,
      44,
    );
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('shell-tab-close'))).dx,
      lessThan(411),
    );

    await unmount(tester);
  });

  testWidgets('closing a live session asks before it closes', (tester) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions));
    await ready(tester);
    await tester.tap(find.byKey(const ValueKey('shell-tab-new')));
    await ready(tester);

    await tester.tap(find.byKey(const ValueKey('shell-tab-close')));
    await ready(tester);

    expect(find.text('CLOSE SHELL 2?'), findsOneWidget);
    expect(sessions.forHost(_rose.id), hasLength(2));

    await tester.tap(find.text('CLOSE'));
    await ready(tester);

    expect(sessions.forHost(_rose.id), hasLength(1));
    expect(sessions.forHost(_rose.id).single.number, 1);

    await unmount(tester);
  });

  testWidgets('a session that already ended closes without asking', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions));
    await ready(tester);
    await tester.tap(find.byKey(const ValueKey('shell-tab-new')));
    await ready(tester);

    transport.opened.last.exit(1);
    await ready(tester);
    await tester.tap(find.text('KEEP'));
    await ready(tester);

    await tester.tap(find.byKey(const ValueKey('shell-tab-close')));
    await ready(tester);

    expect(find.text('CLOSE SHELL 2?'), findsNothing);
    expect(sessions.forHost(_rose.id), hasLength(1));

    await unmount(tester);
  });

  testWidgets('closing the last tab pops the route', (tester) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions, home: const _Launcher()));
    await tester.pump();

    await tester.tap(find.text('OPEN'));
    await ready(tester);
    expect(find.text('ROSE'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('shell-tab-close')));
    await ready(tester);
    await tester.tap(find.text('CLOSE'));
    await ready(tester);

    expect(sessions.forHost(_rose.id), isEmpty);
    expect(find.text('ROSE'), findsNothing);
    expect(find.text('OPEN'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('a shell that exits clean takes its tab with it', (tester) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions));
    await ready(tester);
    await tester.tap(find.byKey(const ValueKey('shell-tab-new')));
    await ready(tester);
    expect(sessions.forHost(_rose.id), hasLength(2));

    transport.opened.last.exit(0);
    await ready(tester);

    // Nothing to say and nothing to read: the tab is gone and the one left is
    // the one still running.
    expect(sessions.forHost(_rose.id), hasLength(1));
    expect(sessions.forHost(_rose.id).single.number, 1);
    expect(find.textContaining('EXITED'), findsNothing);

    await unmount(tester);
  });

  testWidgets('the last shell exiting clean pops the route', (tester) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions, home: const _Launcher()));
    await tester.pump();
    await tester.tap(find.text('OPEN'));
    await ready(tester);
    expect(find.text('ROSE'), findsOneWidget);

    transport.opened.single.exit(0);
    await ready(tester);

    expect(sessions.forHost(_rose.id), isEmpty);
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
    expect(sessions.forHost(_rose.id), hasLength(1));
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
    await tester.tap(find.byKey(const ValueKey('shell-tab-new')));
    await ready(tester);

    transport.opened.last.exit(3);
    await ready(tester);
    await tester.tap(find.text('CLOSE'));
    await ready(tester);

    expect(sessions.forHost(_rose.id), hasLength(1));
    expect(sessions.forHost(_rose.id).single.number, 1);

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
    expect(sessions.forHost(_rose.id), hasLength(1));

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

    await tester.tap(find.byKey(const ValueKey('shell-tab-new')));
    await ready(tester);

    expect(find.text('SHELL 1 EXITED 3'), findsNothing);

    await unmount(tester);
  });

  testWidgets('the header takes the title the shell sets, while it is live', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    await tester.pumpWidget(app(fakeShellSessions(transport)));
    await ready(tester);

    transport.opened.single.emit('\x1b]0;luis@nyx: ~\x07');
    await ready(tester);

    expect(find.text('luis@nyx: ~'), findsOneWidget);

    // Once the shell is gone its name for itself is stale, and the state is
    // what the row is for.
    transport.opened.single.exit(1);
    await ready(tester);

    expect(find.text('luis@nyx: ~'), findsNothing);
    expect(find.text('EXITED 1'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('the keyboard cell follows the keyboard the system shows, not '
      'the focus', (tester) async {
    addTearDown(tester.view.reset);
    final transport = FakeShellTransport();
    await tester.pumpWidget(app(fakeShellSessions(transport)));
    await ready(tester);

    bool focused() => tester
        .widget<TerminalView>(find.byType(TerminalView))
        .focusNode!
        .hasFocus;
    bool armed() => tester.widget<ShellBar>(find.byType(ShellBar)).keyboardOpen;

    expect(focused(), isFalse);
    expect(armed(), isFalse);

    await tester.tap(find.byKey(const ValueKey('bar-keyboard')));
    await ready(tester);
    expect(focused(), isTrue);
    // The focus is on the terminal but no keyboard has come up yet, and the
    // cell says what is on screen.
    expect(armed(), isFalse);

    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await ready(tester);
    expect(armed(), isTrue);

    // The system taking the keyboard away dims the cell even though the view
    // keeps the focus, so the next tap asks for a keyboard rather than
    // dismissing one that is not there.
    tester.view.viewInsets = FakeViewPadding.zero;
    await ready(tester);
    expect(focused(), isTrue);
    expect(armed(), isFalse);

    // And with the keyboard up the cell puts it away.
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await ready(tester);
    await tester.tap(find.byKey(const ValueKey('bar-keyboard')));
    await ready(tester);
    expect(focused(), isFalse);

    await unmount(tester);
  });

  testWidgets('the paste cell puts what is on the clipboard on the wire', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    await tester.pumpWidget(app(fakeShellSessions(transport)));
    await ready(tester);

    stubClipboard('uname -a');
    await tester.tap(find.byKey(const ValueKey('bar-PASTE')));
    await ready(tester);

    expect(transport.opened.single.written, 'uname -a');

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

/// A page to pop back to, so the last tab closing has somewhere to land.
class _Launcher extends StatelessWidget {
  const _Launcher();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: GestureDetector(
          onTap: () => openHostShell(context, _rose),
          child: const Text('OPEN'),
        ),
      ),
    );
  }
}
