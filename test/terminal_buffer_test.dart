import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  group('a row keeps its own index', () {
    /// The whole buffer, one string per row, top to bottom.
    List<String> rows(Terminal terminal) => [
      for (var y = 0; y < terminal.buffer.lines.length; y++)
        terminal.buffer.lines[y].toString().trimRight(),
    ];

    /// Every line agrees with the slot it is in.
    void indicesHold(Terminal terminal) {
      for (var y = 0; y < terminal.buffer.lines.length; y++) {
        expect(terminal.buffer.lines[y].index, y, reason: 'row $y');
      }
    }

    test('a view that shrinks on the alternate screen leaves them where they '
        'are', () {
      final terminal = Terminal(maxLines: 1000);
      terminal.resize(40, 30);
      // A full-screen application: the alternate screen, filled to the last
      // row, which is where the shells that run one leave the cursor.
      terminal.write('\x1b[?1049h');
      for (var i = 0; i < 30; i++) {
        terminal.write('row$i${i < 29 ? '\r\n' : ''}');
      }

      // The keyboard comes up and takes twelve rows off the view. There is no
      // scrollback to keep on the alternate screen, so those rows are trimmed
      // off the top.
      terminal.resize(40, 18);
      expect(terminal.buffer.lines.length, 18);
      expect(rows(terminal).first, 'row12');
      indicesHold(terminal);

      // A press on the third row down takes the third row down, not the one
      // twelve further on that its old index used to name.
      final anchor = terminal.buffer.createAnchorFromOffset(
        const CellOffset(0, 3),
      );
      expect(anchor.attached, isTrue);
      expect(anchor.offset, const CellOffset(0, 3));
      expect(terminal.buffer.lines[anchor.offset.y].toString().trimRight(),
          'row15');
    });

    test('a scroll leaves the rows it moved in the buffer', () {
      final terminal = Terminal(maxLines: 1000);
      terminal.resize(40, 6);
      terminal.write('\x1b[?1049h');
      for (var i = 0; i < 5; i++) {
        terminal.write('alt$i\r\n');
      }

      // The finger goes down on the third row, and the application prints one
      // more line, which scrolls the screen up by one.
      final anchor = terminal.buffer.createAnchorFromOffset(
        const CellOffset(0, 2),
      );
      terminal.write('more\r\n');

      // The row moved up by one and the anchor moved with it. A scroll writes
      // each row from the one below it, so the row it has just written is
      // still sitting in the next slot along when that slot is written: the
      // line must not be taken out of the buffer it is still part of.
      expect(anchor.attached, isTrue);
      expect(anchor.offset, const CellOffset(0, 1));
      expect(terminal.buffer.lines[anchor.offset.y].toString().trimRight(),
          'alt2');
      indicesHold(terminal);
    });

    test('erasing the scrollback leaves them where they are', () {
      final terminal = Terminal(maxLines: 1000);
      terminal.resize(40, 5);
      for (var i = 0; i < 20; i++) {
        terminal.write('line$i\r\n');
      }
      final anchor = terminal.buffer.createAnchorFromOffset(
        CellOffset(0, terminal.buffer.lines.length - 3),
      );

      terminal.write('\x1b[3J');

      expect(terminal.buffer.lines.length, 5);
      expect(anchor.attached, isTrue);
      expect(terminal.buffer.lines[anchor.offset.y].toString().trimRight(),
          'line18');
      indicesHold(terminal);
    });

    test('a reflow after the scrollback has wrapped keeps the order', () {
      final terminal = Terminal(maxLines: 40);
      terminal.resize(20, 10);
      // Past the cap, so the buffer no longer starts at its first slot.
      for (var i = 0; i < 60; i++) {
        terminal.write('L$i\r\n');
      }
      final before = rows(terminal);

      // A pinch on the type, which is a width the lines are reflowed to.
      terminal.resize(30, 10);

      expect(rows(terminal), before);
      indicesHold(terminal);
    });
  });
}
