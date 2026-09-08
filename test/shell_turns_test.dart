import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spectacle/data/repositories/host_repository.dart';
import 'package:spectacle/features/shell/host_shell_screen.dart';
import 'package:spectacle/features/shell/shell_search.dart';
import 'package:spectacle/features/shell/shell_sessions.dart';
import 'package:spectacle/features/shell/shell_turns.dart';
import 'package:xterm/xterm.dart';

import 'support/fake_shell.dart';
import 'support/platform_channels.dart';

/// Stepping between the user's own turns: what counts as one, where the cell
/// is, and where a step lands.

const _rose = Host(
  id: 'h1',
  name: 'rose',
  address: '100.64.0.1',
  port: 22,
  user: 'luis',
  keyId: 'key-1',
);

const _find = ValueKey('bar-find');
const _field = ValueKey('shell-find-field');
const _prev = ValueKey('shell-turns-prev');
const _next = ValueKey('shell-turns-next');
const _close = ValueKey('shell-turns-close');

/// A Claude pane: the shell it was started from, the agent's copy of two
/// messages, and the work it printed about them.
const _claudePane =
    '~/spectacle main > just test\r\n'
    '> read the gate log\r\n'
    '● Bash(flutter test)\r\n'
    '  918 tests passed\r\n'
    '> now ship it\r\n'
    '● Write(lib/main.dart)\r\n';

