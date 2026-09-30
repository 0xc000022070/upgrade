import 'package:dazzle/application/agent_state.dart';
import 'package:dazzle/application/agents.dart';
import 'package:dazzle/application/alerts.dart';
import 'package:dazzle/data/repositories/host_repository.dart';
import 'package:dazzle/features/agents/agents_screen.dart';
import 'package:dazzle/platform/agent_watcher.dart';
import 'package:dazzle/platform/engine_agents.dart';
import 'package:dazzle/platform/herdr_client.dart';
import 'package:dazzle/platform/host_keys.dart';
import 'package:flutter_test/flutter_test.dart';

final pinned = PinnedHostKey(
  type: 'ssh-ed25519',
  fingerprint: 'SHA256:abc',
  pinnedAt: DateTime.utc(2026, 9, 29),
);

final host = Host(
  id: 'h1',
  name: 'nyx',
  address: '100.64.0.1',
  port: 22,
  user: 'dev',
  keyId: 'k1',
  hostKey: pinned,
);

Map<String, Object?> session({
  String key = 'claude:s1',
  String state = 'blocked',
  Object? approval,
  String? herdrPane,
  String? title,
  String? prompt,
}) => {
  'key': key,
  'agent': 'claude',
  'session_id': 's1',
  'state': state,
  'started': 1,
  'updated': 7,
  'cwd': '/home/dev/Projects/fixture',
  'title': title,
  'prompt': prompt,
  'message': 'last word',
  'approval': approval,
  'question': null,
  'herdr_pane': herdrPane,
};

AgentSnapshot herdrRow(String pane) => AgentSnapshot(
  session: 'development',
  paneId: pane,
  agent: 'claude',
  state: AgentState.of('working'),
  terminalTitleStripped: 'claude',
  workspaceId: 'w1',
  cwd: '/home/dev',
  stateChangeSeq: 1,
);

