import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/features/shell/host_shell_screen.dart';
import 'package:upgrade/features/shell/shell_search.dart';
import 'package:upgrade/features/shell/shell_sessions.dart';
import 'package:flterm/flterm.dart';

import 'support/fake_shell.dart';
import 'support/platform_channels.dart';
import 'support/reasons.dart';
import 'support/shell_route.dart' show noWorkspaces;

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

  group('the line under the terminal', () {
    /// No terminal is laid out under it, so nothing moves.
    Future<ShellSession> row(
      WidgetTester tester,
      FakeShellTransport transport, {
      required String output,
    }) async {
      final sessions = fakeShellSessions(transport);
      sessions.open(intent: testIntent(), _rose);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      final session = sessions.activeFor(_rose.id)!;
      transport.opened.single.emit(output);
      await tester.pump(const Duration(milliseconds: 10));
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: ThemeData(extensions: const [UpgradeTokens.house]),
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

      final search = session.terminal.search;
      int rowOf(Selection match) =>
          match.start.positionIn(PointTag.screen)!.row;
      expect(search.totalMatches, 2);
      final current = search.selectedMatch!;
      final other = search.matches.singleWhere(
        (match) => rowOf(match) != rowOf(current),
      );
      expect(rowOf(current), greaterThan(rowOf(other)));

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
      sessions.open(intent: testIntent(), _rose);
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
            theme: ThemeData(extensions: const [UpgradeTokens.house]),
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
      expect(session.terminal.search.totalMatches, 2);

      await tester.tap(find.byKey(_close));
      await tester.pump();

      expect(closed, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(session.terminal.search.totalMatches, 0);
    });
  });

  group('the search on the route', () {
    Widget app(ShellSessions sessions) => ProviderScope(
      overrides: [
        shellSessionsProvider.overrideWithValue(sessions),
        noWorkspaces,
      ],
      child: MaterialApp(
        theme: ThemeData(extensions: const [UpgradeTokens.house]),
        home: HostShellRoute(host: _rose, intent: testIntent()),
      ),
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

      transport.opened.single.emit('needle\r\n${'filler\r\n' * 300}');
      await ready(tester);

      expect(session.rowsBehind, 0);

      await tester.tap(find.byKey(const ValueKey('bar-find')));
      await tester.pump();
      await tester.enterText(find.byKey(_field), 'needle');
      await tester.pump(const Duration(milliseconds: 200));

      expect(session.terminal.search.totalMatches, 1);
      expect(session.rowsBehind, greaterThan(0));
      expect(find.byKey(const ValueKey('shell-tail')), findsOneWidget);

      await tester.tap(find.byKey(_close));
      await tester.pump();
      expect(find.byKey(_field), findsNothing);
      await tester.pump();
      expect(session.terminal.search.totalMatches, 0);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('FIND is the whole gesture: one tap raises the line, the next '
        'takes it down', (tester) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions));
      await ready(tester);

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
