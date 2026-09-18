import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  group('a token is the run under the finger', () {
    String take(String text, int index) {
      final span = tokenAt(text, index);
      return span == null ? '' : text.substring(span.start, span.end);
    }

    test('a word in prose comes whole from any letter in it', () {
      expect(take('one two three', 0), 'one');
      expect(take('one two three', 5), 'two');
      expect(take('one two three', 12), 'three');
    });

    test('a gap is nobody\'s token', () {
      expect(tokenAt('one two', 3), isNull);
      expect(tokenAt('one two', -1), isNull);
      expect(tokenAt('one two', 7), isNull);
    });

    test('a path, a port and an scp target survive their separators', () {
      expect(take('at /home/luis/x.dart:42 now', 10), '/home/luis/x.dart:42');
      expect(take('host db-1.local:5432 up', 8), 'db-1.local:5432');
      expect(
        take('git clone git@github.com:o/r.git', 20),
        'git@github.com:o/r.git',
      );
      expect(take('see github.com/o/r for it', 8), 'github.com/o/r');
    });

    test('a scheme inside the run wins the run', () {
      expect(take('url=https://x.dev/a/b?c=1', 20), 'https://x.dev/a/b?c=1');
      expect(take('url=https://x.dev/a', 1), 'url=https://x.dev/a');
      expect(take('[INFO] https://x.dev/a', 12), 'https://x.dev/a');
    });

    test('punctuation the sentence added is not part of the token', () {
      expect(take('go to https://x.dev/a.', 12), 'https://x.dev/a');
      expect(take('go to https://x.dev/a,', 12), 'https://x.dev/a');
      expect(take('see (https://x.dev/a).', 12), 'https://x.dev/a');
      expect(take('the "quoted" one', 6), 'quoted');
      expect(take('say `code` here', 6), 'code');
      expect(take('done.', 1), 'done');
    });

    test('punctuation the token needs is kept', () {
      expect(take('see https://x.dev/a_(b)_c.', 12), 'https://x.dev/a_(b)_c');
      expect(take('x.dev/a?b=1&c=2', 3), 'x.dev/a?b=1&c=2');
      expect(take('done.', 4), 'done.');
      expect(take('(done)', 0), '(done)');
    });
  });

  group('the buffer answers with cells', () {
    Terminal terminalWith(String text, {int width = 40, int height = 8}) {
      final terminal = Terminal(maxLines: 100);
      terminal.resize(width, height);
      terminal.write(text);
      return terminal;
    }

    String take(Terminal terminal, int x, int y) {
      final range = terminal.buffer.getTokenBoundary(CellOffset(x, y));
      return range == null ? '' : terminal.buffer.getText(range);
    }

    test('a press on a line takes the token under it', () {
      final terminal = terminalWith('open https://x.dev/a/b now\r\n');
      expect(take(terminal, 12, 0), 'https://x.dev/a/b');
      expect(take(terminal, 1, 0), 'open');
      expect(terminal.buffer.getTokenBoundary(const CellOffset(4, 0)), isNull);
    });

    test('a token torn across a soft wrap is still one token', () {
      // 40 columns wide, so the link runs off the right edge and continues on a row that is a
      // continuation rather than a line of its own.
      final url = 'https://x.dev/${'a' * 36}/b';
      final terminal = terminalWith('$url\r\n');
      expect(terminal.buffer.lines[1].isWrapped, isTrue);
      expect(take(terminal, 5, 0), url);
      expect(take(terminal, 3, 1), url);
    });

    test('a glyph wider than one cell does not slide the columns after it', () {
      // The flattened line must be one UTF-16 unit per cell or an index stops being a column:
      // '名' occupies two cells and the second holds no code point of its own, and an emoji is
      // a surrogate pair in one cell run.
      final terminal = terminalWith('名前 https://x.dev/a 😀 tail\r\n');
      expect(take(terminal, 6, 0), 'https://x.dev/a');
      expect(take(terminal, 25, 0), 'tail');
      expect(take(terminal, 0, 0), '名前');
      expect(take(terminal, 1, 0), '名前');
    });

    test('a press past the last row has nothing under it', () {
      final terminal = terminalWith('one\r\n');
      expect(terminal.buffer.getTokenBoundary(const CellOffset(0, 99)), isNull);
    });
  });
}
