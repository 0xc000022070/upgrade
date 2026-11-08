import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/platform/herdr/agent_state.dart';
import 'package:upgrade/application/agents/agents.dart';
import 'package:upgrade/application/launcher/launcher_feed.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/platform/herdr/herdr_client.dart';
import 'package:upgrade/platform/launcher_widget/launcher_widget.dart';

const _pine = Host(
  id: 'h1',
  name: 'pine',
  address: '100.64.0.1',
  port: 22,
  user: 'alex',
  keyId: 'key-1',
);

AgentSnapshot _agent(
  String pane,
  String state, {
  String title = 'make test',
  AgentSource source = AgentSource.herdr,
  String? herdrPane,
  String? question,
  String? message,
  AgentApproval? approval,
}) => AgentSnapshot(
  session: 'default',
  paneId: pane,
  agent: 'claude',
  state: AgentState.of(state),
  terminalTitleStripped: title,
  workspaceId: 'wQ',
  cwd: '/workspace',
  stateChangeSeq: 1,
  source: source,
  herdrPane: herdrPane,
  question: question,
  message: message,
  approval: approval,
);

HostOutcome _ok(
  List<AgentSnapshot> agents, {
  AgentSource source = AgentSource.herdr,
}) => HostOutcome(
  host: _pine,
  kind: AgentOutcomeKind.snapshot,
  agents: agents,
  source: source,
);

const _down = HostOutcome(host: _pine, kind: AgentOutcomeKind.unreachable);

const OpenSend _send = (
  id: 's1',
  host: 'h1',
  session: 'default',
  pane: 'wQ:p1',
);

void main() {
  group('the launcher tally', () {
    test('counts blocked and working agents and nothing else', () {
      final tally = launcherTally([
        _ok([
          _agent('wQ:p1', 'blocked'),
          _agent('wQ:p2', 'working'),
          _agent('wQ:p3', 'working'),
          _agent('wQ:p4', 'idle'),
        ]),
      ]);
      expect(tally, (blocked: 1, working: 2));
    });

    test('is not drawn with nothing working or blocked', () {
      expect(
        launcherTally([
          _ok([_agent('wQ:p1', 'done')]),
        ]),
        isNull,
      );
      expect(launcherTally(const []), isNull);
    });

    test('drops while a watched host is failing', () {
      expect(
        launcherTally([
          _ok([_agent('wQ:p1', 'working')]),
          _down,
        ]),
        isNull,
      );
    });
  });

  group('a send\'s live state', () {
    test('is its pane\'s agent with the terminal title', () {
      final live = launcherLive(
        [_send],
        [
          _ok([_agent('wQ:p1', 'working', title: 'running tests')]),
        ],
        const {},
      );
      expect(live['s1'], (state: 'WORKING', line: 'running tests', dim: false));
    });

    test('reads the approval while blocked, else the engine\'s message', () {
      const approval = AgentApproval(id: 'a', tool: 'Bash', summary: 'rm -rf');
      final blocked = launcherLive(
        [_send],
        [
          _ok([_agent('wQ:p1', 'blocked', approval: approval)]),
        ],
        const {},
      );
      expect(blocked['s1']!.line, 'Bash · rm -rf');

      final working = launcherLive(
        [_send],
        [
          _ok([_agent('wQ:p1', 'working')]),
          _ok([
            _agent(
              'e1',
              'working',
              source: AgentSource.engine,
              herdrPane: 'wQ:p1',
              message: 'Patched the parser',
            ),
          ], source: AgentSource.engine),
        ],
        const {},
      );
      expect(working['s1']!.line, 'Patched the parser');
    });

    test('is ENDED once its pane is gone', () {
      final live = launcherLive([_send], [_ok(const [])], const {});
      expect(live['s1']!.state, 'ENDED');
    });

    test('keeps its last state, dimmed, while its host fails', () {
      final live = launcherLive([_send], const [_down], {
        's1': (state: 'WORKING', line: 'make', dim: false),
      });
      expect(live['s1'], (state: 'WORKING', line: 'make', dim: true));
      expect(launcherLive([_send], const [_down], const {}), isEmpty);
    });

    test('says nothing for a host nothing watches', () {
      expect(launcherLive([_send], const [], const {}), isEmpty);
    });
  });
}
