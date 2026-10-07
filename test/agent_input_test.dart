import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/application/agent_input.dart';
import 'package:upgrade/application/agent_kind.dart';

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

void main() {
  test('the marked foreground process identifies Codex and Claude', () {
    expect(
      foregroundAgent('codex\t/nix/store/codex/bin/.codex-wrapped\t\n'),
      isA<CodexKind>(),
    );
    expect(
      foregroundAgent('claude\t/nix/store/claude/bin/.claude-wrapped\t\n'),
      isA<ClaudeKind>(),
    );
    expect(
      foregroundAgent(
        'node\t/usr/bin/node\t'
        '/home/dev/.npm/@anthropic-ai/claude-code/cli.js\n',
      ),
      isA<ClaudeKind>(),
    );
    expect(
      foregroundAgent(
        'claude\t/home/dev/.local/share/claude/versions/2.1.287\t\n',
      ),
      isA<ClaudeKind>(),
    );
    expect(
      foregroundAgent(
        'node\t/usr/bin/node\t'
        '/home/dev/.npm/@openai/codex/bin/codex.js\n',
      ),
      isA<CodexKind>(),
    );
    expect(foregroundAgent('zsh\t/usr/bin/zsh\t\n'), isNull);
    expect(
      foregroundAgent(
        'codex\t/nix/store/codex/bin/.codex-wrapped\t\n'
        'claude\t/home/dev/.local/bin/claude\t\n',
      ),
      isNull,
    );
    expect(
      foregroundAgent(
        'zsh\t/usr/bin/zsh\t\n'
        'codex\t/nix/store/codex/bin/.codex-wrapped\t\n',
      ),
      isNull,
    );
  });

  test('typed input clears after deletion, submit, and uncertain edits', () {
    final input = AgentInputActivity();
    input.observe(_bytes('á '));
    expect(input.hasText, isTrue);
    input.observe(Uint8List.fromList([0x7f, 0x7f]));
    expect(input.hasText, isFalse);

    input.observe(_bytes('hello'));
    input.observe(_bytes('\x1b[D'));
    expect(input.hasText, isFalse);
    input.observe(_bytes('x'));
    expect(input.hasText, isTrue);
    input.observe(Uint8List.fromList([0x0d]));
    expect(input.hasText, isFalse);

    input.observe(_bytes('again'));
    input.observe(Uint8List.fromList([0x15]));
    expect(input.hasText, isFalse);
  });

  test('application arrows and Alt keys do not count as typed text', () {
    final input = AgentInputActivity();
    for (final key in ['\x1bOA', '\x1bOD', '\x1bb']) {
      input.observe(_bytes(key));
      expect(input.hasText, isFalse);
    }
    input.observe(_bytes('hello'));
    expect(input.hasText, isTrue);
    input.observe(_bytes('\x1bOD'));
    expect(input.hasText, isFalse);
  });

  test('bracketed multiline paste stays pending until Enter', () {
    final input = AgentInputActivity();
    input.observe(_bytes('\x1b[200~first\nsecond\x1b[201~'));
    expect(input.hasText, isTrue);
    input.observe(Uint8List.fromList([0x0d]));
    expect(input.hasText, isFalse);
  });
}
