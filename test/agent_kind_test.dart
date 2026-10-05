import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/application/agent_kind.dart';
import 'package:upgrade/application/alerts.dart';
import 'package:upgrade/features/home/agent_mark.dart';

void main() {
  group('the factory', () {
    test('answers the two kinds and refuses a third', () {
      expect(AgentKind.of('claude'), isA<ClaudeKind>());
      expect(AgentKind.of('codex'), isA<CodexKind>());
      expect(() => AgentKind.of('gemini'), throwsArgumentError);
    });

    test('takes the name as it comes off the wire', () {
      expect(AgentKind.of('  CLAUDE '), isA<ClaudeKind>());
    });

    test('the looking-up door answers null instead of throwing', () {
      expect(AgentKind.lookup('gemini'), isNull);
      expect(AgentKind.lookup(''), isNull);
      expect(AgentKind.lookup('codex'), isA<CodexKind>());
    });
  });

  group('each kind', () {
    test('carries the start flags the command used to spell out', () {
      expect(const ClaudeKind().startFlags, const [
        '--settings',
        '{"skipDangerousModePermissionPrompt":true}',
        '--dangerously-skip-permissions',
      ]);
      expect(const CodexKind().startFlags, const ['--yolo']);
    });

    test('says where its models come from', () {
      expect(const ClaudeKind().bundledModels, const [
        'opus',
        'sonnet',
        'fable',
      ]);
      expect(const ClaudeKind().modelsArgv, isEmpty);
      expect(const CodexKind().bundledModels, isNull);
      expect(const CodexKind().modelsArgv, const [
        'codex',
        'debug',
        'models',
        '--bundled',
      ]);
    });

    test('matches its own trust dialog and not the other one', () {
      const claude = ' Yes, I trust this folder\n';
      const codex = ' Do you trust the contents of this directory?\n';
      expect(const ClaudeKind().trustKeys(claude), const ['down', 'enter']);
      expect(const CodexKind().trustKeys(codex), const ['enter']);
      expect(const ClaudeKind().trustKeys(codex), isNull);
      expect(const CodexKind().trustKeys(claude), isNull);
    });

    test('answers a blocked pane with its own keys', () {
      expect(answerKeys('claude', yes: true), const ['enter']);
      expect(answerKeys('claude', yes: false), const ['esc']);
      expect(answerKeys('codex', yes: true), const ['y']);
      expect(answerKeys('codex', yes: false), const ['n']);
    });

    test('names a mark file that is in the bundle', () {
      for (final kind in AgentKind.all) {
        expect(
          File(kind.markAsset).existsSync(),
          isTrue,
          reason: '${kind.name} names ${kind.markAsset} and it is not there',
        );
      }
      expect(AgentKind.all.map((kind) => kind.name), ['claude', 'codex']);
    });
  });

  group('a name that is no agent', () {
    test('still draws the fallback glyph', () {
      expect(agentMarkAsset('gemini'), isNull);
      expect(agentMarkName(''), '?');
    });

    test('is still answered with the keys most TUIs take', () {
      expect(answerKeys('gemini', yes: true), const ['enter']);
      expect(answerKeys('gemini', yes: false), const ['esc']);
    });
  });
}
