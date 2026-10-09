import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/design/components/action_block.dart';
import 'package:upgrade/features/shell/host_shell_screen.dart';
import 'package:upgrade/features/shell/shell_bar.dart';
import 'package:upgrade/platform/shell/remote_shell.dart';
import 'package:upgrade/platform/shell/shell_connection.dart';
import 'package:flterm/flterm.dart';

import 'support/fake_shell.dart';
import 'support/platform_channels.dart';
import 'support/reasons.dart';
import 'support/shell_route.dart';

void main() {
  setUp(stubDeviceChannels);

  testWidgets('CTRL dragged down carries the next two keys, and the label '
      'counts them off', (tester) async {
    final transport = FakeShellTransport();
    await tester.pumpWidget(app(fakeShellSessions(transport)));
    await ready(tester);
    final connection = transport.opened.single;
    final terminal = tester
        .widget<TerminalView>(find.byType(TerminalView))
        .controller;

    await tester.drag(
      find.byKey(const ValueKey('bar-CTRL')),
      const Offset(0, 40),
    );
    await ready(tester);
    expect(find.text('CTRL(x2)'), findsOneWidget);

    terminal.sendText('d');
    await ready(tester);
    expect(find.text('CTRL(x2)'), findsNothing);
    expect(find.text('CTRL'), findsOneWidget);

    terminal.sendText('d');
    await ready(tester);
    terminal.sendText('d');

    expect(connection.writes, [
      [0x04],
      [0x04],
      [0x64],
    ]);

    await ready(tester);
    await unmount(tester);
  });

  testWidgets('a bar key spends one of the count and the rest of it stands', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    await tester.pumpWidget(app(fakeShellSessions(transport)));
    await ready(tester);
    final connection = transport.opened.single;

    await tester.drag(
      find.byKey(const ValueKey('bar-ALT')),
      const Offset(0, 40),
    );
    await ready(tester);

    await tester.tap(find.byKey(const ValueKey('bar-LEFT')));
    await ready(tester);
    expect(find.text('ALT'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('bar-LEFT')));
    await ready(tester);
    expect(find.text('ALT'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('bar-LEFT')));

    expect(connection.writes, [
      [0x1b, 0x1b, 0x5b, 0x44],
      [0x1b, 0x1b, 0x5b, 0x44],
      [0x1b, 0x5b, 0x44],
    ]);

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
    expect(armed(), isFalse);

    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await ready(tester);
    expect(armed(), isTrue);

    tester.view.viewInsets = FakeViewPadding.zero;
    await ready(tester);
    expect(focused(), isTrue);
    expect(armed(), isFalse);

    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await ready(tester);
    await tester.tap(find.byKey(const ValueKey('bar-keyboard')));
    await ready(tester);
    expect(focused(), isFalse);

    await unmount(tester);
  });

  testWidgets('the keyboard cell recovers an inset with no keyboard under it', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    final transport = FakeShellTransport();
    await tester.pumpWidget(app(fakeShellSessions(transport)));
    await ready(tester);

    bool focused() => tester
        .widget<TerminalView>(find.byType(TerminalView))
        .focusNode!
        .hasFocus;
    bool armed() => tester.widget<ShellBar>(find.byType(ShellBar)).keyboardOpen;

    // What the window comes back with when it was stopped with the keyboard up: the inset
    // stands, nothing holds focus, and there is no keyboard under it.
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await ready(tester);
    expect(focused(), isFalse);
    expect(armed(), isFalse);

    await tester.tap(find.byKey(const ValueKey('bar-keyboard')));
    await ready(tester);
    expect(focused(), isTrue);

    await unmount(tester);
  });

  group('AUTHORIZATION REQUIRED', () {
    const id = '0123456789abcdef';
    String payload({String error = ''}) => base64Encode(
      utf8.encode(
        jsonEncode({
          'mode': 'pin',
          'desc': 'Please enter the passphrase for the ssh key',
          'prompt': 'Passphrase:',
          'error': error,
        }),
      ),
    );

    String request({String requestId = id, String error = ''}) =>
        '\x1b]7771;pin;$requestId;${payload(error: error)}\x07';

    /// What the host answers while it still holds the request open.
    String listing() => '$id ${payload()}\n';

    testWidgets('a request raises the sheet and UNLOCK sends what was typed', (
      tester,
    ) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions));
      await ready(tester);
      final connection = transport.opened.single;
      expect(
        connection.execs.first.command,
        pinentryMarkCommand(sessions.forHost(rose.id).single.tab),
      );

      connection.emit(request(error: 'Bad Passphrase (try 2 of 3)'));
      await ready(tester);

      expect(find.text('AUTHORIZATION REQUIRED'), findsOneWidget);
      expect(find.text('SHELL 1'), findsOneWidget);
      expect(
        find.text('Please enter the passphrase for the ssh key'),
        findsOneWidget,
      );
      expect(find.text('Bad Passphrase (try 2 of 3)'), findsOneWidget);
      expect(find.text('PASSPHRASE'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'hunter2');
      await tester.tap(find.text('UNLOCK'));
      await ready(tester);

      expect(find.text('AUTHORIZATION REQUIRED'), findsNothing);
      final answer = connection.execs.last;
      expect(answer.command, pinentryAnswerCommand(id));
      expect(answer.command, isNot(contains('hunter2')));
      expect(utf8.decode(answer.stdin!), 'hunter2\n');

      await unmount(tester);
    });

    testWidgets('the sheet names the tab on screen when it holds the request', (
      tester,
    ) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions));
      await ready(tester);
      await openNewShell(tester);
      final connections = transport.opened;
      expect(connections, hasLength(2));

      // Under Mosh every tab of the host hears the bell, one after another.
      connections[0].emit(request());
      await ready(tester);

      expect(find.text('AUTHORIZATION REQUIRED'), findsOneWidget);
      expect(find.text('SHELL 1'), findsOneWidget);

      connections[1].emit(request());
      await ready(tester);

      expect(find.text('AUTHORIZATION REQUIRED'), findsOneWidget);
      expect(find.text('SHELL 2'), findsOneWidget);
      expect(find.text('SHELL 1'), findsNothing);

      await unmount(tester);
    });

    testWidgets('UNLOCK takes down the sheet and nothing under it', (
      tester,
    ) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(
        app(
          sessions,
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      HostShellRoute(host: rose, intent: testIntent()),
                ),
              ),
              child: const Text('GO'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('GO'));
      await ready(tester);
      final connection = transport.opened.single;

      connection.emit(request());
      await ready(tester);
      await tester.enterText(find.byType(TextField), 'hunter2');
      await tester.tap(find.text('UNLOCK'));
      await ready(tester);

      expect(find.text('AUTHORIZATION REQUIRED'), findsNothing);
      expect(find.byType(HostShellRoute), findsOneWidget);
      expect(find.text('GO'), findsNothing);

      await unmount(tester);
    });

    testWidgets('CANCEL sends the bare newline', (tester) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions));
      await ready(tester);
      final connection = transport.opened.single;

      connection.emit(request());
      await ready(tester);
      await tester.tap(find.text('CANCEL'));
      await ready(tester);

      expect(find.text('AUTHORIZATION REQUIRED'), findsNothing);
      expect(connection.execs.last.command, pinentryAnswerCommand(id));
      expect(connection.execs.last.stdin, [0x0a]);

      await unmount(tester);
    });

    testWidgets('done takes the sheet down and sends nothing', (tester) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions));
      await ready(tester);
      final connection = transport.opened.single;

      connection.emit(request());
      await ready(tester);
      expect(find.text('AUTHORIZATION REQUIRED'), findsOneWidget);

      connection.emit('\x1b]7771;done;$id\x07');
      await ready(tester);

      expect(find.text('AUTHORIZATION REQUIRED'), findsNothing);
      expect(
        connection.execs.map((exec) => exec.command),
        isNot(contains(pinentryAnswerCommand(id))),
      );

      await unmount(tester);
    });

    testWidgets('a sheet swiped away sends nothing and stays away', (
      tester,
    ) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions));
      await ready(tester);
      final connection = transport.opened.single;

      connection.emit(request());
      await ready(tester);
      expect(find.text('AUTHORIZATION REQUIRED'), findsOneWidget);

      await tester.tapAt(const Offset(10, 10));
      await ready(tester);

      expect(find.text('AUTHORIZATION REQUIRED'), findsNothing);
      expect(
        connection.execs.map((exec) => exec.command),
        isNot(contains(pinentryAnswerCommand(id))),
      );
      expect(sessions.forHost(rose.id).single.pin?.id, id);
      connection.emit('hello\n');
      await ready(tester);
      expect(find.text('AUTHORIZATION REQUIRED'), findsNothing);

      connection.emit(request(requestId: 'fedcba9876543210'));
      await ready(tester);
      expect(find.text('AUTHORIZATION REQUIRED'), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('the header brings a swiped sheet back while the ask stands', (
      tester,
    ) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions));
      await ready(tester);
      final connection = transport.opened.single;
      final key = find.byKey(const ValueKey('shell-tab-pin'));
      expect(key, findsNothing);

      connection.emit(request());
      await ready(tester);
      expect(key, findsNothing);

      await tester.tapAt(const Offset(10, 10));
      await ready(tester);
      expect(find.text('AUTHORIZATION REQUIRED'), findsNothing);
      expect(key, findsOneWidget);

      await tester.tap(key);
      await ready(tester);
      expect(find.text('AUTHORIZATION REQUIRED'), findsOneWidget);
      expect(key, findsNothing);

      await tester.tapAt(const Offset(10, 10));
      await ready(tester);
      expect(key, findsOneWidget);

      connection.emit('\x1b]7771;done;$id\x07');
      await ready(tester);
      expect(key, findsNothing);
      expect(find.text('AUTHORIZATION REQUIRED'), findsNothing);
      expect(
        connection.execs.map((exec) => exec.command),
        isNot(contains(pinentryAnswerCommand(id))),
      );

      await unmount(tester);
    });

    testWidgets('an ask that stands past its window may be over', (
      tester,
    ) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(
        transport,
        pinRecheck: const Duration(milliseconds: 50),
        pinStale: Duration.zero,
      );
      await tester.pumpWidget(app(sessions));
      await ready(tester);
      final connection = transport.opened.single;

      connection.answerWith(listing());
      connection.emit(request());
      await ready(tester);
      ActionBlock unlock() => tester.widget<ActionBlock>(
        find.widgetWithText(ActionBlock, 'UNLOCK'),
      );
      expect(find.text('AUTHORIZATION REQUIRED'), findsOneWidget);
      expect(find.text('MAY HAVE EXPIRED'), findsNothing);
      expect(unlock().filled, isTrue);

      connection.emit('\x07');
      await ready(tester);

      expect(find.text('AUTHORIZATION REQUIRED'), findsOneWidget);
      expect(find.text('MAY HAVE EXPIRED'), findsOneWidget);
      expect(unlock().filled, isFalse);

      connection.emit('\x1b]7771;done;$id\x07');
      await ready(tester);
      expect(find.text('AUTHORIZATION REQUIRED'), findsNothing);

      await unmount(tester);
    });

    testWidgets('an answer the host had already taken down says so', (
      tester,
    ) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions));
      await ready(tester);
      final connection = transport.opened.single;

      connection.emit(request());
      await ready(tester);
      connection.answer = (command, _) => ExecResult(
        exitCode: command == pinentryAnswerCommand(id) ? 1 : 0,
        stdout: Uint8List(0),
        stderr: Uint8List(0),
      );

      await tester.enterText(find.byType(TextField), 'hunter2');
      await tester.tap(find.text('UNLOCK'));
      await ready(tester);

      expect(find.text('AUTHORIZATION REQUIRED'), findsNothing);
      expect(find.text('AUTHORIZATION EXPIRED'), findsOneWidget);
      expect(find.text('SHELL 1'), findsOneWidget);

      await tester.tap(find.text('CLOSE'));
      await ready(tester);
      expect(find.text('AUTHORIZATION EXPIRED'), findsNothing);

      await unmount(tester);
    });
  });
}
