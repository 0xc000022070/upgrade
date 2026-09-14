import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/design/colors.dart';
import 'package:dazzle/features/shell/shell_header.dart';
import 'package:dazzle/features/shell/shell_status.dart';
import 'package:dazzle/platform/shell/shell_connection.dart';
import 'package:xterm/xterm.dart';

import 'support/fake_shell.dart';
import 'support/platform_channels.dart';
import 'support/shell_route.dart';

/// The word one tab is drawn with.
String labelOfTab(WidgetTester tester, int number) => tester
    .widget<Text>(
      find.descendant(
        of: find.byKey(ValueKey('shell-tab-$number')),
        matching: find.byType(Text),
      ),
    )
    .data!;

/// The colour of one tab's state dot.
/// The colour of one tab's state dot.
Color? dotOfTab(WidgetTester tester, int number) =>
    (tester
                .widget<Container>(
                  find.descendant(
                    of: find.descendant(
                      of: find.byKey(ValueKey('shell-tab-$number')),
                      matching: find.byType(ShellStateDot),
                    ),
                    matching: find.byType(Container),
                  ),
                )
                .decoration
            as BoxDecoration)
        .color;

void main() {
  setUp(stubDeviceChannels);

  testWidgets('a live Mosh tab names its transport in the header', (
    tester,
  ) async {
    final transport = FakeShellTransport()..transport = ShellTransport.mosh;
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions));
    await ready(tester);

    expect(find.text('CONNECTED · MOSH'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('the plus menu opens a numbered tab on the selected host', (
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

    expect(find.byKey(const ValueKey('shell-new-host-h1')), findsOneWidget);
    expect(find.text('CURRENT'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('shell-new-host-h1')));
    await ready(tester);

    expect(find.byKey(const ValueKey('shell-tab-2')), findsOneWidget);
    expect(sessions.activeFor(rose.id)?.number, 2);

    // And the first tab takes the user back to the shell it holds.
    await tester.tap(find.byKey(const ValueKey('shell-tab-1')));
    await ready(tester);
    expect(sessions.activeFor(rose.id)?.number, 1);

    await unmount(tester);
  });

  group('a tab says which shell it is', () {
    test('a shell with no title reads its number', () {
      expect(shellTabLabel(null, 3), '3');
      expect(shellTabLabel('   ', 3), '3');
    });

    test('a login shell reads where it is, not who it is', () {
      expect(shellTabLabel('luis@nyx: ~/Projects/dazzle', 1), 'dazzle');
      expect(shellTabLabel('luis@nyx: ~', 1), '~');
      expect(shellTabLabel('~/Projects/dazzle', 1), 'dazzle');
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

      transport.opened.first.emit('\x1b]0;luis@rose: ~/Projects/dazzle\x07');
      await ready(tester);

      expect(labelOfTab(tester, 1), 'dazzle');

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
        tester.getSize(find.byKey(const ValueKey('shell-tab-1'))).width,
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

      expect(dotOfTab(tester, 1), DazzleColors.accent);

      transport.opened.first.drop();
      await ready(tester);

      expect(dotOfTab(tester, 1), isNot(DazzleColors.accent));

      await tester.tap(find.text('STOP'));
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

      // The cap is on the word, not on the cell: a tab that says `1` is a tap
      // target wide and leaves the rest of the row to what the shell is doing.
      expect(
        tester.getSize(find.byKey(const ValueKey('shell-tab-1'))).width,
        lessThan(60),
      );

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
        sessions.open(rose);
      }
      await tester.pumpWidget(app(sessions));
      await ready(tester);

      // Through the store, the way the plus opens one: the plus itself is off
      // the right edge here, which is the very thing being fixed.
      sessions.open(rose);
      await ready(tester);

      final ninth = tester.getRect(find.byKey(const ValueKey('shell-tab-9')));
      expect(ninth.left, greaterThanOrEqualTo(0));
      expect(ninth.right, lessThanOrEqualTo(411));

      await unmount(tester);
    });
  });

  testWidgets('the plus is gone once nine tabs are open', (tester) async {
    // A phone's width, where nine tabs are wider than the row they are in.
    tester.view.physicalSize = const Size(411, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    for (var i = 0; i < 9; i++) {
      sessions.open(rose);
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
    expect(find.text('ROSE'), findsNothing);
    expect(find.text('OPEN'), findsOneWidget);

    await unmount(tester);
  });

  group('the keyboard follows the tab', () {
    /// Whether the IME is wired to anything. The view opens a text input
    /// connection when its focus node takes focus and closes it when the view
    /// goes; a focus node that is held with no connection under it is a
    /// keyboard that types into nothing.
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

      await tester.tap(find.byKey(const ValueKey('shell-tab-1')));
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

      // The shell the keyboard was on exits clean and takes its tab, which
      // puts the first tab back on screen.
      transport.opened[1].exit(0);
      await ready(tester);
      expect(sessions.activeFor(rose.id)?.number, 1);

      // Whether the keyboard came along or went down, the cell's next tap
      // has to end with a keyboard that types into the shell on screen.
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

      // Two views sharing one node hand focus over without a change of focus,
      // and a view that never sees the change never opens its input.
      expect(first, isNotNull);
      expect(second, isNot(same(first)));

      await unmount(tester);
    });
  });
}
