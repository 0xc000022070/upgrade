import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:striked/features/shell/input/shell_selection.dart';
import 'package:striked/features/shell/session/shell_sessions.dart';
import 'package:striked/features/shell/shell_terminal.dart';
import 'package:flterm/flterm.dart';

import '../../../support/platform_channels.dart';
import '../../../support/shell_route.dart' show rose;
import '../../../support/themed_app.dart';

const _screen = Size(400, 600);

ShellSession _session() {
  final session = ShellSession(
    number: 1,
    terminal: TerminalController(),
    host: rose,
  );
  addTearDown(session.dispose);
  return session;
}

void _write(ShellSession session, String text) =>
    session.terminal.write(Uint8List.fromList(utf8.encode(text)));

void _select(ShellSession session, int from, int to, {int row = 1}) =>
    session.terminal.selectRange(
      start: Position(row: row, col: from),
      end: Position(row: row, col: to),
      pointTag: PointTag.viewport,
    );

Widget _screenOf(Widget child) => Theme(
  data: testTheme,
  child: Directionality(
    textDirection: TextDirection.ltr,
    child: MediaQuery(
      data: const MediaQueryData(size: _screen),
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: _screen.width,
          height: _screen.height,
          child: child,
        ),
      ),
    ),
  ),
);

Future<void> _pumpView(WidgetTester tester, ShellSession session) async {
  await tester.pumpWidget(
    _screenOf(ShellTerminalView(session: session, fontSize: 12)),
  );
  await tester.pump();
}

Rect _copy(WidgetTester tester) =>
    tester.getRect(find.byKey(const ValueKey('shell-copy')));

void main() {
  testWidgets('the cell sits over the selected row and follows it down', (
    tester,
  ) async {
    final session = _session();
    await _pumpView(tester, session);

    _select(session, 2, 6, row: 10);
    await tester.pump();
    final high = _copy(tester);
    _select(session, 2, 6, row: 14);
    await tester.pump();
    final low = _copy(tester);

    expect(low.top, greaterThan(high.top));
    expect(high.top, greaterThan(shellTerminalPadding.top));
  });

  testWidgets('a selection on the top row puts the cell under it', (
    tester,
  ) async {
    final session = _session();
    await _pumpView(tester, session);

    _select(session, 2, 6, row: 0);
    await tester.pump();
    final top = _copy(tester);
    _select(session, 2, 6, row: 10);
    await tester.pump();

    expect(top.top, greaterThan(shellTerminalPadding.top));
    expect(top.top, lessThan(_copy(tester).top));
  });

  testWidgets('with no view laid out the cell takes the corner', (
    tester,
  ) async {
    final session = _session();
    await tester.pumpWidget(_screenOf(ShellSelectionActions(session: session)));
    _select(session, 2, 6);
    await tester.pump();

    final clear = tester.getRect(
      find.byKey(const ValueKey('shell-copy-clear')),
    );
    expect(clear.bottom, closeTo(_screen.height, 2));
    expect(clear.right, closeTo(_screen.width, 2));
  });

  testWidgets('COPY puts the selected text on the clipboard and lets it go', (
    tester,
  ) async {
    final writes = recordClipboardWrites();
    final session = _session();
    await _pumpView(tester, session);
    _write(session, 'revisar pgbouncer.conf');
    _select(session, 8, 21, row: 0);
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('shell-copy')));
    await tester.pumpAndSettle();

    expect(writes, ['pgbouncer.conf']);
    expect(session.terminal.hasSelection, isFalse);
    expect(find.byKey(const ValueKey('shell-copy')), findsNothing);
  });

  testWidgets('a selected link is handed to the browser', (tester) async {
    final opened = stubUrlLauncher();
    final session = _session();
    await _pumpView(tester, session);
    const url = 'http://100.118.60.77:8080/';
    _write(session, url);
    _select(session, 0, url.length - 1, row: 0);
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('shell-open')));
    await tester.pumpAndSettle();

    expect(opened, [url]);
    expect(session.terminal.hasSelection, isFalse);
  });

  testWidgets('a run with a link in it opens the link', (tester) async {
    final opened = stubUrlLauncher();
    final session = _session();
    await _pumpView(tester, session);
    const run = 'url=https://x.dev/a/b?c=1';
    _write(session, run);
    _select(session, 0, run.length - 1, row: 0);
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('shell-open')));
    await tester.pumpAndSettle();

    expect(opened, ['https://x.dev/a/b?c=1']);
  });

  testWidgets('a selection that is not a link has nothing to open', (
    tester,
  ) async {
    final session = _session();
    await _pumpView(tester, session);
    _write(session, 'revisar pgbouncer.conf');
    _select(session, 8, 21, row: 0);
    await tester.pump();

    expect(find.byKey(const ValueKey('shell-open')), findsNothing);
    expect(find.byKey(const ValueKey('shell-copy')), findsOneWidget);
    expect(find.byKey(const ValueKey('shell-copy-clear')), findsOneWidget);
  });

  testWidgets('a link the device refuses keeps the selection', (tester) async {
    stubUrlLauncher(takes: false);
    final session = _session();
    await _pumpView(tester, session);
    const url = 'https://min.io/docs';
    _write(session, url);
    _select(session, 0, url.length - 1, row: 0);
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('shell-open')));
    await tester.pumpAndSettle();

    expect(session.terminal.hasSelection, isTrue);
  });

  testWidgets('CLEAR lets the selection go', (tester) async {
    final session = _session();
    await _pumpView(tester, session);
    _write(session, 'revisar');
    _select(session, 0, 6, row: 0);
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('shell-copy-clear')));
    await tester.pump();

    expect(session.terminal.hasSelection, isFalse);
    expect(find.byKey(const ValueKey('shell-copy')), findsNothing);
  });

  testWidgets('nothing is drawn while there is no selection', (tester) async {
    final session = _session();
    await _pumpView(tester, session);

    expect(find.byKey(const ValueKey('shell-copy')), findsNothing);
  });
}
