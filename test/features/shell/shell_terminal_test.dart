import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/application/shell/shell_font.dart';
import 'package:upgrade/data/database.dart';
import 'package:upgrade/data/repositories/settings_repository.dart';
import 'package:upgrade/design/colors.dart';
import 'package:upgrade/features/shell/session/shell_engine.dart';
import 'package:upgrade/features/shell/input/shell_selection.dart';
import 'package:upgrade/features/shell/session/shell_sessions.dart';
import 'package:upgrade/platform/shell/shell_connection.dart';
import 'package:flterm/flterm.dart';

import '../../support/fake_shell.dart';
import '../../support/platform_channels.dart';
import '../../support/reasons.dart';
import '../../support/shell_route.dart';
import '../../support/themed_app.dart';

void main() {
  setUp(stubDeviceChannels);

  double fontSize(WidgetTester tester) =>
      tester.widget<TerminalView>(find.byType(TerminalView)).theme!.fontSize;

  /// The main buffer draws inside a [Scrollable], so a drag that reaches the terminal moves
  /// this and a drag the pinch ate does not.
  double scrollOffset(WidgetTester tester) => tester
      .state<ScrollableState>(
        find.descendant(
          of: find.byType(TerminalView),
          matching: find.byType(Scrollable),
        ),
      )
      .position
      .pixels;

  /// Fills the buffer past its viewport and lets the store decode it off the real event
  /// loop.
  Future<void> fill(WidgetTester tester, FakeShellTransport transport) async {
    final buffer = StringBuffer();
    for (var i = 0; i < 200; i++) {
      buffer.write('line $i\r\n');
    }
    transport.opened.single.emit(buffer.toString());
    await ready(tester);
  }

  /// Two steps: the first carries the span past the scale slop while each finger is still
  /// inside the drag slop, so the pinch is the gesture that wins and not a scroll.
  Future<void> pinch(
    WidgetTester tester, {
    required double from,
    required double to,
  }) async {
    final center = tester.getCenter(find.byType(TerminalView));
    final left = await tester.startGesture(center - Offset(from / 2, 0));
    final right = await tester.startGesture(center + Offset(from / 2, 0));
    await tester.pump();
    final perFinger = (to - from) / 2;
    var moved = 0.0;
    while ((perFinger - moved).abs() > 0.001) {
      final chunk = (perFinger - moved).clamp(-12.0, 12.0);
      await left.moveBy(Offset(-chunk, 0));
      await right.moveBy(Offset(chunk, 0));
      await tester.pump();
      moved += chunk;
    }
    await left.up();
    await right.up();
    await tester.pump();
  }

  group('the terminal is pinched to size', () {
    late AppDatabase db;

    setUp(() => db = AppDatabase(NativeDatabase.memory()));
    tearDown(() => db.close());

    testWidgets('the view opens at the default with no settings behind it', (
      tester,
    ) async {
      await tester.pumpWidget(app(fakeShellSessions(FakeShellTransport())));
      await ready(tester);

      expect(fontSize(tester), shellFontSizeDefault);

      await unmount(tester);
    });

    testWidgets('a spread grows the type and a close shrinks it', (
      tester,
    ) async {
      await tester.pumpWidget(
        app(fakeShellSessions(FakeShellTransport()), db: db),
      );
      await ready(tester);
      expect(fontSize(tester), 13);

      // The recognizer measures its starting span once it has accepted, a slop past where the
      // fingers landed.
      await pinch(tester, from: 100, to: 160);
      final grown = fontSize(tester);
      expect(grown, greaterThan(13));

      await pinch(tester, from: 160, to: 100);
      expect(fontSize(tester), lessThan(grown));

      await unmount(tester);
    });

    testWidgets('a pinch past either end lands on the end', (tester) async {
      await tester.pumpWidget(
        app(fakeShellSessions(FakeShellTransport()), db: db),
      );
      await ready(tester);

      await pinch(tester, from: 100, to: 400);
      expect(fontSize(tester), shellFontSizeMax);

      await pinch(tester, from: 200, to: 40);
      expect(fontSize(tester), shellFontSizeMin);

      await unmount(tester);
    });

    testWidgets('the size is written on the lift and read on the next open', (
      tester,
    ) async {
      final settings = SettingsRepository(db);
      await tester.pumpWidget(
        app(fakeShellSessions(FakeShellTransport()), db: db),
      );
      await ready(tester);

      await pinch(tester, from: 100, to: 160);
      await ready(tester);
      final drawn = fontSize(tester);
      expect(drawn, greaterThan(13));
      // A drift stream never emits inside the test's own event loop.
      final written = await tester.runAsync(
        () => settings
            .watchNumber(SettingsRepository.shellFontSize, orElse: 0)
            .first,
      );
      expect(written, drawn);
      await unmount(tester);

      await tester.pumpWidget(
        app(fakeShellSessions(FakeShellTransport()), db: db),
      );
      await ready(tester);
      expect(fontSize(tester), drawn);

      await unmount(tester);
    });

    testWidgets('one finger is a scroll, not a resize', (tester) async {
      final transport = FakeShellTransport();
      await tester.pumpWidget(app(fakeShellSessions(transport), db: db));
      await ready(tester);
      await fill(tester, transport);

      final before = scrollOffset(tester);
      // Horizontal first, past the pan slop the scale recognizer wins on while the vertical
      // drag is still inside its own.
      final center = tester.getCenter(find.byType(TerminalView));
      final finger = await tester.startGesture(center);
      await finger.moveBy(const Offset(50, 8));
      await tester.pump();
      await finger.moveBy(const Offset(0, 120));
      await tester.pump();
      await finger.up();
      await ready(tester);

      expect(fontSize(tester), 13);
      expect(scrollOffset(tester), isNot(before));

      await unmount(tester);
    });
  });

  group('the terminal copies a selection', () {
    late AppDatabase db;

    setUp(() => db = AppDatabase(NativeDatabase.memory()));
    tearDown(() => db.close());

    String? selected(ShellSession session) =>
        session.terminal.hasSelection ? session.terminal.selectedText() : null;

    void select(ShellSession session, int from, int to, {int row = 0}) =>
        session.terminal.selectRange(
          start: Position(row: row, col: from),
          end: Position(row: row, col: to),
          pointTag: PointTag.viewport,
        );

    Rect cellRect(WidgetTester tester, int x, int y) {
      final actions = find.byType(ShellSelectionActions);
      final overlay = find.ancestor(of: actions, matching: find.byType(Stack));
      final geometry = tester.widget<ShellSelectionActions>(actions).geometry!;
      return geometry
          .cellRect(Position(row: y, col: x))!
          .shift(tester.getTopLeft(overlay.first));
    }

    Offset cellAt(WidgetTester tester, int x, int y) =>
        cellRect(tester, x, y).center;

    Future<TestGesture> hold(WidgetTester tester, Offset at) async {
      final gesture = await tester.startGesture(at);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      return gesture;
    }

    Future<void> press(WidgetTester tester, Offset at) async {
      final gesture = await hold(tester, at);
      await tester.pump();
      await gesture.up();
      await ready(tester);
    }

    testWidgets('a selection raises COPY, which lifts the text and clears', (
      tester,
    ) async {
      final writes = recordClipboardWrites();
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions, db: db));
      await ready(tester);

      transport.opened.single.emit('copyme\r\n');
      await ready(tester);

      expect(find.byKey(const ValueKey('shell-copy')), findsNothing);

      final session = sessions.activeFor(rose.id)!;
      select(session, 0, 5);
      await tester.pump();
      expect(selected(session), 'copyme');

      expect(find.byKey(const ValueKey('shell-copy')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('shell-copy')));
      await tester.pump();

      expect(writes, ['copyme']);
      expect(session.terminal.hasSelection, isFalse);
      expect(find.byKey(const ValueKey('shell-copy')), findsNothing);

      await unmount(tester);
    });

    testWidgets('a long press takes the word under it, with one tick', (
      tester,
    ) async {
      final haptics = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'HapticFeedback.vibrate') {
              haptics.add(call.arguments as String);
            }
            return null;
          });

      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions, db: db));
      await ready(tester);
      transport.opened.single.emit('one   two three\r\n');
      await ready(tester);
      final session = sessions.activeFor(rose.id)!;

      final gesture = await hold(tester, cellAt(tester, 7, 0));
      await tester.pump();
      expect(selected(session), 'two');
      expect(haptics, ['HapticFeedbackType.selectionClick']);

      await gesture.moveTo(cellAt(tester, 12, 0));
      await tester.pump();
      expect(selected(session), 'two three');

      await gesture.up();
      await tester.pump();
      expect(haptics, hasLength(1));
      expect(find.byKey(const ValueKey('shell-copy')), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('a long press is not a click on the application under it', (
      tester,
    ) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions, db: db));
      await ready(tester);
      transport.opened.single.emit('\x1b[?1002h\x1b[?1006hword\r\n');
      await ready(tester);
      final session = sessions.activeFor(rose.id)!;

      final gesture = await hold(tester, cellAt(tester, 1, 0));
      await tester.pump();
      await gesture.moveTo(cellAt(tester, 5, 0));
      await tester.pump();
      await gesture.up();
      await ready(tester);

      expect(selected(session), 'word');
      expect(transport.opened.single.written, isEmpty);
      expect(find.byKey(const ValueKey('shell-copy')), findsOneWidget);

      await unmount(tester);
    });

    /// A sidebar, a pane and a pane beside it, split by rules the way a multiplexer
    /// draws them on the alternate screen.
    String panes(List<String> middle) {
      final rows = StringBuffer('\x1b[?1049h\x1b[?1002h\x1b[?1006h');
      for (var row = 0; row < 6; row++) {
        final text = row < middle.length ? middle[row] : '';
        rows.write(
          '\x1b[${row + 1};1H${'side'.padRight(10)}│'
          '${text.padRight(19)}│right',
        );
      }
      return rows.toString();
    }

    testWidgets('a selection keeps to the pane it was pressed in', (
      tester,
    ) async {
      final writes = recordClipboardWrites();
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions, db: db));
      await ready(tester);
      transport.opened.single.emit(
        panes(['alpha one', 'beta two', 'gamma', 'a' * 19, 'bbb']),
      );
      await ready(tester);
      final session = sessions.activeFor(rose.id)!;

      final gesture = await hold(tester, cellAt(tester, 12, 0));
      await tester.pump();
      await gesture.moveTo(cellAt(tester, 3, 4));
      await tester.pump();
      await gesture.up();
      await ready(tester);

      final frame = session.terminal.selectionFrame!;
      expect(frame.start, const Position(row: 0, col: 11));
      expect(frame.end.col, 29);
      expect(selected(session), 'alpha one\nbeta two\ngamma\n${'a' * 19}bbb');
      expect(transport.opened.single.written, isEmpty);

      final actions = tester.widget<ShellSelectionActions>(
        find.byType(ShellSelectionActions),
      );
      final rows = actions.geometry!.selectionRects(
        selectionOf(session.terminal)!,
        frame: frame,
      );
      final first = cellRect(tester, 11, 0).left;
      final last = cellRect(tester, 29, 0).right;
      final origin = tester.getTopLeft(
        find
            .ancestor(
              of: find.byType(ShellSelectionActions),
              matching: find.byType(Stack),
            )
            .first,
      );
      for (final row in rows) {
        expect(row.left + origin.dx, greaterThanOrEqualTo(first - 0.01));
        expect(row.right + origin.dx, lessThanOrEqualTo(last + 0.01));
      }

      await tester.tap(find.byKey(const ValueKey('shell-copy')));
      await tester.pump(const Duration(seconds: 1));
      expect(writes, ['alpha one\nbeta two\ngamma\n${'a' * 19}bbb']);

      await unmount(tester);
    });

    testWidgets(
      'tmux drawing over the primary screen still has panes, and a table in one is not an edge',
      (tester) async {
        final transport = FakeShellTransport();
        final sessions = fakeShellSessions(transport);
        await tester.pumpWidget(app(sessions, db: db));
        await ready(tester);
        transport.opened.single.emit(
          panes(['alpha one', '├${'─' * 17}┤', 'beta'])
              .replaceFirst('\x1b[?1049h', ''),
        );
        await ready(tester);
        final session = sessions.activeFor(rose.id)!;

        final gesture = await hold(tester, cellAt(tester, 12, 0));
        await tester.pump();
        await gesture.moveTo(cellAt(tester, 3, 2));
        await tester.pump();
        await gesture.up();
        await ready(tester);

        expect(session.terminal.selectionFrame?.start.col, 11);
        expect(selected(session), 'alpha one\n├${'─' * 17}┤\nbeta');
        expect(transport.opened.single.written, isEmpty);

        await unmount(tester);
      },
    );

    testWidgets('a rule in a shell\'s output does not cut a selection', (
      tester,
    ) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions, db: db));
      await ready(tester);
      transport.opened.single.emit(
        panes(['alpha']).replaceFirst('\x1b[?1049h\x1b[?1002h', ''),
      );
      await ready(tester);
      final session = sessions.activeFor(rose.id)!;

      await press(tester, cellAt(tester, 12, 0));

      expect(session.terminal.selectionFrame, isNull);
      expect(selected(session), 'alpha');

      await unmount(tester);
    });

    testWidgets('a hold over a selection takes another word, not a click', (
      tester,
    ) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions, db: db));
      await ready(tester);
      transport.opened.single.emit(
        '\x1b[?1000h\x1b[?1006hword${'\r\n' * 10}other\r\n',
      );
      await ready(tester);
      final session = sessions.activeFor(rose.id)!;

      select(session, 0, 3);
      await tester.pump();
      await press(tester, cellAt(tester, 1, 10));

      expect(session.terminal.selectedText(), 'other');
      expect(transport.opened.single.written, isEmpty);

      await tester.tapAt(cellAt(tester, 6, 20));
      await ready(tester);
      expect(session.terminal.hasSelection, isFalse);
      expect(transport.opened.single.written, isEmpty);

      await tester.tapAt(cellAt(tester, 6, 20));
      await ready(tester);
      expect(transport.opened.single.written, '\x1b[<0;7;21M\x1b[<0;7;21m');

      await unmount(tester);
    });

    testWidgets('a copy from the host lands on the clipboard, and only that', (
      tester,
    ) async {
      final writes = recordClipboardWrites();
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions, db: db));
      await ready(tester);

      String osc52(String target, String text) =>
          '\x1b]52;$target;${base64.encode(utf8.encode(text))}\x07';
      transport.opened.single.emit(
        '${osc52('p', 'primary')}${osc52('c', 'from herdr')}\x1b]52;c;?\x07'
        '\x1b]52;c;!\x07',
      );
      await ready(tester);

      expect(writes, ['from herdr']);
      expect(transport.opened.single.written, isEmpty);

      await unmount(tester);
    });

    testWidgets(
      'a click names a row of the screen, not one of the scrollback',
      (tester) async {
        final transport = FakeShellTransport();
        final sessions = fakeShellSessions(transport);
        await tester.pumpWidget(app(sessions, db: db));
        await ready(tester);
        transport.opened.single.emit('\x1b[?1000h\x1b[?1006h');
        await fill(tester, transport);
        final bar = sessions.activeFor(rose.id)!.terminal.scrollbar;
        expect(bar.total, greaterThan(bar.visible));

        await tester.tapAt(cellAt(tester, 1, 2));
        await ready(tester);
        expect(transport.opened.single.written, '\x1b[<0;2;3M\x1b[<0;2;3m');

        await unmount(tester);
      },
    );

    testWidgets('a tap on a held frame still reaches a mouse application', (
      tester,
    ) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions, db: db));
      await ready(tester);
      transport.opened.single.emit('\x1b[?1000h\x1b[?1006hword\r\n');
      await ready(tester);
      final session = sessions.activeFor(rose.id)!;

      transport.opened.single.emit('\x1b[?2026h\x1b[2J\x1b[Hredraw');
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(session.terminal.modeGet(const TerminalMode.syncOutput()), isTrue);

      await tester.tapAt(cellAt(tester, 1, 0));
      await tester.pump();
      expect(transport.opened.single.written, '\x1b[<0;2;1M\x1b[<0;2;1m');
      expect(session.terminal.modeGet(const TerminalMode.syncOutput()), isTrue);

      await unmount(tester);
    });

    Rect pill(WidgetTester tester) => tester.getRect(
      find
          .ancestor(
            of: find.byKey(const ValueKey('shell-copy')),
            matching: find.byType(DecoratedBox),
          )
          .first,
    );

    testWidgets('COPY sits over the selected word, on it and not in a corner', (
      tester,
    ) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions, db: db));
      await ready(tester);
      transport.opened.single.emit('${'\r\n' * 8}${' ' * 10}copyme\r\n');
      await ready(tester);

      await press(tester, cellAt(tester, 12, 8));

      final box = pill(tester);
      final cell = cellRect(tester, 12, 8);
      expect(box.bottom, lessThan(cell.top));
      expect(box.bottom, greaterThan(cell.top - cell.height * 2));
      final word = (cellAt(tester, 10, 8).dx + cellAt(tester, 15, 8).dx) / 2;
      expect(box.center.dx, moreOrLessEquals(word, epsilon: 1));

      await unmount(tester);
    });

    testWidgets('a word on the top line puts COPY under it', (tester) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions, db: db));
      await ready(tester);
      transport.opened.single.emit('copyme\r\n');
      await ready(tester);

      await press(tester, cellAt(tester, 2, 0));

      final cell = cellRect(tester, 2, 0);
      expect(pill(tester).top, greaterThan(cell.bottom));
      expect(pill(tester).top, lessThan(cell.bottom + cell.height * 3));

      await unmount(tester);
    });

    testWidgets('output arriving under a held finger leaves the selection on '
        'its words', (tester) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions, db: db));
      await ready(tester);
      final shell = transport.opened.single;
      final session = sessions.activeFor(rose.id)!;

      final last = session.terminal.scrollbar.visible - 1;
      shell.emit('${'\r\n' * last}alpha bravo');
      await ready(tester);

      final gesture = await hold(tester, cellAt(tester, 1, last));
      await tester.pump();
      expect(selected(session), 'alpha');

      shell.emit('\r\nline a\r\nline b');
      await ready(tester);
      expect(selected(session), 'alpha');

      await gesture.up();
      await ready(tester);
      expect(selected(session), 'alpha');
      await unmount(tester);
    });

    testWidgets('a second finger does not move where the first one landed', (
      tester,
    ) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions, db: db));
      await ready(tester);
      transport.opened.single.emit('alpha bravo charlie\r\n');
      await ready(tester);
      final session = sessions.activeFor(rose.id)!;

      final one = await tester.startGesture(cellAt(tester, 1, 0), pointer: 1);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      expect(selected(session), 'alpha');

      final two = await tester.startGesture(cellAt(tester, 14, 0), pointer: 2);
      await tester.pump();
      await one.moveTo(cellAt(tester, 8, 0));
      await tester.pump();
      expect(selected(session), 'alpha bravo');

      await two.up();
      await one.up();
      await ready(tester);
      await unmount(tester);
    });

    testWidgets('a press takes the run it lands in, a URL with it', (
      tester,
    ) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions, db: db));
      await ready(tester);
      transport.opened.single.emit('see url=https://x.dev/a/b?c=1 (done).\r\n');
      await ready(tester);
      final session = sessions.activeFor(rose.id)!;

      await press(tester, cellAt(tester, 18, 0));
      expect(selected(session), 'url=https://x.dev/a/b?c=1');

      await press(tester, cellAt(tester, 32, 0));
      expect(selected(session), 'done');

      await unmount(tester);
    });

    testWidgets('a URL broken over a soft wrap is still one press', (
      tester,
    ) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions, db: db));
      await ready(tester);
      final session = sessions.activeFor(rose.id)!;
      final url = 'https://x.dev/${'a' * 300}';
      transport.opened.single.emit('$url\r\n');
      await ready(tester);

      await press(tester, cellAt(tester, 5, 0));

      expect(selected(session), url);

      await unmount(tester);
    });

    testWidgets('a press on a full-screen application takes the word under '
        'the finger after the keyboard has been up', (tester) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions, db: db));
      await ready(tester);
      final shell = transport.opened.single;
      final session = sessions.activeFor(rose.id)!;
      final terminal = session.terminal;

      shell.emit('\x1b[?1049h');
      await ready(tester);
      final tall = terminal.scrollbar.visible;
      shell.emit(List.generate(tall, (i) => 'row$i').join('\r\n'));
      await ready(tester);

      tester.view.viewInsets = const FakeViewPadding(bottom: 400);
      await ready(tester);
      expect(terminal.scrollbar.visible, lessThan(tall));
      tester.view.viewInsets = FakeViewPadding.zero;
      await ready(tester);

      final third = activeRows(terminal)[2].trimRight();
      await press(tester, cellAt(tester, 1, 2));

      expect(selected(session), third);

      await unmount(tester);
    });

    testWidgets('the highlight is a wash the text shows through', (
      tester,
    ) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions, db: db));
      await ready(tester);

      final selection = tester
          .widget<TerminalView>(find.byType(TerminalView))
          .theme!
          .selection;
      final wash = selection.background!.fixedColor!;
      expect(wash.a, lessThan(0.5));
      expect(wash.withValues(alpha: 1), UpgradeColors.accent);
      expect(selection.foreground, isNull);

      await unmount(tester);
    });

    testWidgets('CLEAR drops the selection without copying', (tester) async {
      final writes = recordClipboardWrites();
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions, db: db));
      await ready(tester);

      transport.opened.single.emit('copyme\r\n');
      await ready(tester);

      final session = sessions.activeFor(rose.id)!;
      select(session, 0, 5);
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('shell-copy-clear')));
      await tester.pump();

      expect(writes, isEmpty);
      expect(session.terminal.hasSelection, isFalse);
      expect(find.byKey(const ValueKey('shell-copy')), findsNothing);

      await unmount(tester);
    });
  });

  group('a Herdr pane over Mosh', () {
    testWidgets('keeps taps and scrolls as remote mouse input', (tester) async {
      final transport = FakeShellTransport()..transport = ShellTransport.mosh;
      final sessions = fakeShellSessions(transport);
      const pane = (session: 'default', pane: 'w1:p1');
      sessions.open(intent: testIntent(), rose, command: 'attach', pane: pane);
      await tester.pumpWidget(app(sessions));
      await ready(tester);
      final connection = transport.opened.single;

      // Mosh rejects mode 1003 after a TUI first enables mode 1002. Its fallback disables
      // 1002, leaving the outer terminal with no mouse mode.
      connection.emit('\x1b[?1049h\x1b[?1002h\x1b[?1002l\x1b[?1006hHerdr');
      await ready(tester);

      final view = find.byType(TerminalView);
      await tester.tapAt(tester.getCenter(view));
      await ready(tester);
      expect(connection.written, contains(RegExp(r'\x1b\[<0;\d+;\d+M')));
      expect(connection.written, contains(RegExp(r'\x1b\[<0;\d+;\d+m')));

      connection.writes.clear();
      await tester.drag(view, const Offset(0, -120));
      await ready(tester);
      expect(connection.written, contains(RegExp(r'\x1b\[<65;\d+;\d+M')));
      expect(connection.written, isNot(contains('\x1b[B')));

      await unmount(tester);
    });
  });

  group('a normal-buffer application with mouse reporting', () {
    testWidgets('a drag sends wheel input instead of opening redraw history', (
      tester,
    ) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions));
      await ready(tester);
      final connection = transport.opened.single;
      final session = sessions.activeFor(rose.id)!;

      connection.emit('line\r\n' * 200);
      await ready(tester);
      connection.emit('\x1b[?1002h\x1b[?1006h');
      await ready(tester);
      expect(session.terminal.activeScreen, TerminalScreen.primary);
      expect(session.terminal.mouseTracking, isNot(MouseTracking.none));

      final before = session.scrollController.position.pixels;
      await tester.drag(find.byType(TerminalView), const Offset(0, 120));
      await ready(tester);

      expect(connection.written, contains(RegExp(r'\x1b\[<64;\d+;\d+M')));
      expect(session.scrollController.position.pixels, before);

      connection.writes.clear();
      connection.emit('\x1b[?1002l');
      await ready(tester);
      await tester.drag(find.byType(TerminalView), const Offset(0, 120));
      await ready(tester);

      expect(connection.written, isEmpty);
      expect(session.scrollController.position.pixels, lessThan(before));

      await unmount(tester);
    });

    testWidgets('turning reporting on under a finger does not take the drag', (
      tester,
    ) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions));
      await ready(tester);
      final connection = transport.opened.single;
      final session = sessions.activeFor(rose.id)!;

      connection.emit('line\r\n' * 200);
      await ready(tester);
      expect(session.terminal.mouseTracking, MouseTracking.none);

      // The first twenty pixels go to the gesture arena's touch slop, so the finger is walked
      // down in steps rather than thrown in one move.
      final start = session.scrollController.position.pixels;
      final finger = await tester.startGesture(
        tester.getCenter(find.byType(TerminalView)),
      );
      for (var i = 0; i < 4; i++) {
        await finger.moveBy(const Offset(0, 20));
        await tester.pump();
      }
      final moved = session.scrollController.position.pixels;
      expect(moved, lessThan(start));

      connection.emit('\x1b[?1002h\x1b[?1006h');
      await tester.pump();
      expect(session.terminal.mouseTracking, isNot(MouseTracking.none));

      for (var i = 0; i < 4; i++) {
        await finger.moveBy(const Offset(0, 20));
        await tester.pump();
      }
      expect(session.scrollController.position.pixels, lessThan(moved));

      await finger.up();
      await ready(tester);
      await tester.drag(find.byType(TerminalView), const Offset(0, 120));
      await ready(tester);
      expect(connection.written, contains(RegExp(r'\x1b\[<6[45];\d+;\d+M')));

      await unmount(tester);
    });

    testWidgets('the wheel survives the scrollable being handed a new '
        'position', (tester) async {
      addTearDown(tester.view.reset);
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions));
      await ready(tester);
      final connection = transport.opened.single;

      connection.emit('line\r\n' * 200);
      await ready(tester);
      connection.emit('\x1b[?1002h\x1b[?1006h');
      await ready(tester);

      Future<String> wheel() async {
        connection.writes.clear();
        await tester.drag(find.byType(TerminalView), const Offset(0, 120));
        await ready(tester);
        return connection.written;
      }

      final wheelReport = contains(RegExp(r'\x1b\[<64;\d+;\d+M'));
      expect(await wheel(), wheelReport);

      // A theme animation and a screen the app is moved onto each rebuild the scrollable's
      // position out from under the render object that reads it.
      await tester.pumpWidget(
        app(
          sessions,
          theme: testTheme.copyWith(
            colorScheme: testTheme.colorScheme.copyWith(
              primary: UpgradeColors.accentMuted,
            ),
          ),
        ),
      );
      await ready(tester);
      expect(await wheel(), wheelReport);

      tester.view.devicePixelRatio = 2;
      await ready(tester);
      expect(await wheel(), wheelReport);

      await unmount(tester);
    });
  });

  group('the way back to the live line', () {
    Future<ShellSession> filled(
      WidgetTester tester,
      FakeShellTransport transport,
      ShellSessions sessions,
    ) async {
      await tester.pumpWidget(app(sessions));
      await ready(tester);
      transport.opened.single.emit('line\r\n' * 200);
      await ready(tester);
      return sessions.activeFor(rose.id)!;
    }

    void scrollUp(ShellSession session) {
      final position = session.scrollController.position;
      session.scrollController.jumpTo(position.maxScrollExtent - 200);
    }

    final tail = find.byKey(const ValueKey('shell-tail'));

    testWidgets('nothing to offer while the last line is on the screen', (
      tester,
    ) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      final session = await filled(tester, transport, sessions);

      expect(session.scrollController.position.extentAfter, 0);
      expect(tail, findsNothing);

      await unmount(tester);
    });

    testWidgets('a view dragged off the last line offers the way back', (
      tester,
    ) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      final session = await filled(tester, transport, sessions);

      await tester.drag(find.byType(TerminalView), const Offset(0, 200));
      await tester.pump();

      expect(tail, findsOneWidget);
      expect(
        tester.getSize(tail).width,
        lessThan(tester.getSize(find.byType(TerminalView)).width / 2),
      );

      await tester.tap(tail);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final position = session.scrollController.position;
      expect(position.pixels, position.maxScrollExtent);
      expect(tail, findsNothing);

      await unmount(tester);
    });

    testWidgets('output printed under a reader moves neither the view nor the '
        'cell', (tester) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      final session = await filled(tester, transport, sessions);

      scrollUp(session);
      await tester.pump();
      final at = session.scrollController.position.pixels;
      expect(tail, findsOneWidget);

      transport.opened.single.emit('more\r\n' * 20);
      await ready(tester);

      expect(session.scrollController.position.pixels, at);
      expect(tail, findsOneWidget);

      await unmount(tester);
    });

    testWidgets('a key from the bar puts the view back on the last line', (
      tester,
    ) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      final session = await filled(tester, transport, sessions);

      scrollUp(session);
      await tester.pump();
      expect(tail, findsOneWidget);

      await tester.tap(find.text('ESC'));
      await tester.pump();

      final position = session.scrollController.position;
      expect(position.pixels, position.maxScrollExtent);
      expect(tail, findsNothing);

      await unmount(tester);
    });

    testWidgets('the corner belongs to the selection while there is one', (
      tester,
    ) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      final session = await filled(tester, transport, sessions);

      scrollUp(session);
      await tester.pump();
      expect(tail, findsOneWidget);

      session.terminal.selectRange(
        start: const Position(row: 0, col: 0),
        end: const Position(row: 0, col: 3),
        pointTag: PointTag.viewport,
      );
      await tester.pump();

      expect(find.byKey(const ValueKey('shell-copy')), findsOneWidget);
      expect(tail, findsNothing);

      session.terminal.clearSelection();
      await tester.pump();
      expect(tail, findsOneWidget);

      await unmount(tester);
    });
  });
}
