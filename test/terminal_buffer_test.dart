import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  group('a row keeps its own index', () {
    List<String> rows(Terminal terminal) => [
      for (var y = 0; y < terminal.buffer.lines.length; y++)
        terminal.buffer.lines[y].toString().trimRight(),
    ];

    void indicesHold(Terminal terminal) {
      for (var y = 0; y < terminal.buffer.lines.length; y++) {
        expect(terminal.buffer.lines[y].index, y, reason: 'row $y');
      }
    }

    test('a view that shrinks on the alternate screen leaves them where they '
        'are', () {
      final terminal = Terminal(maxLines: 1000);
      terminal.resize(40, 30);
      // The alternate screen, filled to the last row.
      terminal.write('\x1b[?1049h');
      for (var i = 0; i < 30; i++) {
        terminal.write('row$i${i < 29 ? '\r\n' : ''}');
      }

      // There is no scrollback to keep on the alternate screen, so the rows the shrink cuts
      // are trimmed off the top.
      terminal.resize(40, 18);
      expect(terminal.buffer.lines.length, 18);
      expect(rows(terminal).first, 'row12');
      indicesHold(terminal);

      final anchor = terminal.buffer.createAnchorFromOffset(
        const CellOffset(0, 3),
      );
      expect(anchor.attached, isTrue);
      expect(anchor.offset, const CellOffset(0, 3));
      expect(
        terminal.buffer.lines[anchor.offset.y].toString().trimRight(),
        'row15',
      );
    });

    test('a scroll leaves the rows it moved in the buffer', () {
      final terminal = Terminal(maxLines: 1000);
      terminal.resize(40, 6);
      terminal.write('\x1b[?1049h');
      for (var i = 0; i < 5; i++) {
        terminal.write('alt$i\r\n');
      }

      final anchor = terminal.buffer.createAnchorFromOffset(
        const CellOffset(0, 2),
      );
      terminal.write('more\r\n');

      // A scroll writes each row from the one below it, so the row it has just written is
      // still sitting in the next slot along when that slot is written.
      expect(anchor.attached, isTrue);
      expect(anchor.offset, const CellOffset(0, 1));
      expect(
        terminal.buffer.lines[anchor.offset.y].toString().trimRight(),
        'alt2',
      );
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
      expect(
        terminal.buffer.lines[anchor.offset.y].toString().trimRight(),
        'line18',
      );
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

      terminal.resize(30, 10);

      expect(rows(terminal), before);
      indicesHold(terminal);
    });
  });
}
