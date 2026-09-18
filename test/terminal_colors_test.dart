import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/data/repositories/host_repository.dart';
import 'package:dazzle/design/tokens.dart';
import 'package:dazzle/platform/vnc/keysyms.dart';
import 'package:xterm/xterm.dart';

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
const _colors = TerminalColors(
  foreground: 0xFFE8E8E8,
  background: 0xFF08090B,
  cursor: 0xFFB7FF2A,
);

({Terminal terminal, List<String> reports, List<String> unknown}) _terminal({
  TerminalColors? colors = _colors,
}) {
  final reports = <String>[];
  final unknown = <String>[];
  final terminal = Terminal(
    colors: colors,
    onReport: reports.add,
    onOutput: (data) => fail('the user typed nothing: $data'),
    onPrivateOSC: (code, args) => unknown.add('$code;${args.join(';')}'),
  );
  return (terminal: terminal, reports: reports, unknown: unknown);
}

void main() {
  group('a colour the terminal is drawn in', () {
    test('the background is answered in sixteen-bit channels', () {
      final it = _terminal();

      it.terminal.write('\x1b]11;?\x07');

      expect(it.reports, ['\x1b]11;rgb:0808/0909/0b0b\x07']);
    });

    test('the foreground and the cursor answer on their own slots', () {
      final it = _terminal();

      it.terminal.write('\x1b]10;?\x07\x1b]12;?\x07');

      expect(it.reports, [
        '\x1b]10;rgb:e8e8/e8e8/e8e8\x07',
        '\x1b]12;rgb:b7b7/ffff/2a2a\x07',
      ]);
    });

    test('an answer ends the way the question did', () {
      final it = _terminal();

      it.terminal.write('\x1b]11;?\x1b\\');

      // A program that asked with ST reads until ST; a bell would leave it waiting on a reply
      // it has already been sent.
      expect(it.reports, ['\x1b]11;rgb:0808/0909/0b0b\x1b\\']);
    });

    test('one question can ask for the next colours in turn', () {
      final it = _terminal();

      it.terminal.write('\x1b]10;?;?;?\x07');

      expect(it.reports, [
        '\x1b]10;rgb:e8e8/e8e8/e8e8\x07',
        '\x1b]11;rgb:0808/0909/0b0b\x07',
        '\x1b]12;rgb:b7b7/ffff/2a2a\x07',
      ]);
    });

    test('a question split across two reads is still one question', () {
      final it = _terminal();

      it.terminal.write('\x1b]11');
      it.terminal.write(';?\x07');

      expect(it.reports, ['\x1b]11;rgb:0808/0909/0b0b\x07']);
    });

    test('a terminal told no colours answers nothing', () {
      final it = _terminal(colors: null);

      it.terminal.write('\x1b]11;?\x07');

      expect(it.reports, isEmpty);
    });
  });

  group('what is not a question', () {
    test('a colour being set is left where it was', () {
      final it = _terminal();

      it.terminal.write('\x1b]11;#161821\x07');

      expect(it.reports, isEmpty);
      expect(it.unknown, ['11;#161821']);
    });

    test('a colour being put back is left where it was', () {
      final it = _terminal();

      it.terminal.write('\x1b]111\x07');

      expect(it.reports, isEmpty);
      expect(it.unknown, ['111;']);
    });

    test('a question about a colour there is no name for is not answered', () {
      final it = _terminal();

      // Four marks from slot 10 runs past the cursor, into the colours this terminal has
      // nothing to say about.
      it.terminal.write('\x1b]10;?;?;?;?\x07');

      expect(it.reports, isEmpty);
      expect(it.unknown, ['10;?;?;?;?']);
    });

    test('a title still sets the title', () {
      final it = _terminal();
      final titles = <String>[];
      it.terminal.onTitleChange = titles.add;

      it.terminal.write('\x1b]2;rose\x07');

      expect(titles, ['rose']);
      expect(it.reports, isEmpty);
    });
  });

  group('a session answers with the ground it is drawn on', () {
    test('the reply carries the house terminal, not a default', () async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);

      final session = sessions.open(_rose)!;
      await _settle();
      final connection = transport.opened.single;

      session.terminal.write('\x1b]11;?\x07');

      final ground = DazzleTokens.house.terminal.background;
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

      final session = sessions.open(_rose)!;
      await _settle();
      final connection = transport.opened.single;

      sessions.arm(session, {StickyModifier.alt}, repeat: 2);
      session.terminal.write('\x1b]11;?\x07');

      expect(connection.writes.single.first, 0x1b);
      expect(connection.writes.single[1], 0x5d);
      expect(session.stickyRepeat, 2);
    });
  });
}
