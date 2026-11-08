import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/application/files/phone_inbox.dart';

SharedFile _file(String name, String mime) =>
    SharedFile(path: '/c/$name', name: name, size: 1, mime: mime);

void main() {
  group('the clipboard plan', () {
    test('one picture goes on as itself, of its own type', () {
      final plan = planClipboard([_file('a.jpg', 'image/jpeg')], ['/t/a.jpg']);
      expect(plan, isA<CopyImage>());
      expect((plan as CopyImage).path, '/t/a.jpg');
      expect(plan.mime, 'image/jpeg');
    });

    test('text stays text, and every file is its path, one per line', () {
      final plan = planClipboard(
        [
          const SharedText('look'),
          _file('a.png', 'image/png'),
          _file('b.pdf', 'application/pdf'),
        ],
        [null, '/t/a.png', '/t/b.pdf'],
      );
      expect((plan as CopyText).text, 'look\n/t/a.png\n/t/b.pdf');
    });
  });

  test('a name the folder holds gets the next free number', () {
    expect(freeName('a.txt', {}), 'a.txt');
    expect(freeName('a.txt', {'a.txt', 'a (2).txt'}), 'a (3).txt');
    expect(freeName('.env', {'.env'}), '.env (2)');
    expect(freeName('Makefile', {'Makefile'}), 'Makefile (2)');
  });

  test('shared text is named for when it came in', () {
    expect(
      sharedTextName(DateTime(2026, 3, 4, 5, 6, 7)),
      'shared-20260304-050607.txt',
    );
  });

  test('a share parsed off the channel keeps text and files apart', () {
    final items = parseSharedItems([
      {'kind': 'text', 'text': 'hi'},
      {'kind': 'file', 'path': '/c/a', 'name': 'a', 'size': 3, 'mime': 'x/y'},
    ]);
    expect((items[0] as SharedText).text, 'hi');
    expect((items[1] as SharedFile).size, 3);
  });

  test('a share the phone could not read is counted, not sent', () {
    final raw = [
      {'kind': 'unreadable'},
      {'kind': 'file', 'path': '/c/a', 'name': 'a', 'size': 3, 'mime': 'x/y'},
    ];
    expect(parseSharedItems(raw).single, isA<SharedFile>());
    expect(countUnreadable(raw), 1);
  });
}
