import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:striked/platform/ssh/host_files.dart' show uploadsSharing;
import 'package:striked/application/agents/agent_kind.dart';
import 'package:striked/platform/herdr/herdr_client.dart';
import 'package:striked/platform/ssh/host_links.dart';
import 'package:striked/platform/herdr/herdr_socket.dart';
import 'package:striked/platform/ssh/host_keys.dart';
import 'package:striked/platform/ssh/keys.dart';

import '../../support/herdr_link.dart';
import '../../support/tarpit.dart';

void main() {
  test('parses a local herdr agent list fixture', () {
    final agents = HerdrClient.parseCliAgentList(
      File('test/fixtures/herdr_agent_list.json').readAsStringSync(),
      session: 'lab',
    );

    expect(agents, hasLength(3));
    expect(agents.first.paneId, 'wQ:p1');
    expect(agents.first.session, 'lab');
    expect(agents.first.agent, 'claude');
    expect(agents.first.state.word, 'idle');
    expect(agents.first.terminalTitleStripped, 'app-init-orchestator');
    expect(agents.first.workspaceId, 'wQ');
    expect(agents.first.cwd, '/home/luisnquin/.dotfiles');
    expect(agents.first.stateChangeSeq, 248);
    expect(HerdrCommands.agents('lab'), contains('agent list --json'));
  });

  test('an agent herdr has not named or titled yet still lists', () {
    final agents = HerdrClient.parseAgentList(const {
      'type': 'agent_list',
      'agents': [
        {
          'terminal_id': 't1',
          'agent_status': 'unknown',
          'workspace_id': 'w1',
          'tab_id': 'w1:t1',
          'pane_id': 'w1:p1',
          'focused': true,
          'state_change_seq': 0,
          'revision': 1,
        },
      ],
    }, session: 'default');

    expect(agents.single.paneId, 'w1:p1');
    expect(agents.single.agent, isEmpty);
    expect(agents.single.terminalTitleStripped, isEmpty);
    expect(agents.single.cwd, isEmpty);
    expect(
      () => HerdrClient.parseAgentList(const {
        'type': 'agent_list',
        'agents': [
          {
            'agent_status': 'idle',
            'workspace_id': 'w1',
            'pane_id': 'w1:p1',
            'state_change_seq': 0,
            'cwd': 7,
          },
        ],
      }, session: 'default'),
      throwsA(
        isA<HerdrProtocolMismatch>().having(
          (error) => error.detail,
          'detail',
          'agent cwd',
        ),
      ),
    );
  });

  test('a workspace is titled by the label herdr lists it under', () {
    Map<String, Object?> result(String name) =>
        (jsonDecode(File('test/fixtures/$name').readAsStringSync())
                as Map<String, Object?>)['result']!
            as Map<String, Object?>;
    final labels = HerdrClient.parseWorkspaceLabels(
      HerdrResult('workspace_list', result('herdr_workspace_list.json')),
    );
    final agents = HerdrClient.labelWorkspaces(
      HerdrClient.parseAgentList(
        result('herdr_agent_list.json'),
        session: 'lab',
      ),
      labels,
    );

    expect(labels, {
      'w1': '~',
      'wK': 'striked',
      'wP': 'striked 2',
      'wQ': 'striked 3',
    });
    expect(agents.map((agent) => agent.workspaceLabel).toSet(), {'striked 3'});
    expect(agents.first.workspaceId, 'wQ');
    expect(agents.first.paneId, 'wQ:p1');
    expect(agents.first.session, 'lab');

    final carried = AgentSnapshot.fromJson(agents.first.toJson());
    expect(carried.workspaceLabel, 'striked 3');
  });

  test('a workspace herdr gives no label keeps only its id', () {
    final agents = HerdrClient.labelWorkspaces(
      HerdrClient.parseAgentList(agentListResult('wZ:p1'), session: 'lab'),
      HerdrClient.parseWorkspaceLabels(
        const HerdrResult('workspace_list', {
          'type': 'workspace_list',
          'workspaces': [
            {'workspace_id': 'wZ', 'label': ''},
          ],
        }),
      ),
    );

    expect(agents.single.workspaceLabel, isNull);
    expect(agents.single.toJson().containsKey('workspace_label'), isFalse);
    expect(
      HerdrClient.parseWorkspaceLabels(
        const HerdrRefusal('invalid_request', 'unknown method'),
      ),
      isEmpty,
    );
  });

  String roster(List<(String, {bool running, bool isDefault})> sessions) =>
      jsonEncode({
        'sessions': [
          for (final (name, :running, :isDefault) in sessions)
            {
              'default': isDefault,
              'name': name,
              'running': running,
              'session_dir': '/run/user/1000/herdr/$name',
              'socket_path': '/run/user/1000/herdr/$name/server.sock',
            },
        ],
      });

  test('every session stamps its own agents', () {
    List<AgentSnapshot> answered(String session, String pane, String agent) =>
        HerdrClient.parseSessionAgents(
          HerdrResult('agent_list', agentListResult(pane, agent: agent)),
          session: session,
        );

    final agents = [
      ...answered('default', 'w1:p1', 'claude'),
      ...answered('lab', 'w1:p1', 'codex'),
    ];

    expect(agents.map((agent) => agent.session), ['default', 'lab']);
    expect(agents.map((agent) => agent.paneId), ['w1:p1', 'w1:p1']);
    expect(agents.map((agent) => agent.agent), ['claude', 'codex']);
    expect(agents.first.pane, (session: 'default', pane: 'w1:p1'));
  });

  test('a session that stopped between the roster and its turn is skipped', () {
    expect(
      HerdrClient.parseSessionAgents(
        const HerdrRefusal('server_not_running', 'no herdr server is running'),
        session: 'lab',
      ),
      isEmpty,
    );
    expect(
      () => HerdrClient.parseSessionAgents(
        const HerdrRefusal('invalid_request', 'unknown method'),
        session: 'lab',
      ),
      throwsA(isA<HerdrProtocolMismatch>()),
    );
  });

  test('the roster carries where each session listens', () {
    final sessions = HerdrClient.parseSessions(
      roster([('default', running: true, isDefault: true)]),
    );

    expect(sessions.single.socketPath, contains('default'));
    expect(
      () => HerdrClient.parseSessions(
        '{"sessions":[{"default":true,"name":"default","running":true}]}',
      ),
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
      expect(
        target([('my session', running: true, isDefault: true)]),
        isA<SpawnTargetRefused>(),
      );
    },
  );

  test('a lookup failure is not a refused connection', () {
    // Dart words the DNS failure in the exception's own message; the errno beneath is EAI_*,
    // a namespace that cannot be told from a connect errno by number.
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
    expect(
      HerdrClient.isLookupFailure(
        const SocketException('Connection timed out'),
      ),
      isFalse,
    );
  });

  test('rejects a response from an unknown protocol shape', () {
    expect(
      () => HerdrClient.parseAgentList(const {
        'type': 'other',
        'protocol': 22,
      }, session: 'default'),
      throwsA(
        isA<HerdrProtocolMismatch>().having(
          (error) => error.protocol,
          'protocol',
          22,
        ),
      ),
    );
    expect(
      asHerdrFailure(const HerdrMalformed('garbage', 20)),
      isA<HerdrProtocolMismatch>().having(
        (error) => error.protocol,
        'protocol',
        20,
      ),
    );
  });

  test('parses a created workspace pane', () {
    expect(
      HerdrClient.parseWorkspacePane(const {
        'type': 'workspace_created',
        'root_pane': {'pane_id': 'wH:p4'},
      }),
      'wH:p4',
    );
    expect(
      () => HerdrClient.parseWorkspacePane(const {
        'type': 'workspace_created',
        'root_pane': {'pane_id': 'bad pane'},
      }),
      throwsA(isA<HerdrProtocolMismatch>()),
    );
  });

  test('a shell at its prompt owns the foreground group alone', () {
    Map<String, Object?> info(int group, List<int> pids) => {
      'type': 'pane_process_info',
      'process_info': {
        'shell_pid': 7,
        'foreground_process_group_id': group,
        'foreground_processes': [
          for (final pid in pids) {'pid': pid, 'name': 'zsh'},
        ],
      },
    };

    expect(HerdrClient.parseShellAtPrompt(info(7, [7])), isTrue);
    // starship or a direnv subshell holding the terminal during rc files
    expect(HerdrClient.parseShellAtPrompt(info(9, [9])), isFalse);
    // a forked child still inside the shell's own group
    expect(HerdrClient.parseShellAtPrompt(info(7, [7, 8])), isFalse);
    expect(HerdrClient.parseShellAtPrompt(info(7, [])), isFalse);
    // a reply without a process group cannot be waited on
    expect(
      HerdrClient.parseShellAtPrompt(const {
        'type': 'pane_process_info',
        'process_info': {'pane_id': 'w1:p1'},
      }),
      isTrue,
    );
    expect(HerdrClient.parseShellAtPrompt(const {}), isTrue);
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

  test('process info names the pane and nothing else', () {
    final request = HerdrRequests.processInfo((session: 'lab', pane: 'w1:p2'));
    expect(request.method, 'pane.process_info');
    expect(request.params, {'pane_id': 'w1:p2'});
    expect(
      () => HerdrRequests.processInfo((session: 'lab', pane: 'w1:p2; reboot')),
      throwsA(isA<HerdrProtocolMismatch>()),
    );
  });

  test('requests reject injected pane ids and keys', () {
    expect(
      () => HerdrRequests.read((session: 'lab', pane: 'wH:p1; reboot')),
      throwsA(isA<HerdrProtocolMismatch>()),
    );
    expect(
      () => HerdrRequests.sendKeys(
        (session: 'lab', pane: 'wH:p1'),
        const ['enter; reboot'],
      ),
      throwsA(isA<HerdrProtocolMismatch>()),
    );
    expect(
      () => HerdrRequests.sendKeys((session: 'lab', pane: 'wH:p1'), const []),
      throwsA(isA<HerdrProtocolMismatch>()),
    );
    expect(
      () => HerdrCommands.attach((session: "lab' reboot '", pane: 'wH:p1')),
      throwsA(isA<HerdrProtocolMismatch>()),
    );
  });

  test('agent startup carries the unattended flags and optional model', () {
    final claude = HerdrRequests.agentStart(
      pane: (session: 'lab', pane: 'wH:p4'),
      name: 'striked-wh',
      kind: const ClaudeKind(),
      model: 'sonnet',
    );
    expect(claude.method, 'agent.start');
    expect(claude.params['name'], 'striked-wh');
    expect(claude.params['kind'], 'claude');
    expect(claude.params['pane_id'], 'wH:p4');
    final args = claude.params['args']! as List<Object?>;
    expect(args.join(' '), contains('dangerously-skip-permissions'));
    expect(args.join(' '), contains('skipDangerousModePermissionPrompt'));
    expect(args, containsAllInOrder(const ['--model', 'sonnet']));

    final codex = HerdrRequests.agentStart(
      pane: (session: 'lab', pane: 'wH:p4'),
      name: 'striked-wh',
      kind: const CodexKind(),
    );
    expect(codex.params['args'], contains('--yolo'));
    expect(
      () => HerdrRequests.agentStart(
        pane: (session: 'lab', pane: 'wH:p4'),
        name: 'striked-wh',
        kind: const CodexKind(),
        model: 'sonnet; reboot',
      ),
      throwsA(isA<ArgumentError>()),
    );
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
    final prompt = HerdrRequests.prompt((session: 'lab', pane: 'w1:p2'), 'go');
    expect(prompt.method, 'agent.prompt');
    expect(prompt.params['target'], 'w1:p2');
    expect(prompt.params['text'], 'go');
    expect(prompt.params['wait'], {
      'until': ['working'],
      'timeout_ms': 6000,
    });
    expect(HerdrClient.isPromptStalled('agent_prompt_stalled'), isTrue);
    expect(HerdrClient.isPromptStalled('timeout'), isTrue);
    expect(HerdrClient.isPromptStalled('agent_blocked'), isFalse);
    expect(HerdrClient.isPromptStalled(null), isFalse);
  });

  test(
    'an agent that has not announced itself is waited out, not reported',
    () {
      expect(HerdrClient.isAgentPending('agent_not_ready'), isTrue);
      expect(HerdrClient.isAgentPending('agent_prompt_stalled'), isFalse);
      expect(HerdrClient.isAgentPending('agent_blocked'), isFalse);
      expect(HerdrClient.isAgentPending(null), isFalse);
    },
  );

  test('wait and read target the pane', () {
    const pane = (session: 'lab', pane: 'w1:p2');
    final wait = HerdrRequests.wait(pane, timeout: const Duration(seconds: 15));
    expect(wait.method, 'agent.wait');
    expect(wait.params, {
      'target': 'w1:p2',
      'until': ['idle'],
      'timeout_ms': 15000,
    });
    expect(HerdrRequests.read(pane, lines: 40).params, {
      'target': 'w1:p2',
      'source': 'visible',
      'lines': 40,
      'format': 'text',
    });
    expect(
      () => HerdrRequests.wait((
        session: 'lab',
        pane: 'w1:p2; reboot',
      ), timeout: Duration.zero),
      throwsA(isA<HerdrProtocolMismatch>()),
    );
  });

  test('a new workspace carries the cwd, the label and the pane mark', () {
    final request = HerdrRequests.workspaceCreate(
      cwd: "/home/dev/checkout with ' quote",
      label: "label with ' quote",
    );

    expect(request.method, 'workspace.create');
    expect(request.params, {
      'cwd': "/home/dev/checkout with ' quote",
      'label': "label with ' quote",
      'env': {'STRIKED_PANE': '1'},
      'focus': false,
    });
    expect(HerdrRequests.workspaceClose('wH').params, const {
      'workspace_id': 'wH',
    });
  });

  test(
    'the directory is resolved and tested before anything is made',
    () async {
      final temp = Directory.systemTemp.createTempSync('striked-herdr-command');
      addTearDown(() => temp.deleteSync(recursive: true));
      final directory = Directory("${temp.path}/checkout with ' quote")
        ..createSync();

      Future<ProcessResult> resolve(String path, {String? home}) => Process.run(
        '/bin/sh',
        ['-c', HerdrCommands.resolveDirectory(path)],
        environment: {'HOME': ?home},
      );

      final found = await resolve(directory.path);
      expect(found.exitCode, 0, reason: '${found.stderr}');
      expect((found.stdout as String).trim(), directory.path);

      final missing = await resolve('${temp.path}/nowhere');
      expect(missing.exitCode, 20);

      final tilde = await resolve('~/checkout with \' quote', home: temp.path);
      expect(tilde.exitCode, 0, reason: '${tilde.stderr}');
      expect((tilde.stdout as String).trim(), directory.path);
    },
  );

  test(
    'an exchange that stops moving is given up on and then let go',
    () async {
      final stalled = Completer<void>();

      await expectLater(
        awaitWithin(stalled.future, const Duration(milliseconds: 20)),
        throwsA(isA<TimeoutException>()),
      );

      // What the abandoned exchange fails with once its channel closes under it must not reach
      // the zone as an unhandled error.
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
    expect(
      uploadDeadline(uploadRate * 4, sharing: uploadsSharing(5)),
      uploadOpening + const Duration(seconds: 12),
    );
  });

  test('a dial that ran out of time does not hang up mid-handshake', () async {
    final keys = Ed25519Keys(MemoryPrivateKeyStore());
    await keys.generate(id: 'k1', name: 'test');
    final privateKey = (await keys.privateKey('k1'))!;
    final tarpit = await openTarpit();

    await expectLater(
      HerdrClient(
        links: HostLinks(timeout: const Duration(milliseconds: 300)),
        use: HostUse.send,
      ).connect(
        address: tarpit.address,
        port: tarpit.port,
        user: 'luis',
        privateKey: privateKey,
        verifier: HostKeyVerifier.pinnedOnly(null),
      ),
      throwsA(isA<HerdrUnreachable>()),
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(tarpit.closedByPeer.isCompleted, isFalse);
  });

  group('a host change watch', () {
    test(
      'sends a listing once, then a beat, and ends with its stdin',
      () async {
        final dir = await Directory.systemTemp.createTemp('striked-watch');
        addTearDown(() => dir.delete(recursive: true));
        final file = File('${dir.path}/listing')..writeAsStringSync('a\nb');
        final command = hostChangesCommand(
          'cat ${file.path}',
          const Duration(seconds: 1),
          beat: const Duration(seconds: 2),
        );
        final process = await Process.start('sh', ['-c', command]);
        final lines = <String>[];
        final arrived = StreamController<void>.broadcast();
        addTearDown(arrived.close);
        process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen((line) {
              lines.add(line);
              arrived.add(null);
            });
        Future<void> until(int count) async {
          while (lines.length < count) {
            await arrived.stream.first.timeout(const Duration(seconds: 5));
          }
        }

        await until(4);
        expect(lines, ['a', 'b', hostChangesEnd, hostChangesBeat]);

        file.writeAsStringSync('c');
        await until(6);
        expect(lines.skip(4), ['c', hostChangesEnd]);

        await process.stdin.close();
        expect(
          await process.exitCode.timeout(const Duration(seconds: 3)),
          isNonZero,
        );
      },
    );

    test('frames listings and drops the beats', () async {
      final stdout = StreamController<List<int>>();
      final frames = <String>[];
      final watch = hostChangeFrames(stdout.stream).listen(frames.add);

      stdout.add(utf8.encode('a\nb\n$hostChangesEnd\n$hostChangesBeat\n'));
      stdout.add(utf8.encode('$hostChangesEnd\n'));
      await Future<void>.delayed(Duration.zero);

      expect(frames, ['a\nb', '']);
      await watch.cancel();
    });

    test('a host that says nothing past the quiet is a dead link', () async {
      const quiet = Duration(milliseconds: 300);
      final stdout = StreamController<List<int>>();
      var went = 0;
      final failed = Completer<Object>();
      final done = Completer<void>();
      hostChangeFrames(
        stdout.stream,
        quiet: quiet,
        onQuiet: () => went++,
      ).listen(null, onError: failed.complete, onDone: done.complete);

      for (var beat = 0; beat < 6; beat++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        stdout.add(utf8.encode('$hostChangesBeat\n'));
      }
      expect(went, 0);

      expect(await failed.future, isA<HerdrUnreachable>());
      await done.future;
      expect(went, 1);
    });
  });
}
