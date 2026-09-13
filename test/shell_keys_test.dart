import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/features/shell/shell_bar.dart';
import 'package:dazzle/platform/shell/remote_shell.dart';
import 'package:xterm/xterm.dart';

import 'support/fake_shell.dart';
import 'support/platform_channels.dart';
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
        .terminal;

    await tester.drag(
      find.byKey(const ValueKey('bar-CTRL')),
      const Offset(0, 40),
    );
    await ready(tester);
    expect(find.text('CTRL(x2)'), findsOneWidget);

    // The keyboard's own characters, which never pass through the bar.
    terminal.textInput('d');
    await ready(tester);
    expect(find.text('CTRL(x2)'), findsNothing);
    expect(find.text('CTRL'), findsOneWidget);

    terminal.textInput('d');
    await ready(tester);
    terminal.textInput('d');

    expect(connection.writes, [
      [0x04],
      [0x04],
      [0x64],
    ]);

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

    // What the window comes back with when it was stopped with the keyboard
    // up: the inset stands, nothing holds focus, and there is no keyboard
    // under it. The inset alone would light the cell and every tap on it would
    // put away a keyboard that is not there, which left the strip jammed until
    // the app was killed.
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await ready(tester);
    expect(focused(), isFalse);
    expect(armed(), isFalse);

    await tester.tap(find.byKey(const ValueKey('bar-keyboard')));
    await ready(tester);
    // One tap asks for a real keyboard, and a real keyboard is what replaces
    // the inset it left standing.
    expect(focused(), isTrue);

    await unmount(tester);
  });

  group('AUTHORIZATION REQUIRED', () {
    const id = '0123456789abcdef';
    String request({String requestId = id, String error = ''}) {
      final payload = base64Encode(
        utf8.encode(
          jsonEncode({
            'mode': 'pin',
            'desc': 'Please enter the passphrase for the ssh key',
            'prompt': 'Passphrase:',
            'error': error,
          }),
        ),
      );
      return '\x1b]7771;pin;$requestId;$payload\x07';
    }

    testWidgets('a request raises the sheet and UNLOCK sends what was typed', (
      tester,
    ) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions));
      await ready(tester);
      final connection = transport.opened.single;
      expect(connection.execs.first.command, pinentryMarkCommand);

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
      // The computer still has it; the phone is not asked twice for one id.
      expect(sessions.forHost(rose.id).single.pin?.id, id);
      connection.emit('hello\n');
      await ready(tester);
      expect(find.text('AUTHORIZATION REQUIRED'), findsNothing);

      // The next request is a new one and comes up.
      connection.emit(request(requestId: 'fedcba9876543210'));
      await ready(tester);
      expect(find.text('AUTHORIZATION REQUIRED'), findsOneWidget);

      await unmount(tester);
    });
  });
}
