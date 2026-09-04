/// The session card's miniature: which lines it takes off the terminal, how
/// often it goes back for more, and when the painter bothers to repaint.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotline/features/shell/shell_thumbnail.dart';
import 'package:xterm/xterm.dart';

Terminal terminalShowing(List<String> lines, {int rows = 4, int columns = 20}) {
  final terminal = Terminal(maxLines: 100);
  terminal.resize(columns, rows);
  terminal.write(lines.join('\r\n'));
  return terminal;
}

/// The painter the widget is currently handing the canvas.
ShellThumbnailPainter painterOf(WidgetTester tester) =>
    tester
            .widget<CustomPaint>(
              find.descendant(
                of: find.byType(ShellThumbnail),
                matching: find.byType(CustomPaint),
              ),
            )
            .painter
        as ShellThumbnailPainter;

Future<void> pumpThumbnail(WidgetTester tester, Terminal terminal) =>
    tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: 160,
            height: 110,
            child: ShellThumbnail(terminal: terminal),
          ),
        ),
      ),
    );

void main() {
  group('what it takes off the terminal', () {
    test('the lines the terminal is showing, oldest first', () {
      final terminal = terminalShowing(['one', 'two', 'three']);

      expect(thumbnailLines(terminal), ['one', 'two', 'three', '']);
    });

    test('only the visible ones once the buffer has scrolled past them', () {
      final terminal = terminalShowing([
        'gone',
        'also gone',
        'one',
        'two',
        'three',
        'four',
      ]);

      expect(thumbnailLines(terminal), ['one', 'two', 'three', 'four']);
      expect(thumbnailLines(terminal).length, terminal.buffer.viewHeight);
    });

    test('a line is its text without the cells it never wrote in', () {
      final terminal = terminalShowing(['ok']);

      expect(thumbnailLines(terminal).first, 'ok');
    });
  });

  group('the widget', () {
    testWidgets('paints the buffer it was given', (tester) async {
      await pumpThumbnail(tester, terminalShowing(['one', 'two']));

      expect(painterOf(tester).lines, ['one', 'two', '', '']);
      expect(painterOf(tester).columns, 20);
    });

    testWidgets('catches up with output on its own clock, not per chunk', (
      tester,
    ) async {
      final terminal = terminalShowing(['one']);
      await pumpThumbnail(tester, terminal);

      terminal.write('\r\ntwo');
      await tester.pump();
      expect(painterOf(tester).lines, [
        'one',
        '',
        '',
        '',
      ], reason: 'the chunk has not been picked up yet');

      await tester.pump(const Duration(milliseconds: 600));
      expect(painterOf(tester).lines, ['one', 'two', '', '']);
    });

    testWidgets('follows the terminal when the card is given another', (
      tester,
    ) async {
      await pumpThumbnail(tester, terminalShowing(['first']));
      await pumpThumbnail(tester, terminalShowing(['second']));
      await tester.pump();

      expect(painterOf(tester).lines.first, 'second');
    });

    testWidgets('lets go of the terminal it was showing', (tester) async {
      final terminal = terminalShowing(['one']);
      await pumpThumbnail(tester, terminal);
      await tester.pumpWidget(const SizedBox.shrink());

      terminal.write('\r\ntwo');
      await tester.pump(const Duration(milliseconds: 600));

      expect(tester.takeException(), isNull);
    });
  });

  group('the painter', () {
    test('repaints for new lines and for a resized terminal, nothing else', () {
      const painter = ShellThumbnailPainter(lines: ['one'], columns: 20);

      expect(
        painter.shouldRepaint(
          const ShellThumbnailPainter(lines: ['one'], columns: 20),
        ),
        isFalse,
      );
      expect(
        painter.shouldRepaint(
          const ShellThumbnailPainter(lines: ['two'], columns: 20),
        ),
        isTrue,
      );
      expect(
        painter.shouldRepaint(
          const ShellThumbnailPainter(lines: ['one'], columns: 80),
        ),
        isTrue,
      );
    });

    testWidgets('an empty buffer paints nothing and does not throw', (
      tester,
    ) async {
      await pumpThumbnail(tester, Terminal(maxLines: 100));

      expect(tester.takeException(), isNull);
    });
  });
}
