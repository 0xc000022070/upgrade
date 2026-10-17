import 'package:striked/platform/shell/remote_shell.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('the pinentry mark', () {
    test('names the tab so the Mosh server holding its pty is found', () {
      final command = pinentryMarkCommand('shmch5j3bgs1');
      expect(command, startsWith('sh -c '));
      expect(command, contains('$moshTabVariable=shmch5j3bgs1'));
      expect(command, contains('mosh-server'));
      expect(command, contains(r'$PPID'));
      expect(command, contains('pinentry-gate'));
      expect(command, contains(r'"$d/tty/pts-${t#pts/}"'));
    });

    test('takes only a tab that is a mark', () {
      expect(() => pinentryMarkCommand('../x'), throwsA(isA<AssertionError>()));
      expect(() => pinentryMarkCommand(''), throwsA(isA<AssertionError>()));
    });

    test('the open list reads the fifo-backed json files and exits 0', () {
      final command = pinentryOpenCommand();
      expect(command, startsWith('sh -c '));
      expect(command, contains('pinentry-gate'));
      expect(command, contains('*.json'));
      expect(command, contains('[ -p '));
      expect(command, contains('base64'));
      expect(command, endsWith("exit 0'"));
    });

    test('the answer hands the id over and never opens the fifo itself', () {
      final command = pinentryAnswerCommand('0123456789abcdef');
      expect(command, startsWith('sh -c '));
      expect(command, contains('pinentry-gate answer 0123456789abcdef'));
      expect(command, isNot(contains('[ -p ')));
      expect(command, isNot(contains('cat > ')));
    });

    test('takes only an id that is a request id', () {
      expect(
        () => pinentryAnswerCommand('../x'),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}
