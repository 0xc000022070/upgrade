import 'dart:convert';
import 'dart:typed_data';

import 'package:flterm/flterm.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/features/shell/shell_engine.dart';
import 'package:upgrade/platform/shell/shell_connection.dart';
import 'package:upgrade/platform/vnc/keysyms.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_shell.dart';

const _rose = Host(
  id: 'h1',
  name: 'rose',
  address: '100.64.0.1',
  port: 22,
  user: 'luis',
  keyId: 'key-1',
);

Future<void> _settle() => Future<void>.delayed(Duration.zero);

/// Colours nothing else in the suite uses, so a reply can only have come from these.
const _palette = TerminalPalette(
  foreground: Color(0xFFE8E8E8),
  background: Color(0xFF08090B),
  cursor: Color(0xFFB7FF2A),
  ansi: [
    Color(0xFF000000),
    Color(0xFFCD3131),
    Color(0xFF0DBC79),
    Color(0xFFE5E510),
    Color(0xFF2472C8),
    Color(0xFFBC3FBC),
    Color(0xFF11A8CD),
    Color(0xFFE5E5E5),
    Color(0xFF666666),
    Color(0xFFF14C4C),
    Color(0xFF23D18B),
    Color(0xFFF5F543),
    Color(0xFF3B8EEA),
    Color(0xFFD670D6),
    Color(0xFF29B8DB),
    Color(0xFFFFFFFF),
  ],
);

({TerminalController terminal, List<String> replies}) _terminal({
  TerminalPalette? palette = _palette,
}) {
  final replies = <String>[];
  final terminal = TerminalController()
    ..onOutput = (bytes) => replies.add(utf8.decode(bytes));
  if (palette != null) answerInColours(terminal, palette);
  addTearDown(terminal.dispose);
  return (terminal: terminal, replies: replies);
}

extension on TerminalController {
  void type(String text) => write(Uint8List.fromList(utf8.encode(text)));
}

void main() {
  group('a colour the terminal is drawn in', () {
    test('the background is answered in sixteen-bit channels', () {
      final it = _terminal();

      it.terminal.type('\x1b]11;?\x07');

      expect(it.replies.join(), '\x1b]11;rgb:0808/0909/0b0b\x07');
    });

    test('the foreground and the cursor answer on their own slots', () {
      final it = _terminal();

      it.terminal.type('\x1b]10;?\x07\x1b]12;?\x07');

      expect(
        it.replies.join(),
        '\x1b]10;rgb:e8e8/e8e8/e8e8\x07'
        '\x1b]12;rgb:b7b7/ffff/2a2a\x07',
      );
    });

    test('an answer ends the way the question did', () {
      final it = _terminal();

      it.terminal.type('\x1b]11;?\x1b\\');

      // A program that asked with ST reads until ST; a bell would leave it waiting on a reply
      // it has already been sent.
      expect(it.replies.join(), '\x1b]11;rgb:0808/0909/0b0b\x1b\\');
    });

    test('a question split across two reads is still one question', () {
      final it = _terminal();

      it.terminal.type('\x1b]11');
      it.terminal.type(';?\x07');

      expect(it.replies.join(), '\x1b]11;rgb:0808/0909/0b0b\x07');
    });

    test('a numbered colour of the table is answered too', () {
      final it = _terminal();

      it.terminal.type('\x1b]4;1;?\x07');

      expect(it.replies.join(), '\x1b]4;1;rgb:cdcd/3131/3131\x07');
    });
  });

  group('a session answers with the ground it is drawn on', () {
    test('the reply carries the house terminal, not a default', () async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);

      sessions.open(intent: UserIntent.fromGesture(), _rose);
      await _settle();
      final connection = transport.opened.single;

      connection.emit('\x1b]11;?\x07');
      await _settle();

      final ground = UpgradeTokens.house.terminal.background;
      final rgb = [
        (ground.r * 0xff).round(),
        (ground.g * 0xff).round(),
        (ground.b * 0xff).round(),
      ].map((c) => (c * 0x101).toRadixString(16).padLeft(4, '0')).join('/');
      expect(connection.writes.map(utf8.decode), ['\x1b]11;rgb:$rgb\x07']);
    });

    test('an armed modifier is not put in front of the answer', () async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);

      final session = sessions.open(intent: UserIntent.fromGesture(), _rose)!;
      await _settle();
      final connection = transport.opened.single;

      sessions.arm(session, {StickyModifier.alt}, repeat: 2);
      connection.emit('\x1b]11;?\x07');
      await _settle();

      expect(connection.writes.single.first, 0x1b);
      expect(connection.writes.single[1], 0x5d);
      expect(session.stickyRepeat, 2);
    });
  });
}
