import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/application/shell_font.dart';
import 'package:dazzle/data/database.dart';
import 'package:dazzle/data/repositories/settings_repository.dart';
import 'package:dazzle/design/colors.dart';
import 'package:dazzle/features/shell/shell_sessions.dart';
import 'package:dazzle/platform/shell/shell_connection.dart';
import 'package:xterm/xterm.dart';

import 'support/fake_shell.dart';
import 'support/platform_channels.dart';
import 'support/shell_route.dart';
import 'support/themed_app.dart';

void main() {
  setUp(stubDeviceChannels);

  double fontSize(WidgetTester tester) =>
      tester.widget<TerminalView>(find.byType(TerminalView)).textStyle.fontSize;

  /// Where the terminal's own scroll sits. The main buffer draws inside a
  /// [Scrollable], so a drag that reaches the terminal moves this and a drag
  /// the pinch ate does not.
  double scrollOffset(WidgetTester tester) => tester
      .state<ScrollableState>(
        find.descendant(
          of: find.byType(TerminalView),
          matching: find.byType(Scrollable),
        ),
      )
      .position
      .pixels;

  /// Fills the buffer past its viewport so there is a scrollback to move into,
  /// and lets the store decode it off the real event loop.
  Future<void> fill(WidgetTester tester, FakeShellTransport transport) async {
    final buffer = StringBuffer();
    for (var i = 0; i < 200; i++) {
      buffer.write('line $i\r\n');
    }
    transport.opened.single.emit(buffer.toString());
    await ready(tester);
  }

  /// Two fingers on the view, `from` apart, moved to `to` apart along the row
  /// and lifted. Two steps: the first carries the span past the scale slop
  /// while each finger is still inside the drag slop, so the pinch is the
  /// gesture that wins and not a scroll.
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

      // The recognizer measures its starting span once it has accepted, a
      // slop past where the fingers landed, so the size is asserted by
      // direction and not by the ratio the fingers drew.
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
      // The row is read off the real event loop: a drift stream never emits
      // inside the test's own.
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
      // Horizontal first, past the pan slop the scale recognizer wins on while
      // the vertical drag is still inside its own: this is the diagonal swipe a
      // thumb draws on glass, the one the old pinch handler ate.
      final center = tester.getCenter(find.byType(TerminalView));
      final finger = await tester.startGesture(center);
      await finger.moveBy(const Offset(50, 8));
      await tester.pump();
      await finger.moveBy(const Offset(0, 120));
      await tester.pump();
      await finger.up();
      await ready(tester);

      // The type is untouched and the buffer has moved: the drag reached the
      // terminal instead of the resize.
      expect(fontSize(tester), 13);
      expect(scrollOffset(tester), isNot(before));

      await unmount(tester);
    });
  });

  group('the terminal copies a selection', () {
    late AppDatabase db;

    setUp(() => db = AppDatabase(NativeDatabase.memory()));
    tearDown(() => db.close());

    testWidgets('a selection raises COPY, which lifts the text and clears', (
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

      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions, db: db));
      await ready(tester);

      transport.opened.single.emit('copyme\r\n');
      await ready(tester);

      // Nothing selected, nothing to copy.
      expect(find.byKey(const ValueKey('shell-copy')), findsNothing);

      final session = sessions.activeFor(rose.id)!;
      final buffer = session.terminal.buffer;
      session.controller.setSelection(
        buffer.createAnchor(0, 0),
        buffer.createAnchor(6, 0),
      );
      await tester.pump();
      final selected = buffer.getText(session.controller.selection);
      expect(selected, isNotEmpty);

      expect(find.byKey(const ValueKey('shell-copy')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('shell-copy')));
      await tester.pump();

      expect(copied, selected);
      // The copy takes the selection with it, so the cell goes too.
      expect(session.controller.selection, isNull);
      expect(find.byKey(const ValueKey('shell-copy')), findsNothing);

      await unmount(tester);
    });

    /// Where a cell sits on screen, through the render object that paints it.
    Offset cellAt(WidgetTester tester, int x, int y) {
      final render = tester
          .state<TerminalViewState>(find.byType(TerminalView))
          .renderTerminal;
      final cell = render.getOffset(CellOffset(x, y));
      final size = render.cellSize;
      return render.localToGlobal(
        cell + Offset(size.width / 2, size.height / 2),
      );
    }

    /// A finger held past the long-press timeout, still down on return.
    Future<TestGesture> hold(WidgetTester tester, Offset at) async {
      final gesture = await tester.startGesture(at);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      return gesture;
    }

    testWidgets('a press on a gap still takes, and the drag follows the finger '
        'across the next one', (tester) async {
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
      String selected() =>
          session.terminal.buffer.getText(session.controller.selection);

      // Column 4 is the middle of the three spaces between one and two: a
      // space with a word to one side counts as that word, so only this cell
      // is a gap in the buffer's eyes.
      final gesture = await hold(tester, cellAt(tester, 4, 0));
      await tester.pump();
      expect(selected(), ' ');
      expect(haptics, ['HapticFeedbackType.selectionClick']);

      // Across the next space: the range grows to it rather than waiting for
      // the finger to land on a word.
      await gesture.moveTo(cellAt(tester, 5, 0));
      await tester.pump();
      expect(selected(), '  ');

      // On to a word, and the whole of it comes in.
      await gesture.moveTo(cellAt(tester, 7, 0));
      await tester.pump();
      expect(selected(), '  two');

      // Growing the selection is one press, one tick.
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
      // The shell turns mouse reporting on, the way a TUI does.
      transport.opened.single.emit('\x1b[?1000h\x1b[?1006hword\r\n');
      await ready(tester);
      final session = sessions.activeFor(rose.id)!;

      final gesture = await hold(tester, cellAt(tester, 1, 0));
      await tester.pump();
      await gesture.up();
      await ready(tester);
      expect(session.controller.selection, isNotNull);
      expect(transport.opened.single.written, isEmpty);

      // A tap is still a click, press and release together, and it drops the
      // selection.
      await tester.tapAt(cellAt(tester, 1, 0));
      await ready(tester);
      expect(session.controller.selection, isNull);
      expect(transport.opened.single.written, '\x1b[<0;2;1M\x1b[<0;2;1m');

      await unmount(tester);
    });

    /// The COPY / CLEAR cell as one box, and the top edge of a cell on the
    /// terminal, both on the screen.
    Rect pill(WidgetTester tester) => tester.getRect(
      find
          .ancestor(
            of: find.byKey(const ValueKey('shell-copy')),
            matching: find.byType(DecoratedBox),
          )
          .first,
    );
    double cellTop(WidgetTester tester, int y) {
      final render = tester
          .state<TerminalViewState>(find.byType(TerminalView))
          .renderTerminal;
      return cellAt(tester, 0, y).dy - render.cellSize.height / 2;
    }

    testWidgets('COPY sits over the selected word, on it and not in a corner', (
      tester,
    ) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions, db: db));
      await ready(tester);
      transport.opened.single.emit('${'\r\n' * 8}${' ' * 10}copyme\r\n');
      await ready(tester);

      final gesture = await hold(tester, cellAt(tester, 12, 8));
      await tester.pump();
      await gesture.up();
      await ready(tester);

      final box = pill(tester);
      final top = cellTop(tester, 8);
      final render = tester
          .state<TerminalViewState>(find.byType(TerminalView))
          .renderTerminal;
      // Just over the line, and centred on the word.
      expect(box.bottom, lessThan(top));
      expect(box.bottom, greaterThan(top - render.cellSize.height * 2));
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

      final gesture = await hold(tester, cellAt(tester, 2, 0));
      await tester.pump();
      await gesture.up();
      await ready(tester);

      final render = tester
          .state<TerminalViewState>(find.byType(TerminalView))
          .renderTerminal;
      final bottom = cellTop(tester, 0) + render.cellSize.height;
      expect(pill(tester).top, greaterThan(bottom));
      expect(pill(tester).top, lessThan(bottom + render.cellSize.height * 2));

      await unmount(tester);
    });

    testWidgets('a grip on either end of the selection drags that end', (
      tester,
    ) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions, db: db));
      await ready(tester);
      transport.opened.single.emit('one two three\r\n');
      await ready(tester);
      final session = sessions.activeFor(rose.id)!;
      String selected() =>
          session.terminal.buffer.getText(session.controller.selection!);
      final render = tester
          .state<TerminalViewState>(find.byType(TerminalView))
          .renderTerminal;
      final cell = render.cellSize;

      final gesture = await hold(tester, cellAt(tester, 5, 0));
      await tester.pump();
      await gesture.up();
      await ready(tester);
      expect(selected(), 'two');

      // The grips stand on the word's edges, their bars down the line.
      final begin = find.byKey(const ValueKey('shell-select-begin'));
      final end = find.byKey(const ValueKey('shell-select-end'));
      expect(
        tester.getRect(begin).center.dx,
        moreOrLessEquals(cellAt(tester, 4, 0).dx - cell.width / 2, epsilon: 1),
      );
      expect(
        tester.getRect(end).center.dx,
        moreOrLessEquals(cellAt(tester, 6, 0).dx + cell.width / 2, epsilon: 1),
      );
      expect(tester.getRect(begin).top, moreOrLessEquals(cellTop(tester, 0)));

      // The end grip out to the last word, then the begin grip back to the
      // first; the other end holds.
      await tester.drag(end, Offset(cell.width * 5, 0));
      await ready(tester);
      expect(selected(), 'two three');
      await tester.drag(begin, Offset(-cell.width * 4, 0));
      await ready(tester);
      expect(selected(), 'one two three');

      // Past the other end: the range turns round rather than collapsing.
      await tester.drag(begin, Offset(cell.width * 12, 0));
      await ready(tester);
      expect(selected(), 'e');

      await unmount(tester);
    });

    testWidgets('a grip keeps its end when the scrollback rolls out from '
        'under it', (tester) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions, db: db));
      await ready(tester);
      final shell = transport.opened.single;
      final session = sessions.activeFor(rose.id)!;
      final terminal = session.terminal;
      String selected() =>
          terminal.buffer.getText(session.controller.selection!);
      int rowOfWords() {
        for (var y = terminal.buffer.height - 1; y >= 0; y--) {
          final text = terminal.buffer.getText(
            BufferRangeLine(
              CellOffset(0, y),
              CellOffset(terminal.viewWidth, y),
            ),
          );
          if (text.trimRight() == 'one two three') return y;
        }
        return -1;
      }

      // Fill the scrollback to the brim: from here on every line printed drops
      // one off the top, and the index of every line still in the buffer walks
      // down by one with it.
      shell.emit('${'filler\r\n' * shellScrollback}one two three\r\n');
      await ready(tester);
      expect(terminal.buffer.height, shellScrollback);
      final before = rowOfWords();

      final press = await hold(tester, cellAt(tester, 5, before));
      await press.up();
      await ready(tester);
      expect(selected(), 'two');

      // The end grip goes down, and two lines arrive before the finger moves.
      final grip = find.byKey(const ValueKey('shell-select-end'));
      final drag = await tester.startGesture(tester.getRect(grip).center);
      await tester.pump();
      shell.emit('\r\ntail a\r\ntail b');
      await ready(tester);
      final after = rowOfWords();
      expect(after, before - 2);

      // The finger carries the far end out to the last word. The near end is
      // where the grip started, and a row number taken back then now points
      // two lines below the words.
      await drag.moveTo(cellAt(tester, 12, after));
      await ready(tester);
      expect(selected(), 'two three');

      await drag.up();
      await ready(tester);
      await unmount(tester);
    });

    testWidgets('output arriving under a held finger leaves the press where '
        'it landed', (tester) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions, db: db));
      await ready(tester);
      final shell = transport.opened.single;
      shell.emit('target\r\n');
      await ready(tester);
      final session = sessions.activeFor(rose.id)!;

      // The finger goes down on the word, then the shell prints past the
      // bottom of the view before the half second is up. The buffer scrolls
      // under the finger, so by the time the long press is reported the pixel
      // it is on covers a line that was not there when it landed.
      final gesture = await tester.startGesture(cellAt(tester, 2, 0));
      shell.emit(
        List.generate(
          session.terminal.viewHeight + 10,
          (i) => 'line $i\r\n',
        ).join(),
      );
      await ready(tester);
      await gesture.up();
      await ready(tester);

      expect(
        session.terminal.buffer.getText(session.controller.selection),
        'target',
      );

      await unmount(tester);
    });

    testWidgets('the press keeps its end while the shell prints under the '
        'drag', (tester) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions, db: db));
      await ready(tester);
      final shell = transport.opened.single;
      final session = sessions.activeFor(rose.id)!;
      String selected() =>
          session.terminal.buffer.getText(session.controller.selection);

      // On the last row of a full view, so the next line printed scrolls
      // rather than filling empty space below.
      final last = session.terminal.viewHeight - 1;
      shell.emit('${'\r\n' * last}alpha bravo');
      await ready(tester);

      final gesture = await hold(tester, cellAt(tester, 1, last));
      await tester.pump();
      expect(selected(), 'alpha');

      // Two lines arrive while the finger is still down, then it moves out to
      // the second word. The far end is the finger's, the near end the
      // press's, and the press's must not have gone down with the scroll.
      shell.emit('\r\nline a\r\nline b');
      await ready(tester);
      await gesture.moveTo(cellAt(tester, 7, last));
      await tester.pump();
      expect(selected(), 'alpha bravo');

      await gesture.up();
      await ready(tester);
      await unmount(tester);
    });

    testWidgets('a press whose line leaves the scrollback stops moving the '
        'selection', (tester) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions, db: db));
      await ready(tester);
      final shell = transport.opened.single;
      final session = sessions.activeFor(rose.id)!;
      final terminal = session.terminal;

      shell.emit('${'filler\r\n' * shellScrollback}alpha bravo\r\n');
      await ready(tester);
      final row = terminal.buffer.height - 2;

      final gesture = await hold(tester, cellAt(tester, 1, row));
      await tester.pump();
      expect(terminal.buffer.getText(session.controller.selection!), 'alpha');

      // A whole scrollback's worth of output while the finger is down: the
      // held line is gone, and with it both the selection's ends and the
      // press's own cell. The drag has nothing to come from, so it lets go
      // rather than reading a row number the buffer no longer answers for.
      shell.emit('gone\r\n' * shellScrollback);
      await ready(tester);
      expect(session.controller.selection, isNull);
      await gesture.moveTo(cellAt(tester, 2, terminal.buffer.height - 2));
      await tester.pump();
      expect(session.controller.selection, isNull);

      await gesture.up();
      await ready(tester);
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
      String selected() =>
          session.terminal.buffer.getText(session.controller.selection);

      final one = await tester.startGesture(cellAt(tester, 1, 0), pointer: 1);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      expect(selected(), 'alpha');

      // The long press has already won the arena, so the second finger never
      // reaches the recognizer — but it is a pointer down all the same, and it
      // must not take the anchor off the word the first one is holding.
      final two = await tester.startGesture(cellAt(tester, 14, 0), pointer: 2);
      await tester.pump();
      await one.moveTo(cellAt(tester, 8, 0));
      await tester.pump();
      expect(selected(), 'alpha bravo');

      await two.up();
      await one.up();
      await ready(tester);
      await unmount(tester);
    });

    testWidgets('a press takes the run it lands in, and the URL inside that '
        'run', (tester) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions, db: db));
      await ready(tester);
      transport.opened.single.emit('see url=https://x.dev/a/b?c=1 (done).\r\n');
      await ready(tester);
      final session = sessions.activeFor(rose.id)!;
      String selected() =>
          session.terminal.buffer.getText(session.controller.selection);

      Future<void> press(int x) async {
        final gesture = await hold(tester, cellAt(tester, x, 0));
        await tester.pump();
        await gesture.up();
        await ready(tester);
      }

      // Inside the link: the scheme wins over the run it sits in, so the
      // `url=` prefix is left behind.
      await press(18);
      expect(selected(), 'https://x.dev/a/b?c=1');

      // Outside it, on the prefix: no scheme under the finger, so the whole
      // run comes, `=` and all.
      await press(5);
      expect(selected(), 'url=https://x.dev/a/b?c=1');

      // A word the sentence wrapped and punctuated: the brackets and the stop
      // are not part of it.
      await press(32);
      expect(selected(), 'done');

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
      // Longer than the view is wide, so the terminal wraps it onto the next
      // row without a line of its own.
      final url = 'https://x.dev/${'a' * (session.terminal.viewWidth + 20)}';
      transport.opened.single.emit('$url\r\n');
      await ready(tester);
      expect(session.terminal.buffer.lines[1].isWrapped, isTrue);

      final gesture = await hold(tester, cellAt(tester, 5, 0));
      await tester.pump();
      await gesture.up();
      await ready(tester);

      expect(
        session.terminal.buffer.getText(session.controller.selection),
        url,
      );

      await unmount(tester);
    });

    testWidgets('a press on a full-screen application takes the line under '
        'the finger after the keyboard has been up', (tester) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions, db: db));
      await ready(tester);
      final shell = transport.opened.single;
      final session = sessions.activeFor(rose.id)!;
      final terminal = session.terminal;

      // The alternate screen, filled to its last row: a REPL, a pager, an
      // editor. There is no scrollback behind it.
      shell.emit('\x1b[?1049h');
      await ready(tester);
      shell.emit(
        List.generate(terminal.viewHeight, (i) => 'row$i').join('\r\n'),
      );
      await ready(tester);
      final tall = terminal.viewHeight;

      // The keyboard comes up and takes rows off the view, then goes away
      // again. Every row the shrink cut off the top is trimmed, and the rows
      // that are left move up by that many.
      tester.view.viewInsets = const FakeViewPadding(bottom: 400);
      await ready(tester);
      expect(terminal.viewHeight, lessThan(tall));
      tester.view.viewInsets = FakeViewPadding.zero;
      await ready(tester);

      // A press on the third row down takes the third row down, not the one
      // the row's index named before the view lost its top.
      final third = terminal.buffer.lines[2].toString().trimRight();
      final gesture = await hold(tester, cellAt(tester, 1, 2));
      await tester.pump();
      await gesture.up();
      await ready(tester);

      expect(terminal.buffer.getText(session.controller.selection), third);

      await unmount(tester);
    });

    testWidgets('the highlight is a wash the text shows through', (
      tester,
    ) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions, db: db));
      await ready(tester);

      final theme = tester
          .widget<TerminalView>(find.byType(TerminalView))
          .theme;
      // xterm paints the selection over the glyphs; a solid one hides them.
      expect(theme.selection.a, lessThan(0.5));
      expect(theme.selection.withValues(alpha: 1), DazzleColors.accent);

      await unmount(tester);
    });

    testWidgets('CLEAR drops the selection without copying', (tester) async {
      String? copied;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String;
            }
            return null;
          });

      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions, db: db));
      await ready(tester);

      transport.opened.single.emit('copyme\r\n');
      await ready(tester);

      final session = sessions.activeFor(rose.id)!;
      final buffer = session.terminal.buffer;
      session.controller.setSelection(
        buffer.createAnchor(0, 0),
        buffer.createAnchor(6, 0),
      );
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('shell-copy-clear')));
      await tester.pump();

      expect(copied, isNull);
      expect(session.controller.selection, isNull);
      expect(find.byKey(const ValueKey('shell-copy')), findsNothing);

      await unmount(tester);
    });
  });

  group('a Herdr pane over Mosh', () {
    testWidgets('keeps taps and scrolls as remote mouse input', (tester) async {
      final transport = FakeShellTransport()..transport = ShellTransport.mosh;
      final sessions = fakeShellSessions(transport);
      const pane = (session: 'default', pane: 'w1:p1');
      sessions.open(rose, command: 'attach', pane: pane);
      await tester.pumpWidget(app(sessions));
      await ready(tester);
      final connection = transport.opened.single;

      // Mosh rejects mode 1003 after a TUI first enables mode 1002. Its
      // fallback disables 1002, leaving the outer terminal with no mouse mode.
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
      expect(session.terminal.isUsingAltBuffer, isFalse);
      expect(session.terminal.mouseMode.reportScroll, isTrue);

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

      // A theme animation and a screen the app is moved onto each rebuild the
      // scrollable's position out from under the render object that reads it.
      await tester.pumpWidget(
        app(
          sessions,
          theme: testTheme.copyWith(
            colorScheme: testTheme.colorScheme.copyWith(
              primary: DazzleColors.accentMuted,
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
    /// A screenful of output and then some, so there is something behind the
    /// bottom of the view to scroll into.
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

    /// Puts the view a screenful up, the way a finger dragging down does.
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

      // The terminal follows its own output, so a shell left alone is on its
      // last line however much it prints.
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
      // A mark in the corner, not a bar across the bottom of the shell. The
      // cell is its own label and the floor under it; a cell that takes the
      // pane's width covers a whole row of output and every touch along it.
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

      final buffer = session.terminal.buffer;
      session.controller.setSelection(
        buffer.createAnchor(0, 0),
        buffer.createAnchor(4, 0),
      );
      await tester.pump();

      expect(find.byKey(const ValueKey('shell-copy')), findsOneWidget);
      expect(tail, findsNothing);

      session.controller.clearSelection();
      await tester.pump();
      expect(tail, findsOneWidget);

      await unmount(tester);
    });
  });
}
