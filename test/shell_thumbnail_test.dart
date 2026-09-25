import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/features/shell/shell_sessions.dart';
import 'package:dazzle/features/shell/shell_thumbnail.dart';
import 'package:flterm/flterm.dart';

import 'support/shell_route.dart' show rose;
import 'support/themed_app.dart';

TerminalController terminalSized({int rows = 4, int columns = 20}) {
  final terminal = TerminalController(
    config: TerminalConfig(cols: columns, rows: rows),
  );
  addTearDown(terminal.dispose);
  return terminal;
}

void write(TerminalController terminal, String text) =>
    terminal.write(Uint8List.fromList(utf8.encode(text)));

TerminalController terminalShowing(
  List<String> lines, {
  int rows = 4,
  int columns = 20,
}) {
  final terminal = terminalSized(rows: rows, columns: columns);
  write(terminal, lines.join('\r\n'));
  return terminal;
}

void emit(ShellSession session, String text) {
  write(session.terminal, text);
  session.output.value++;
}

ShellSession sessionShowing(List<String> lines) =>
    ShellSession(number: 1, terminal: terminalShowing(lines), host: rose);

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

Future<void> pumpThumbnail(WidgetTester tester, ShellSession session) =>
    tester.pumpWidget(
      Theme(
        data: testTheme,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox(
              width: 160,
              height: 110,
              child: ShellThumbnail(session: session),
            ),
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
      expect(thumbnailLines(terminal).length, 4);
      expect(thumbnailLines(terminal), isNot(contains('gone')));
    });

    test('a line is its text without the cells it never wrote in', () {
      final terminal = terminalShowing(['ok']);

      expect(thumbnailLines(terminal).first, 'ok');
    });

    test('a gap the cursor moved over keeps the columns apart', () {
      final terminal = terminalSized(columns: 40);
      write(terminal, 'dazzle 3\x1b[7C1 tab\x1b[3C1 pane');

      expect(thumbnailLines(terminal), ['dazzle 3       1 tab   1 pane']);
    });

    test('a wide character takes its two cells and no more', () {
      final terminal = terminalSized();
      write(terminal, 'a漢b');

      expect(thumbnailLines(terminal), ['a漢b']);
    });
  });

  group('the widget', () {
    testWidgets('paints the buffer it was given', (tester) async {
      await pumpThumbnail(tester, sessionShowing(['one', 'two']));

      expect(painterOf(tester).lines, ['one', 'two']);
    });

    testWidgets('catches up with output on its own clock, not per chunk', (
      tester,
    ) async {
      final session = sessionShowing(['one']);
      await pumpThumbnail(tester, session);

      emit(session, '\r\ntwo');
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
      await pumpThumbnail(tester, sessionShowing(['first']));
      await pumpThumbnail(tester, sessionShowing(['second']));
      await tester.pump();

      expect(painterOf(tester).lines.first, 'second');
    });

    testWidgets('lets go of the terminal it was showing', (tester) async {
      final session = sessionShowing(['one']);
      await pumpThumbnail(tester, session);
      await tester.pumpWidget(const SizedBox.shrink());

      emit(session, '\r\ntwo');
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
      const painter = ShellThumbnailPainter(
        lines: ['one'],
        textColor: Color(0xFFFFFFFF),
      );

      expect(
        painter.shouldRepaint(
          const ShellThumbnailPainter(
            lines: ['one'],
            textColor: Color(0xFFFFFFFF),
          ),
        ),
        isFalse,
      );
      expect(
        painter.shouldRepaint(
          const ShellThumbnailPainter(
            lines: ['two'],
            textColor: Color(0xFFFFFFFF),
          ),
        ),
        isTrue,
      );
      expect(
        painter.shouldRepaint(
          const ShellThumbnailPainter(
            lines: ['one'],
            textColor: Color(0xFF000000),
          ),
        ),
        isTrue,
      );
    });

    testWidgets('a line wider than the card is cut by its edge', (
      tester,
    ) async {
      const card = Size(160, 110);
      final recorder = ui.PictureRecorder();
      const ShellThumbnailPainter(
        lines: ['x'],
        textColor: Color(0xFFFFFFFF),
      ).paint(Canvas(recorder), card);
      final wide = ui.PictureRecorder();
      ShellThumbnailPainter(
        lines: ['x' * 400],
        textColor: const Color(0xFFFFFFFF),
      ).paint(Canvas(wide), card);

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
      await pumpThumbnail(
        tester,
        ShellSession(number: 1, terminal: terminalSized(), host: rose),
      );

      expect(tester.takeException(), isNull);
    });
  });
}
