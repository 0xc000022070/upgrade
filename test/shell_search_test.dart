import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spectacle/data/repositories/host_repository.dart';
import 'package:spectacle/features/shell/host_shell_screen.dart';
import 'package:spectacle/features/shell/shell_search.dart';
import 'package:spectacle/features/shell/shell_sessions.dart';
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

const _field = ValueKey('shell-find-field');
const _prev = ValueKey('shell-find-prev');
const _next = ValueKey('shell-find-next');
const _close = ValueKey('shell-find-close');

void main() {
  setUp(stubDeviceChannels);

  group('what a query finds', () {
    test('a hit is found whatever the case, and a line can hold more than '
        'one', () {
      final terminal = Terminal()..write('Hello\r\nhello there hello\r\n');

      final hits = shellHits(terminal, 'hello');

      expect(hits, hasLength(3));
      // In the order the buffer holds them: the line above first, and the two
      // on one line left to right.
      expect(hits[0].start, 0);
      expect(hits[1].line, hits[0].line + 1);
      expect(hits[1].start, 0);
      expect(hits[2].line, hits[1].line);
      expect(hits[2].start, 12);
      expect(hits[2].end, 17);
    });

    test('nothing is looked for until something is typed', () {
      final terminal = Terminal()..write('hello\r\n');

      expect(shellHits(terminal, ''), isEmpty);
      expect(shellHits(terminal, '   '), isEmpty);
    });

    test('a query with more hits than the cap keeps the newest', () {
      final terminal = Terminal(maxLines: 4000)
        ..write('mark\r\n' * (shellHitCap + 100));

      final hits = shellHits(terminal, 'mark');

      expect(hits, hasLength(shellHitCap));
      // The oldest hundred are the ones dropped: what was just printed is
      // what a search is for.
      final all = shellHits(terminal, 'mark');
      expect(all.last.line, greaterThan(shellHitCap));
    });
  });

  group('the line under the terminal', () {
    /// The row on its own over a session with a buffer, which is everything
    /// the search reads. No terminal is laid out under it, so nothing moves.
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
              body: ShellSearchRow(session: session, onClose: () {}),
            ),
          ),
        ),
      );
      return session;
    }

    /// What the count reads, `3/17`.
    String count(WidgetTester tester) => tester
        .widget<Text>(find.byKey(const ValueKey('shell-find-count')))
        .data!;

    testWidgets('the search opens on the newest hit and the steps walk it', (
      tester,
    ) async {
      final transport = FakeShellTransport();
      await row(tester, transport, output: 'one\r\ntwo\r\none\r\none\r\n');

      await tester.enterText(find.byKey(_field), 'one');
      await tester.pump(const Duration(milliseconds: 200));

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

    testWidgets('the hit being read is marked apart from the rest', (
      tester,
    ) async {
      final transport = FakeShellTransport();
      final session = await row(
        tester,
        transport,
        output: 'one\r\ntwo\r\none\r\n',
      );

      await tester.enterText(find.byKey(_field), 'one');
      await tester.pump(const Duration(milliseconds: 200));

      final marks = session.controller.highlights;
      expect(marks, hasLength(2));
      expect(
        marks.where((mark) => mark.color == shellHitCurrentWash),
        hasLength(1),
      );
      expect(marks.where((mark) => mark.color == shellHitWash), hasLength(1));
      // The newest hit is the one being read.
      expect(
        marks
            .firstWhere((mark) => mark.color == shellHitCurrentWash)
            .range!
            .begin
            .y,
        greaterThan(
          marks.firstWhere((mark) => mark.color == shellHitWash).range!.begin.y,
        ),
      );

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('what is typed in the line is not sent to the shell', (
      tester,
    ) async {
      final transport = FakeShellTransport();
      await row(tester, transport, output: 'one\r\n');

      await tester.enterText(find.byKey(_field), 'one');
      await tester.pump(const Duration(milliseconds: 200));

      expect(transport.opened.single.written, isEmpty);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('closing takes the marks with it', (tester) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      sessions.open(_rose);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      final session = sessions.activeFor(_rose.id)!;
      transport.opened.single.emit('one\r\none\r\n');
      await tester.pump(const Duration(milliseconds: 10));

      var closed = false;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: ShellSearchRow(
                session: session,
                onClose: () => closed = true,
              ),
            ),
          ),
        ),
      );

      await tester.enterText(find.byKey(_field), 'one');
      await tester.pump(const Duration(milliseconds: 200));
      expect(session.controller.highlights, isNotEmpty);

      await tester.tap(find.byKey(_close));
      await tester.pump();

      expect(closed, isTrue);
      // The row is taken down by whoever opened it; the marks go with the
      // row and not with the tap.
      await tester.pumpWidget(const SizedBox.shrink());
      expect(session.controller.highlights, isEmpty);
    });
  });

  group('the search on the route', () {
    Widget app(ShellSessions sessions) => ProviderScope(
      overrides: [shellSessionsProvider.overrideWithValue(sessions)],
      child: const MaterialApp(home: HostShellRoute(host: _rose)),
    );

    Future<void> ready(WidgetTester tester) async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    testWidgets('FIND opens the line and the view goes to the hit', (
      tester,
    ) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions));
      await ready(tester);
      final session = sessions.activeFor(_rose.id)!;

      transport.opened.single.emit(
        'needle\r\n${'filler\r\n' * 300}',
      );
      await ready(tester);

      // The view is on the last line, three hundred lines past the one word
      // being looked for.
      final position = session.tailPosition!;
      expect(position.extentAfter, 0);
      final bottom = position.pixels;

      await tester.tap(find.byKey(const ValueKey('bar-find')));
      await tester.pump();
      await tester.enterText(find.byKey(_field), 'needle');
      await tester.pump(const Duration(milliseconds: 200));

      expect(session.controller.highlights, hasLength(1));
      expect(session.scrollController.position.pixels, lessThan(bottom));
      // And the way back to the live line is there, because the view is off
      // it now.
      expect(find.byKey(const ValueKey('shell-tail')), findsOneWidget);

      await tester.tap(find.byKey(_close));
      await tester.pump();
      expect(find.byKey(_field), findsNothing);
      expect(session.controller.highlights, isEmpty);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('FIND is the whole gesture: one tap raises the line, the next '
        'takes it down', (tester) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions));
      await ready(tester);

      // One frame, so nothing had the chance to stand between the tap and the
      // field: the cell has one answer and gives it.
      await tester.tap(find.byKey(const ValueKey('bar-find')));
      await tester.pump();
      expect(find.byKey(_field), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('bar-find')));
      await tester.pump();
      expect(find.byKey(_field), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('a key from the bar still reaches the shell while the line '
        'is up', (tester) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions));
      await ready(tester);
      final connection = transport.opened.single;

      await tester.tap(find.byKey(const ValueKey('bar-find')));
      await tester.pump();
      await tester.enterText(find.byKey(_field), 'ls');
      await tester.pump(const Duration(milliseconds: 200));
      expect(connection.written, isEmpty);

      await tester.tap(find.byKey(const ValueKey('bar-ESC')));
      await tester.pump();

      expect(connection.written, '\x1b');

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });
  });
}
