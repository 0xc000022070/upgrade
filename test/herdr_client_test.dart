import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spectacle/platform/herdr_client.dart';

void main() {
  test('parses a local herdr agent list fixture', () {
    final source = File('test/fixtures/herdr_agent_list.json')
        .readAsStringSync();
    final agents = HerdrClient.parseAgentList(source);

    expect(agents, hasLength(3));
    expect(agents.first.paneId, 'wQ:p1');
    expect(agents.first.agent, 'claude');
    expect(agents.first.agentStatus, 'idle');
    expect(agents.first.terminalTitleStripped, 'app-init-orchestator');
    expect(agents.first.workspaceId, 'wQ');
    expect(agents.first.cwd, '/home/luisnquin/.dotfiles');
    expect(agents.first.stateChangeSeq, 248);
  });

  test('a lookup failure is not a refused connection', () {
    // Dart words the DNS failure in the exception's own message; the errno
    // beneath is EAI_*, a namespace that cannot be told from a connect errno
    // by number, which is why this reads the words.
    expect(
      HerdrClient.isLookupFailure(
        const SocketException(
          "Failed host lookup: 'nope.invalid'",
          osError: OSError('No address associated with hostname', -5),
        ),
      ),
      isTrue,
    );
    expect(
      HerdrClient.isLookupFailure(
        const SocketException(
          'Connection refused',
          osError: OSError('Connection refused', 111),
        ),
      ),
      isFalse,
    );
    // A tarpit that accepts and never speaks is a timeout, not a lookup.
    expect(
      HerdrClient.isLookupFailure(
        const SocketException('Connection timed out'),
      ),
      isFalse,
    );
  });

  test('rejects a response from an unknown protocol shape', () {
    expect(
      () => HerdrClient.parseAgentList(
        '{"protocol":22,"result":{"type":"other"}}',
      ),
      throwsA(
        isA<HerdrProtocolMismatch>().having(
          (error) => error.protocol,
          'protocol',
          22,
        ),
      ),
    );
  });

  test('parses a created workspace pane', () {
    expect(
      HerdrClient.parseWorkspacePane(
        '{"result":{"root_pane":{"pane_id":"wH:p4"}}}',
      ),
      'wH:p4',
    );
    expect(
      () => HerdrClient.parseWorkspacePane(
        '{"result":{"root_pane":{"pane_id":"bad pane"}}}',
      ),
      throwsA(isA<HerdrProtocolMismatch>()),
    );
  });

  test('parses checkout lines and both model response shapes', () {
    expect(HerdrClient.parsePaths('~/src/a\n~/src/b\n'), [
      '~/src/a',
      '~/src/b',
    ]);
    expect(HerdrClient.parsePaths('["~/src/a"]'), ['~/src/a']);
    expect(HerdrClient.parseModels('["opus","sonnet"]'), ['opus', 'sonnet']);
    expect(
      HerdrClient.parseModels(
        '{"models":[{"slug":"gpt-5.3-codex"},{"slug":"gpt-5.4"}]}',
      ),
      ['gpt-5.3-codex', 'gpt-5.4'],
    );
  });

  test('remote commands reject injected pane ids and keys', () {
    expect(
      () => HerdrCommands.read('wH:p1; reboot'),
      throwsA(isA<HerdrProtocolMismatch>()),
    );
    expect(
      () => HerdrCommands.keys('wH:p1', const ['enter; reboot']),
      throwsA(isA<HerdrProtocolMismatch>()),
    );
  });

  test('agent startup carries the unattended flags and optional model', () {
    final claude = HerdrCommands.agentStart(
      pane: 'wH:p4',
      name: 'spectacle-wh',
      kind: 'claude',
      model: 'sonnet',
    );
    expect(claude, contains('dangerously-skip-permissions'));
    expect(claude, contains('skipDangerousModePermissionPrompt'));
    expect(claude, contains('--model'));
    expect(claude, contains('sonnet'));

    final codex = HerdrCommands.agentStart(
      pane: 'wH:p4',
      name: 'spectacle-wh',
      kind: 'codex',
    );
    expect(codex, contains('--yolo'));
  });

  test('workspace command preserves quoted paths and session names', () async {
    final temp = Directory.systemTemp.createTempSync('spectacle-herdr-command');
    addTearDown(() => temp.deleteSync(recursive: true));
    final bin = Directory('${temp.path}/bin')..createSync();
    final herdr = File('${bin.path}/herdr')
      ..writeAsStringSync(
        '#!/bin/sh\nprintf "session=%s\\n" "\$HERDR_SESSION"\n'
        'printf "%s\\n" "\$@"\n',
      );
    expect(Process.runSync('chmod', ['+x', herdr.path]).exitCode, 0);
    final directory = Directory("${temp.path}/checkout with ' quote")
      ..createSync();

    final result = await Process.run(
      '/bin/sh',
      [
        '-c',
        HerdrCommands.workspaceCreate(
          directory.path,
          label: "label with ' quote",
          session: 'test session',
        ),
      ],
      environment: {'PATH': '${bin.path}:/usr/bin:/bin'},
    );

    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect((result.stdout as String).trim().split('\n'), [
      'session=test session',
      'workspace',
      'create',
      '--cwd',
      directory.path,
      '--label',
      "label with ' quote",
      '--no-focus',
    ]);
  });
}
