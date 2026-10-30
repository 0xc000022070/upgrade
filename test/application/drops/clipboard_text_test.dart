import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/application/drops/clipboard_text.dart';

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

  test('one drop copies bare, with no rule around it', () {
    expect(dropClipboardText([const DropText('uno\ndos', [])]), 'uno\ndos');
  });

  test('several drops are separated by a rule, in the order given', () {
    expect(
      dropClipboardText([
        const DropText('uno', []),
        const DropText('dos', ['https://a.example']),
        const DropText('tres', []),
      ]),
      'uno\n\n---\n\ndos\n\nhttps://a.example\n\n---\n\ntres',
    );
  });

  test('a multiline drop keeps every line and stays one entry', () {
    expect(
      dropClipboardText([
        const DropText('bajar el pool a 40\ny medir otra vez', []),
        const DropText('desplegar el gate', []),
      ]),
      'bajar el pool a 40\ny medir otra vez\n\n---\n\ndesplegar el gate',
    );
  });

  test('a blank line the user typed is not a boundary', () {
    expect(
      dropClipboardText([
        const DropText('revisar pgbouncer\n\ny medir otra vez', []),
        const DropText('desplegar el gate', []),
      ]),
      'revisar pgbouncer\n\ny medir otra vez\n\n---\n\ndesplegar el gate',
    );
  });

  test('the empty space above and below a drop is not copied', () {
    expect(
      dropClipboardText([
        const DropText('\n  uno\n\n', []),
        const DropText('dos', ['https://a.example']),
      ]),
      'uno\n\n---\n\ndos\n\nhttps://a.example',
    );
  });

  test('nothing checked is nothing on the clipboard', () {
    expect(dropClipboardText([]), '');
  });
}
