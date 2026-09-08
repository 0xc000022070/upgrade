import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spectacle/application/agent_kind.dart';
import 'package:spectacle/platform/herdr_client.dart';

void main() {
  test('parses a local herdr agent list fixture', () {
    final source = File('test/fixtures/herdr_agent_list.json')
        .readAsStringSync();
    final agents = HerdrClient.parseAgentList(source, session: 'lab');

    expect(agents, hasLength(3));
    expect(agents.first.paneId, 'wQ:p1');
    expect(agents.first.session, 'lab');
    expect(agents.first.agent, 'claude');
    expect(agents.first.state.word, 'idle');
    expect(agents.first.terminalTitleStripped, 'app-init-orchestator');
    expect(agents.first.workspaceId, 'wQ');
    expect(agents.first.cwd, '/home/luisnquin/.dotfiles');
    expect(agents.first.stateChangeSeq, 248);
  });

  String agentList(String pane, {String agent = 'claude'}) => jsonEncode({
    'id': 'cli:agent:list',
    'result': {
      'type': 'agent_list',
      'agents': [
        {
          'agent': agent,
          'agent_status': 'working',
          'cwd': '/home/luisnquin/src',
          'pane_id': pane,
          'state_change_seq': 1,
          'terminal_title_stripped': 'spectacle',
          'workspace_id': pane.split(':').first,
        },
      ],
    },
  });

  String roster(List<(String, {bool running, bool isDefault})> sessions) =>
      jsonEncode({
        'sessions': [
          for (final (name, :running, :isDefault) in sessions)
            {'default': isDefault, 'name': name, 'running': running},
        ],
      });

  const stopped =
      '{"id":"cli:agent:list","error":{"code":"server_not_running",'
      '"message":"no herdr server is running"}}';

  test('a sweep of two sessions stamps each agent with its own', () {
    final agents = HerdrClient.parseSweepOutput(
      'default\t${agentList('w1:p1')}\n'
      'lab\t${agentList('w1:p1', agent: 'codex')}\n'
      '${roster([('default', running: true, isDefault: true), ('lab', running: true, isDefault: false)])}\n',
    );

    expect(agents.map((agent) => agent.session), ['default', 'lab']);
    expect(agents.map((agent) => agent.paneId), ['w1:p1', 'w1:p1']);
    expect(agents.map((agent) => agent.agent), ['claude', 'codex']);
    expect(agents.first.pane, (session: 'default', pane: 'w1:p1'));
  });

  test('a session that stopped between the roster and its turn is skipped', () {
    final agents = HerdrClient.parseSweepOutput(
      'default\t${agentList('w1:p1')}\n'
      'lab\t$stopped\n'
      '${roster([('default', running: true, isDefault: true), ('lab', running: true, isDefault: false)])}\n',
    );

    expect(agents.map((agent) => agent.session), ['default']);
  });

  test('a running session that printed no line is a protocol mismatch', () {
    // The roster says the host runs it; the sweep never asked it. That is
    // the host's `session list` no longer reading the way the sweep reads it,
    // and an empty panel would hide it.
    expect(
      () => HerdrClient.parseSweepOutput(
        'default\t${agentList('w1:p1')}\n'
        '${roster([('default', running: true, isDefault: true), ('lab', running: true, isDefault: false)])}\n',
      ),
      throwsA(isA<HerdrProtocolMismatch>()),
    );
    // A stopped one it never asked is fine: nothing to answer.
    expect(
      HerdrClient.parseSweepOutput(
        'default\t${agentList('w1:p1')}\n'
        '${roster([('default', running: true, isDefault: true), ('lab', running: false, isDefault: false)])}\n',
      ),
      hasLength(1),
    );
  });

  test('an empty roster is an empty frame, and no roster is no frame', () {
    expect(HerdrClient.parseSweepOutput('${roster([])}\n'), isEmpty);
    expect(
      HerdrClient.parseSweepOutput(
        '${roster([('default', running: false, isDefault: true)])}\n',
      ),
      isEmpty,
    );
    expect(
      () => HerdrClient.parseSweepOutput(''),
      throwsA(isA<HerdrProtocolMismatch>()),
    );
    expect(
      () => HerdrClient.parseSweepOutput('herdr: command not found\n'),
      throwsA(isA<HerdrProtocolMismatch>()),
    );
  });

  test(
    'the spawn target is the running default, else the only one running',
    () {
      SpawnTarget target(List<(String, {bool running, bool isDefault})> rows) =>
          HerdrClient.spawnTarget(HerdrClient.parseSessions(roster(rows)));

      expect(
        target([
          ('default', running: true, isDefault: true),
          ('lab', running: true, isDefault: false),
        ]),
        isA<SpawnTargetSession>().having((t) => t.name, 'name', 'default'),
      );
      expect(
        target([
          ('default', running: false, isDefault: true),
          ('hub', running: true, isDefault: false),
        ]),
        isA<SpawnTargetSession>().having((t) => t.name, 'name', 'hub'),
      );
      expect(
        target([('default', running: false, isDefault: true)]),
        isA<SpawnTargetRefused>().having(
          (t) => t.refusal,
          'refusal',
          SpawnRefusal.noSession,
        ),
      );
      expect(
        target([
          ('default', running: false, isDefault: true),
          ('lab', running: true, isDefault: false),
          ('hub', running: true, isDefault: false),
        ]),
        isA<SpawnTargetRefused>().having(
          (t) => t.refusal,
          'refusal',
          SpawnRefusal.noDefaultSession,
        ),
      );
      // A name the app would never put on a line is not a session it can use.
      expect(
        target([('my session', running: true, isDefault: true)]),
        isA<SpawnTargetRefused>(),
      );
    },
  );

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
        session: 'default',
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

  test('a shell at its prompt owns the foreground group alone', () {
    String info(int group, List<int> pids) =>
        '{"result":{"process_info":{"shell_pid":7,'
        '"foreground_process_group_id":$group,"foreground_processes":['
        '${pids.map((pid) => '{"pid":$pid,"name":"zsh"}').join(',')}]}}}';

    expect(HerdrClient.parseShellAtPrompt(info(7, [7])), isTrue);
    // starship or a direnv subshell holding the terminal during rc files
    expect(HerdrClient.parseShellAtPrompt(info(9, [9])), isFalse);
    // a forked child still inside the shell's own group
    expect(HerdrClient.parseShellAtPrompt(info(7, [7, 8])), isFalse);
    expect(HerdrClient.parseShellAtPrompt(info(7, [])), isFalse);
    // a reply without a process group cannot be waited on
    expect(
      HerdrClient.parseShellAtPrompt(
        '{"result":{"process_info":{"pane_id":"w1:p1"}}}',
      ),
      isTrue,
    );
    expect(HerdrClient.parseShellAtPrompt('{"result":{}}'), isTrue);
    expect(HerdrClient.parseShellAtPrompt('not json'), isTrue);
    expect(
      HerdrClient.parseErrorCode(
        '{"error":{"code":"agent_pane_busy","message":"busy"},"id":"x"}',
      ),
      'agent_pane_busy',
    );
    expect(HerdrClient.parseErrorCode('not json'), isNull);
    expect(HerdrClient.parseErrorCode('{"result":{}}'), isNull);
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

  test('process info targets the pane under the session', () {
    final command = HerdrCommands.processInfo((session: 'lab', pane: 'w1:p2'));
    expect(command, contains('pane process-info --pane'));
    expect(command, contains('w1:p2'));
    expect(command, matches(r"HERDR_SESSION=('|'\\'')lab"));
    expect(
      () => HerdrCommands.processInfo((session: 'lab', pane: 'w1:p2; reboot')),
      throwsA(isA<HerdrProtocolMismatch>()),
    );
  });

  test('remote commands reject injected pane ids, keys and sessions', () {
    expect(
      () => HerdrCommands.read((session: 'lab', pane: 'wH:p1; reboot')),
      throwsA(isA<HerdrProtocolMismatch>()),
    );
    expect(
      () => HerdrCommands.keys(
        (session: 'lab', pane: 'wH:p1'),
        const ['enter; reboot'],
      ),
      throwsA(isA<HerdrProtocolMismatch>()),
    );
    expect(
      () => HerdrCommands.keys(
        (session: "lab' reboot '", pane: 'wH:p1'),
        const ['enter'],
      ),
      throwsA(isA<HerdrProtocolMismatch>()),
    );
    expect(
      () => HerdrCommands.workspaceClose('wH', session: 'a b'),
      throwsA(isA<HerdrProtocolMismatch>()),
    );
  });

  test('agent startup carries the unattended flags and optional model', () {
    final claude = HerdrCommands.agentStart(
      pane: (session: 'lab', pane: 'wH:p4'),
      name: 'spectacle-wh',
      kind: const ClaudeKind(),
      model: 'sonnet',
    );
    expect(claude, contains('dangerously-skip-permissions'));
    expect(claude, contains('skipDangerousModePermissionPrompt'));
    expect(claude, contains('--model'));
    expect(claude, contains('sonnet'));
    expect(claude, matches(r"HERDR_SESSION=('|'\\'')lab"));

    final codex = HerdrCommands.agentStart(
      pane: (session: 'lab', pane: 'wH:p4'),
      name: 'spectacle-wh',
      kind: const CodexKind(),
    );
    expect(codex, contains('--yolo'));
  });

  test('trust dialogs are recognised per agent and answered with keys', () {
    const claude = '''
 Quick safety check: Is this a project you created or one you trust?
 ❯ No, exit
   Yes, I trust this folder
 Enter to confirm · Esc to cancel
''';
    const codex = '''
  Do you trust the contents of this directory? Working with untrusted
› 1. Yes, continue
  2. No, quit
''';
    const idle = '❯\n  ⏵⏵ bypass permissions on (shift+tab to cycle)\n';
    expect(const ClaudeKind().trustKeys(claude), ['down', 'enter']);
    expect(const CodexKind().trustKeys(codex), ['enter']);
    expect(const ClaudeKind().trustKeys(idle), isNull);
    expect(const ClaudeKind().trustKeys(codex), isNull);
    expect(const CodexKind().trustKeys(claude), isNull);
  });

  test('a prompt waits for the agent to take it and a stall is retryable', () {
    final prompt = HerdrCommands.prompt((session: 'lab', pane: 'w1:p2'));
    expect(prompt, contains('agent prompt'));
    expect(prompt, contains('--wait --until working --timeout 6000'));
    expect(
      HerdrClient.isPromptStalled(
        '{"error":{"code":"agent_prompt_stalled","message":"x"}}',
      ),
      isTrue,
    );
    expect(
      HerdrClient.isPromptStalled(
        '{"error":{"code":"timeout","message":"timed out waiting"}}',
      ),
      isTrue,
    );
    expect(
      HerdrClient.isPromptStalled(
        '{"error":{"code":"agent_blocked","message":"x"}}',
      ),
      isFalse,
    );
    expect(HerdrClient.isPromptStalled(''), isFalse);
  });

  test('wait and read target the pane under the session', () {
    const pane = (session: 'lab', pane: 'w1:p2');
    final wait = HerdrCommands.wait(pane, timeout: const Duration(seconds: 15));
    expect(wait, contains('agent wait'));
    expect(wait, contains('w1:p2'));
    expect(wait, contains('--until idle --timeout 15000'));
    expect(wait, matches(r"HERDR_SESSION=('|'\\'')lab"));
    expect(
      HerdrCommands.read(pane, lines: 40),
      contains('--lines 40 --format text'),
    );
    expect(
      () => HerdrCommands.wait((
        session: 'lab',
        pane: 'w1:p2; reboot',
      ), timeout: Duration.zero),
      throwsA(isA<HerdrProtocolMismatch>()),
    );
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
          session: 'test.session-1',
        ),
      ],
      environment: {'PATH': '${bin.path}:/usr/bin:/bin'},
    );

    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect((result.stdout as String).trim().split('\n'), [
      'session=test.session-1',
      'workspace',
      'create',
      '--cwd',
      directory.path,
      '--label',
      "label with ' quote",
      '--no-focus',
    ]);
  });

  test(
    'an exchange that stops moving is given up on and then let go',
    () async {
      final stalled = Completer<void>();

      await expectLater(
        awaitWithin(stalled.future, const Duration(milliseconds: 20)),
        throwsA(isA<TimeoutException>()),
      );

      // What the abandoned exchange fails with once its channel closes under it
      // has nowhere to go, and must not reach the zone as an unhandled error.
      stalled.completeError(const SocketException('channel closed'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    },
  );

  test('an exchange already inside a deadline is waited on whole', () async {
    final finished = Completer<void>();
    var done = false;
    unawaited(awaitWithin(finished.future, null).then((_) => done = true));

    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(done, isFalse);

    finished.complete();
    await Future<void>.delayed(Duration.zero);
    expect(done, isTrue);
  });

  test('an upload is given the time its own bytes need and no more', () {
    expect(uploadDeadline(0), uploadOpening);
    expect(
      uploadDeadline(uploadRate * 4),
      uploadOpening + const Duration(seconds: 4),
    );
    expect(
      uploadDeadline(8 * 1024 * 1024),
      lessThan(const Duration(minutes: 7)),
    );
    expect(
      uploadDeadline(2 * 1024 * 1024),
      greaterThan(uploadDeadline(1024 * 1024)),
    );
  });
}