void main() {
  group('the watch answer', () {
    test('keeps live sessions and drops the ended ones', () {
      final watch = EngineAgents.parseWatch({
        'generation': 3,
        'now': 9,
        'sessions': [
          session(
            approval: {'id': 'a1', 'tool': 'Bash', 'summary': 'rm -rf build'},
          ),
          session(key: 'codex:s2', state: 'ended'),
        ],
      });

      expect(watch.generation, 3);
      final agent = watch.agents.single;
      expect(agent.engine, isTrue);
      expect(agent.paneId, 'claude:s1');
      expect(agent.stateChangeSeq, 7);
      expect(agent.approval?.line, 'Bash · rm -rf build');
      expect(agent.edgeId, 'claude:s1#a1');
      expect(AgentSnapshot.paneOfEdge(agent.edgeId), 'claude:s1');
    });

    test(
      'titles a session by its title, then its prompt, then its last word',
      () {
        String titled(Map<String, Object?> json) =>
            EngineAgents.snapshotOf(json)!.terminalTitleStripped;

        expect(titled(session(title: 'fix it', prompt: 'p')), 'fix it');
        expect(titled(session(prompt: 'the prompt')), 'the prompt');
        expect(titled(session()), 'last word');
      },
    );

    test('an answer without sessions is a protocol mismatch', () {
      expect(
        () => EngineAgents.parseWatch({'generation': 1}),
        throwsA(isA<HerdrProtocolMismatch>()),
      );
    });
  });

  test('a transcript page keeps its items and where it stopped', () {
    final page = EngineAgents.parseTranscript({
      'items': [
        {'index': 0, 'kind': 'user', 'text': 'hi'},
        {
          'index': 1,
          'kind': 'tool',
          'text': 'ls',
          'tool': 'Bash',
          'tool_id': 't1',
        },
        {'index': 2, 'kind': 'result', 'text': 'boom', 'error': true},
        {'kind': 'user'},
      ],
      'last': 2,
    });

    expect(page.last, 2);
    expect(page.items.map((item) => item.kind), ['user', 'tool', 'result']);
    expect(page.items[1].tool, 'Bash');
    expect(page.items[2].error, isTrue);
  });

  test('hook entries given as json are shown pretty', () {
    final hooks = EngineAgents.parseHooks({
      'agents': [
        {
          'agent': 'claude',
          'config_path': '/home/dev/.claude/settings.json',
          'installed': false,
          'writable': false,
          'entries': {'hooks': <String, Object?>{}},
        },
        {
          'agent': 'opencode',
          'config_path': '/home/dev/.config/opencode/plugin/dazzle.js',
          'installed': true,
          'writable': true,
          'entries': 'export default {}',
        },
      ],
    });

    expect(hooks.first.entries, '{\n  "hooks": {}\n}');
    expect(hooks.first.writable, isFalse);
    expect(hooks.last.entries, 'export default {}');
  });

  group('linking', () {
    test('an engine session claims the herdr row of its pane', () {
      final engine = EngineAgents.snapshotOf(session(herdrPane: 'p2'))!;
      final linked = linkAgents([
        HostOutcome(
          host: host,
          kind: AgentOutcomeKind.snapshot,
          agents: [herdrRow('p1'), herdrRow('p2')],
        ),
        HostOutcome(
          host: host,
          kind: AgentOutcomeKind.snapshot,
          source: AgentSource.engine,
          agents: [engine],
        ),
      ]);

      expect(linked.first.agents.map((agent) => agent.paneId), ['p1']);
      expect(linked.last.agents.single.link, (
        session: 'development',
        pane: 'p2',
      ));
    });

    test('a pane herdr does not report is left alone', () {
      final engine = EngineAgents.snapshotOf(session(herdrPane: 'p9'))!;
      final linked = linkAgents([
        HostOutcome(
          host: host,
          kind: AgentOutcomeKind.snapshot,
          agents: [herdrRow('p1')],
        ),
        HostOutcome(
          host: host,
          kind: AgentOutcomeKind.snapshot,
          source: AgentSource.engine,
          agents: [engine],
        ),
      ]);

      expect(linked.first.agents, hasLength(1));
      expect(linked.last.agents.single.link, isNull);
    });
  });

  test('an engine alert survives the notification payload', () {
    final snapshot = EngineAgents.snapshotOf(
      session(
        approval: {'id': 'a1', 'tool': 'Bash', 'summary': 'rm -rf build'},
      ),
    )!;
    final target = AlertTarget.forHost(
      host,
      snapshot,
      channel: channelKey(host.id, AgentSource.engine),
    );
    final decoded = AlertTarget.decode(target.encode())!;

    expect(decoded.engine, isTrue);
    expect(decoded.approvalId, 'a1');
    expect(decoded.edge, 'claude:s1#a1');
    expect(decoded.text, 'Bash · rm -rf build');
    expect(decoded.hostKey?.fingerprint, 'SHA256:abc');
    expect(decoded.notificationId, target.notificationId);
  });

  test('a herdr alert keeps the id it had before the engine', () {
    final target = AlertTarget.forHost(host, herdrRow('p1'));

    expect(target.engine, isFalse);
    expect(target.channel, host.id);
    expect(target.hostKey, host.hostKey);
  });

  test('the watcher keeps which ways each host is heard', () {
    final raw = encodeWatcherHosts(
      [host],
      sources: {
        host.id: {AgentSource.herdr, AgentSource.engine},
      },
    );

    expect(decodeWatcherHosts(raw).single.id, host.id);
    expect(decodeWatcherSources(raw)[host.id], {
      AgentSource.herdr,
      AgentSource.engine,
    });
  });

  test('a blocked inbox row names what it waits on', () {
    final blocked = EngineAgents.snapshotOf(
      session(
        title: 'fix it',
        approval: {'id': 'a1', 'tool': 'Bash', 'summary': 'rm -rf build'},
      ),
    )!;
    final working = EngineAgents.snapshotOf(
      session(state: 'working', title: 'fix it'),
    )!;

    expect(inboxLine(blocked), 'Bash · rm -rf build');
    expect(inboxLine(working), 'fix it');
  });
}