void main() {
  setUp(stubDeviceChannels);

  group('what counts as a turn', () {
    test('a pane answers one turn per message the agent copied back', () {
      final terminal = Terminal()..write(_claudePane);

      final turns = shellTurns(terminal);

      expect(turns, hasLength(2));
      // Oldest first, the way the buffer holds them.
      expect(turns.first.line, lessThan(turns.last.line));
      expect(turns.first.column, 0);
      final buffer = terminal.buffer;
      expect(
        buffer.lines[turns.first.line].getText().trim(),
        '> read the gate log',
      );
      expect(buffer.lines[turns.last.line].getText().trim(), '> now ship it');
    });

    test('both agents are read, because the tab is an ssh session and says '
        'nothing about what was started in it', () {
      final terminal = Terminal()
        ..write('› fix the codex path\r\n• ran tests\r\n');

      final turns = shellTurns(terminal);

      expect(turns, hasLength(1));
      expect(
        terminal.buffer.lines[turns.single.line].getText().trim(),
        '› fix the codex path',
      );
    });

    test('a prompt line, the agent\'s own output and an empty input box are '
        'not turns', () {
      final terminal = Terminal()
        ..write(
          '~/spectacle main > just test\r\n'
          '● Bash(flutter test)\r\n'
          '  the diff is > 400 lines\r\n'
          '> \r\n',
        );

      expect(shellTurns(terminal), isEmpty);
    });

    test('a message long enough to wrap is one turn, not two', () {
      // Narrow enough that the message runs onto a second line, whose text
      // could open with a mark the user typed inside their own message.
      final terminal = Terminal()
        ..resize(20, 10)
        ..write('> ship it and then > check the log\r\n');

      expect(shellTurns(terminal), hasLength(1));
    });

    test('a pane on the alternate screen answers what the screen holds', () {
      final terminal = Terminal()..write(_claudePane);
      expect(shellTurns(terminal), hasLength(2));

      // What Claude Code sends when it takes the screen, which it always does.
      // The main buffer is still alive underneath and still holds those marks;
      // they are not the answer, because they are not what the pane shows.
      terminal.write('\x1b[?1049h');
      expect(terminal.isUsingAltBuffer, isTrue);
      expect(shellTurns(terminal), isEmpty);

      terminal.write('> read the gate log\r\n\u25cf Bash(flutter test)\r\n');

      final turns = shellTurns(terminal);
      expect(turns, hasLength(1));
      expect(
        terminal.buffer.lines[turns.single.line].getText().trim(),
        '> read the gate log',
      );
    });

    test('a pane with more turns than the cap keeps the newest', () {
      final terminal = Terminal(maxLines: 4000)
        ..write('> again\r\n' * (shellTurnCap + 40));

      expect(shellTurns(terminal), hasLength(shellTurnCap));
    });
  });

  group('the line under the terminal', () {
    /// The row on its own over a session with a buffer, which is all the
    /// jumper reads. No terminal is laid out under it, so nothing moves.
    Future<ShellSession> row(
      WidgetTester tester,
      FakeShellTransport transport, {
      required String output,
    }) async {
      final sessions = fakeShellSessions(transport);
      sessions.open(_rose);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      final session = sessions.activeFor(_rose.id)!;
      transport.opened.single.emit(output);
      await tester.pump(const Duration(milliseconds: 10));
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: ShellTurnsWatch(
                session: session,
                builder: (context, turns) => ShellTurnsRow(
                  session: session,
                  turns: turns,
                  onClose: () {},
                ),
              ),
            ),
          ),
        ),
      );
      return session;
    }

    /// What the count reads, `2/2`.
    String count(WidgetTester tester) => tester
        .widget<Text>(find.byKey(const ValueKey('shell-turns-count')))
        .data!;

    testWidgets('it opens on the newest turn and the steps walk it', (
      tester,
    ) async {
      final transport = FakeShellTransport();
      await row(
        tester,
        transport,
        output: '> one\r\n● work\r\n> two\r\n> three\r\n',
      );

      expect(count(tester), '3/3');

      await tester.tap(find.byKey(_prev));
      await tester.pump();
      expect(count(tester), '2/3');

      await tester.tap(find.byKey(_prev));
      await tester.pump();
      expect(count(tester), '1/3');

      // The ends meet: a step past the oldest is the newest again.
      await tester.tap(find.byKey(_prev));
      await tester.pump();
      expect(count(tester), '3/3');

      await tester.tap(find.byKey(_next));
      await tester.pump();
      expect(count(tester), '1/3');

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('the turn being read is the one washed', (tester) async {
      final transport = FakeShellTransport();
      final session = await row(
        tester,
        transport,
        output: '> one\r\n● work\r\n> two\r\n',
      );

      final wash = session.controller.highlights.single;
      expect(wash.color, shellHitCurrentWash);
      // The whole message, from its mark to the end of what was written.
      expect(wash.range!.begin.x, 0);
      expect(wash.range!.end.x, '> two'.length);
      final newest = wash.range!.begin.y;

      await tester.tap(find.byKey(_prev));
      await tester.pump();
      // One wash at a time, and now on the turn two lines above.
      expect(session.controller.highlights.single.range!.begin.y, newest - 2);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('it has no field, so nothing it does reaches the shell', (
      tester,
    ) async {
      final transport = FakeShellTransport();
      await row(tester, transport, output: '> one\r\n> two\r\n');

      expect(find.byType(TextField), findsNothing);

      await tester.tap(find.byKey(_prev));
      await tester.pump();
      await tester.tap(find.byKey(_next));
      await tester.pump();

      expect(transport.opened.single.written, isEmpty);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a redraw that keeps the count still moves the mark', (
      tester,
    ) async {
      final transport = FakeShellTransport();
      final session = await row(
        tester,
        transport,
        output: '\x1b[?1049h> one\r\n\u25cf work\r\n',
      );

      final before = session.controller.highlights.single.range!.begin.y;

      // The screen drawn again with the turn further down it, which is what an
      // alternate-screen agent does on every repaint. One turn before and one
      // after, so a watch counting them sees nothing happen.
      transport.opened.single.emit('\x1b[2J\x1b[H\r\n\r\n> one\r\n');
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();

      expect(shellTurns(session.terminal), hasLength(1));
      expect(
        session.controller.highlights.single.range!.begin.y,
        greaterThan(before),
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('closing takes the wash with it', (tester) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      sessions.open(_rose);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      final session = sessions.activeFor(_rose.id)!;
      transport.opened.single.emit('> one\r\n> two\r\n');
      await tester.pump(const Duration(milliseconds: 10));

      var closed = false;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: ShellTurnsRow(
                session: session,
                turns: shellTurns(session.terminal),
                onClose: () => closed = true,
              ),
            ),
          ),
        ),
      );
      expect(session.controller.highlights, hasLength(1));

      await tester.tap(find.byKey(_close));
      expect(closed, isTrue);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
      expect(session.controller.highlights, isEmpty);
    });
  });

  group('the cell on the bar', () {
    Widget app(ShellSessions sessions) => ProviderScope(
      overrides: [shellSessionsProvider.overrideWithValue(sessions)],
      child: const MaterialApp(home: HostShellRoute(host: _rose)),
    );

    /// The store dials off a microtask and the panels decode over a few
    /// frames, so nothing is on screen after a single pump.
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

    testWidgets('a pane with nothing to step through is not made to pick', (
      tester,
    ) async {
      final transport = FakeShellTransport();
      await tester.pumpWidget(app(fakeShellSessions(transport)));
      await ready(tester);

      transport.opened.single.emit('~/spectacle main > just test\r\n');
      await ready(tester);

      await tester.tap(find.byKey(_find));
      await tester.pumpAndSettle();

      expect(find.text('YOUR TURNS'), findsNothing);
      expect(find.byKey(_field), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('a pane that has kept turns offers them beside the pattern, '
        'and the pick raises the line', (tester) async {
      final transport = FakeShellTransport();
      await tester.pumpWidget(app(fakeShellSessions(transport)));
      await ready(tester);
      transport.opened.single.emit(_claudePane);
      await ready(tester);

      expect(find.byKey(_prev), findsNothing);

      await tester.tap(find.byKey(_find));
      await tester.pumpAndSettle();
      expect(find.text('PATTERN'), findsOneWidget);
      expect(find.text('YOUR TURNS'), findsOneWidget);
      // The menu is the whole of the tap: neither line is up behind it.
      expect(find.byKey(_field), findsNothing);
      expect(find.byKey(_prev), findsNothing);

      await tester.tap(find.text('YOUR TURNS'));
      await tester.pumpAndSettle();
      expect(find.byKey(_prev), findsOneWidget);
      expect(find.byKey(const ValueKey('shell-turns-count')), findsOneWidget);

      await tester.tap(find.byKey(_close));
      await tester.pump();
      expect(find.byKey(_prev), findsNothing);

      await unmount(tester);
    });

    testWidgets('the pattern is still one pick away on a pane with turns', (
      tester,
    ) async {
      final transport = FakeShellTransport();
      await tester.pumpWidget(app(fakeShellSessions(transport)));
      await ready(tester);
      transport.opened.single.emit(_claudePane);
      await ready(tester);

      await tester.tap(find.byKey(_find));
      await tester.pumpAndSettle();
      await tester.tap(find.text('PATTERN'));
      await tester.pumpAndSettle();

      expect(find.byKey(_field), findsOneWidget);
      expect(find.byKey(_prev), findsNothing);

      await unmount(tester);
    });

    testWidgets('one cell for both lines: it is armed while either is up and '
        'takes it back down', (tester) async {
      final transport = FakeShellTransport();
      await tester.pumpWidget(app(fakeShellSessions(transport)));
      await ready(tester);
      transport.opened.single.emit(_claudePane);
      await ready(tester);

      // The cell that came and went with the pane's turns is gone: there is
      // one, and no menu is raised over a line that is already up.
      expect(find.byKey(const ValueKey('bar-turns')), findsNothing);

      await tester.tap(find.byKey(_find));
      await tester.pumpAndSettle();
      await tester.tap(find.text('YOUR TURNS'));
      await tester.pumpAndSettle();
      expect(find.byKey(_prev), findsOneWidget);

      await tester.tap(find.byKey(_find));
      await tester.pumpAndSettle();
      expect(find.text('YOUR TURNS'), findsNothing);
      expect(find.byKey(_prev), findsNothing);
      expect(find.byKey(_field), findsNothing);

      await unmount(tester);
    });
  });
}
