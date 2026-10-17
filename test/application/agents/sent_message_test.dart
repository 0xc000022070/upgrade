import 'package:flutter_test/flutter_test.dart';

import 'package:striked/application/agents/send.dart';
import 'package:striked/platform/shell/remote_shell.dart';

void main() {
  const image = '/data/app/attachments/0192.png';
  final named = '$remoteUploadDirectory/0192.png';

  test('a recorded text gives back its message and the images it named', () {
    final text = 'fix the parser\n\nsee the trace\n\n$named';
    expect(sentMessage(text), 'fix the parser\n\nsee the trace');
    expect(sentImage(text, image), isTrue);
    expect(sentImage(text, '/data/app/attachments/0193.png'), isFalse);
  });

  test('a text with no image block is its own message', () {
    const text = 'fix the parser\n\nsee the trace';
    expect(sentMessage(text), text);
    expect(sentMessage('one line'), 'one line');
  });
}
