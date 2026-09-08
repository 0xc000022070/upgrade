import 'package:flutter_test/flutter_test.dart';
import 'package:spectacle/application/clipboard_text.dart';

void main() {
  test('a drop is its title, a blank line, and its links one per line', () {
    expect(
      dropClipboardText([
        const DropText('revisar pgbouncer', [
          'https://a.example',
          'https://b.example',
        ]),
      ]),
      'revisar pgbouncer\n\nhttps://a.example\nhttps://b.example',
    );
  });

  test('a drop with no link is the title and nothing else', () {
    expect(
      dropClipboardText([const DropText('revisar pgbouncer', [])]),
      'revisar pgbouncer',
    );
  });

  test('several drops are joined by a blank line, in the order given', () {
    expect(
      dropClipboardText([
        const DropText('uno', []),
        const DropText('dos', ['https://a.example']),
        const DropText('tres', []),
      ]),
      'uno\n\ndos\n\nhttps://a.example\n\ntres',
    );
  });

  test('nothing checked is nothing on the clipboard', () {
    expect(dropClipboardText([]), '');
  });
}
