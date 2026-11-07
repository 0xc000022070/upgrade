import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/application/agents/agent_state.dart';
import 'package:upgrade/application/agents/agents.dart';
import 'package:upgrade/application/agents/run_steps.dart';
import 'package:upgrade/application/agents/send_states.dart';
import 'package:upgrade/data/repositories/dispatch_repository.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/platform/herdr/engine_agents.dart';
import 'package:upgrade/platform/herdr/herdr_client.dart';

TranscriptItem _item(
  int index,
  String kind,
  String text, {
  String? tool,
  String? id,
}) => TranscriptItem(
  index: index,
  kind: kind,
  text: text,
  tool: tool,
  toolId: id,
);

const _host = Host(
  id: 'host-1',
  name: 'oak',
  address: '100.64.0.1',
  port: 22,
  user: 'luis',
  keyId: 'key-1',
);

Dispatch _send({List<SeenState> states = const []}) => Dispatch(
  id: 's1',
  pathId: 'path-1',
  hostId: _host.id,
  hostName: _host.name,
  label: 'upgrade',
  directory: '~/src/upgrade',
  text: 'fix the gate',
  agent: 'claude',
  paneId: 'p1',
  herdrSession: 'main',
  sentAt: DateTime.utc(2026, 10, 1, 12),
  states: states,
);

AgentSnapshot _agent(String pane, String state) => AgentSnapshot(
  session: 'main',
  paneId: pane,
  agent: 'claude',
  state: AgentState.of(state),
  terminalTitleStripped: '',
  workspaceId: 'w',
  cwd: '~/src/upgrade',
  stateChangeSeq: 1,
);

void main() {
  group('a step', () {
    test('takes the verb its agent names it by, or its own name', () {
      expect(stepVerb('claude', 'Read'), 'READ');
      expect(stepVerb('claude', 'MultiEdit'), 'EDIT');
      expect(stepVerb('codex', 'exec_command'), 'RUN');
      expect(stepVerb('codex', 'Read'), 'READ');
      expect(stepVerb('claude', 'apply_patch'), 'APPLY_PATCH');
      expect(
        stepVerb('claude', 'mcp__linear__get_issue'),
        'MCP__LINEAR__GET_ISSUE',
      );
    });

    test('reads by the one argument a person reads it by', () {
      expect(stepArgument('Read', 'lib/main.dart'), 'lib/main.dart');
      expect(stepArgument('Bash', 'just check\n&& just test'), 'just check');
      expect(
        stepArgument('shell', '{"command":["bash","-lc","rg gate lib"]}'),
        'rg gate lib',
      );
      expect(stepArgument('exec_command', '{"cmd":"ls -la"}'), 'ls -la');
      expect(
        stepArgument(
          'apply_patch',
          '*** Begin Patch\n*** Update File: lib/gate.dart\n@@\n-a\n+b',
        ),
        'lib/gate.dart',
      );
    });
  });

  test('a prompt matches on its start, whitespace aside', () {
    expect(promptMatches('fix  the\ngate\n\nITEM\nx', 'fix the gate'), isTrue);
    expect(promptMatches('fix the gate', 'fix the door'), isFalse);
    expect(promptMatches('anything', '   '), isFalse);
    final long = 'a' * 400;
    expect(promptMatches('${'a' * 200} cut', long), isTrue);
  });

  test(
    'a run folds same verbs, groups later prompts and ends on its last word',
    () {
      final items = [
        _item(0, 'user', 'fix the gate'),
        _item(1, 'assistant', 'Looking.\nMore detail.'),
        _item(2, 'tool', 'a.dart', tool: 'Read', id: 't1'),
        _item(3, 'result', '', id: 't1'),
        _item(4, 'tool', 'b.dart', tool: 'Read', id: 't2'),
        _item(5, 'result', '', id: 't2'),
        _item(6, 'tool', 'just test', tool: 'Bash', id: 't3'),
        _item(7, 'user', 'now the docs'),
        _item(8, 'tool', 'docs/a.md', tool: 'Edit', id: 't4'),
        _item(9, 'assistant', 'Done, both.'),
      ];
      final lines = runLines(items, agent: 'claude', ended: true);
      expect(lines, hasLength(6));
      expect((lines[0] as SaidLine).first, 'Looking.');
      final reads = lines[1] as StepsLine;
      expect(
        (reads.verb, reads.steps.length, reads.glyph),
        ('READ', 2, StepGlyph.done),
      );
      expect((lines[2] as StepsLine).glyph, StepGlyph.running);
      expect((lines[3] as PromptLine).text, 'now the docs');
      expect((lines[4] as StepsLine).verb, 'EDIT');
      expect((lines[5] as LastSaidLine).text, 'Done, both.');

      final running = runLines(items, agent: 'claude', ended: false);
      expect(running.last, isA<SaidLine>());
    },
  );

  test('the open tool the session asks about carries the approval', () {
    final lines = runLines(
      [
        _item(0, 'user', 'fix'),
        _item(1, 'tool', 'rm -rf build', tool: 'Bash', id: 't1'),
      ],
      agent: 'claude',
      approval: const AgentApproval(id: 'a1', tool: 'Bash', summary: 'rm'),
      ended: false,
    );
    expect((lines.single as StepsLine).glyph, StepGlyph.waiting);
  });

  group('the pane state', () {
    AgentPanelState feed(List<AgentSnapshot> agents, {DateTime? at}) =>
        AgentPanelState([
          HostOutcome(
            host: _host,
            kind: AgentOutcomeKind.snapshot,
            agents: agents,
            lastGoodAt: at,
          ),
        ]);

    test('is the agent on the pane while the host shows it', () {
      expect(paneStateOf(feed([_agent('p1', 'working')]), _send()), 'working');
    });

    test('is ended once the host answers without a pane it showed', () {
      final seen = _send(
        states: [(state: 'working', at: DateTime.utc(2026, 10, 1, 12, 1))],
      );
      expect(paneStateOf(feed([_agent('p2', 'idle')]), seen), endedState);
    });

    test('is unknown before the pane has had time to come up', () {
      expect(
        paneStateOf(
          feed(const [], at: DateTime.utc(2026, 10, 1, 12, 0, 10)),
          _send(),
        ),
        isNull,
      );
      expect(paneStateOf(const AgentPanelState([]), _send()), isNull);
    });
  });
}
