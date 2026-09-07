/// The session card's miniature: which lines it takes off the terminal, how
/// often it goes back for more, and when the painter bothers to repaint.
library;

import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spectacle/features/shell/shell_thumbnail.dart';
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

      expect(thumbnailLines(terminal), ['one', 'two', 'three']);
    });

    test('the blank rows under the last written line are dropped', () {
      final terminal = terminalShowing(['one'], rows: 8);

      expect(thumbnailLines(terminal), ['one']);
    });

    test('a blank line between two written ones is output and is kept', () {
      final terminal = terminalShowing(['one', '', 'three'], rows: 8);

      expect(thumbnailLines(terminal), ['one', '', 'three']);
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
      expect(thumbnailLines(terminal), isNot(contains('gone')));
    });

    test('a line is its text without the cells it never wrote in', () {
      final terminal = terminalShowing(['ok']);

      expect(thumbnailLines(terminal).first, 'ok');
    });
  });

  group('the widget', () {
    testWidgets('paints the buffer it was given', (tester) async {
      await pumpThumbnail(tester, terminalShowing(['one', 'two']));

      expect(painterOf(tester).lines, ['one', 'two']);
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
      ], reason: 'the chunk has not been picked up yet');

      await tester.pump(const Duration(milliseconds: 600));
      expect(painterOf(tester).lines, ['one', 'two']);
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

  group('what the card has room for', () {
    test('a card too short for every line keeps the newest of them', () {
      final lines = [for (var i = 0; i < 40; i++) 'line $i'];

      final drawn = thumbnailTail(lines, 110);

      expect(drawn.last, 'line 39');
      expect(drawn.length, lessThan(lines.length));
      expect(lines.sublist(lines.length - drawn.length), drawn);
    });

    test('a taller card draws more of the same lines', () {
      final lines = [for (var i = 0; i < 40; i++) 'line $i'];

      expect(
        thumbnailTail(lines, 220).length,
        greaterThan(thumbnailTail(lines, 110).length),
      );
    });

    test('what fits is drawn whole, oldest first', () {
      expect(thumbnailTail(['one', 'two'], 110), ['one', 'two']);
    });

    test('a card with no room for a line draws none', () {
      expect(thumbnailTail(['one'], 0), isEmpty);
    });
  });

  group('the painter', () {
    test('repaints for new lines, nothing else', () {
      const painter = ShellThumbnailPainter(lines: ['one']);

      expect(
        painter.shouldRepaint(const ShellThumbnailPainter(lines: ['one'])),
        isFalse,
      );
      expect(
        painter.shouldRepaint(const ShellThumbnailPainter(lines: ['two'])),
        isTrue,
      );
    });

    testWidgets('a line wider than the card is cut by its edge', (
      tester,
    ) async {
      const card = Size(160, 110);
      final recorder = ui.PictureRecorder();
      const ShellThumbnailPainter(lines: ['x']).paint(Canvas(recorder), card);
      final wide = ui.PictureRecorder();
      ShellThumbnailPainter(lines: ['x' * 400]).paint(Canvas(wide), card);

      final picture = wide.endRecording();
      final image = picture.toImageSync(300, card.height.round());
      final pixels = await tester.runAsync(
        () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
      );
      var past = 0;
      for (var y = 0; y < card.height.round(); y++) {
        for (var x = card.width.round() + 4; x < 300; x++) {
          if (pixels!.getUint32((y * 300 + x) * 4) != 0) past++;
        }
      }

      expect(past, 0);
      recorder.endRecording().dispose();
      picture.dispose();
      image.dispose();
    });

    testWidgets('an empty buffer paints nothing and does not throw', (
      tester,
    ) async {
      await pumpThumbnail(tester, Terminal(maxLines: 100));

      expect(tester.takeException(), isNull);
    });
  });
}
