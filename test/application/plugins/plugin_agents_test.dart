import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:striked/application/agents/agent_state.dart';
import 'package:striked/application/agents/agents.dart';
import 'package:striked/application/plugins/plugin_hosts.dart';
import 'package:striked/data/repositories/host_repository.dart';
import 'package:striked/platform/herdr/herdr_client.dart';
import 'package:striked/platform/plugins/manifest.dart';
import 'package:striked/platform/plugins/store.dart';

import '../../plugins/kanban_plugin_test.dart' show kanbanPackage;

const _nyx = Host(
  id: 'h1',
  name: 'nyx',
  address: 'localhost',
  port: 2222,
  user: 'dev',
  keyId: 'test',
);
const _rose = Host(
  id: 'h2',
  name: 'rose',
  address: 'rose',
  port: 2222,
  user: 'dev',
  keyId: 'test',
);

const _blocked = AgentSnapshot(
  session: 'development',
  paneId: 'p1',
  agent: 'claude',
  state: BlockedState(),
  terminalTitleStripped: 'deploy',
  workspaceId: 'w1',
  workspaceLabel: 'striked',
  cwd: '/home/dev/striked',
  stateChangeSeq: 7,
  source: AgentSource.engine,
  approval: AgentApproval(id: 'ap1', tool: 'bash', summary: 'rm -rf build'),
);

final _panel = AgentPanelState([
  HostOutcome(
    host: _nyx,
    kind: AgentOutcomeKind.snapshot,
    agents: const [_blocked],
    lastGoodAt: DateTime.utc(2026, 10, 20, 12),
    source: AgentSource.engine,
  ),
  const HostOutcome(host: _rose, kind: AgentOutcomeKind.unreachable),
]);

void main() {
  late ProviderContainer container;
  late PluginHostRegistry registry;
  late InstalledPlugin plugin;
  setUp(() async {
    container = ProviderContainer(
      overrides: [
        agentsFeedProvider.overrideWith((ref) => Stream.value(_panel)),
      ],
    );
    await container.read(agentsFeedProvider.future);
    registry = container.read(pluginHostRegistryProvider);
    final package = kanbanPackage();
    plugin = InstalledPlugin(package, package.manifest.permissions);
  });
  tearDown(() => container.dispose());

  Future<Object?> invoke(
    String operation,
    Map<String, Object?> args, [
    PluginHostGesture? gesture,
  ]) => registry.invoke(
    plugin,
    {'capability': 'agents', 'operation': operation, 'args': args},
    (_, _, _) async => true,
    () {},
    gesture: gesture,
  );

  test('list hands over the panel in plain values', () {
    final listed = pluginAgentList(_panel, DateTime.utc(2026, 10, 20, 12, 1));
    expect(listed['ready'], isTrue);
    expect(listed['hosts'], [
      {
        'id': 'h1',
        'name': 'nyx',
        'ok': true,
        'read_at': '2026-10-20T12:00:00.000Z',
        'read_ago': 60,
      },
      {'id': 'h2', 'name': 'rose', 'ok': false, 'reason': isA<String>()},
    ]);
    expect(listed['items'], [
      {
        'id': 'h1/engine/development/p1',
        'host': 'h1',
        'host_name': 'nyx',
        'agent': 'claude',
        'state': 'blocked',
        'title': 'deploy',
        'workspace': 'striked',
        'directory': '/home/dev/striked',
        'question': '',
        'message': '',
        'source': 'engine',
        'seq': 7,
        'approval': {
          'id': 'ap1',
          'tool': 'bash',
          'line': 'bash · rm -rf build',
        },
      },
    ]);
    expect(pluginAgentList(null, DateTime.now())['ready'], isFalse);
  });

  test('answer and open need a tap, and a tap is spent once', () async {
    expect(await invoke('list', {}), containsPair('ready', true));
    await expectLater(
      invoke('answer', {'approval': 'ap1', 'allow': true}),
      throwsA(isA<PluginException>()),
    );
    await expectLater(
      invoke('open', {'id': 'h1/engine/development/p1'}),
      throwsA(isA<PluginException>()),
    );
    final opened = <String>[];
    final gesture = PluginHostGesture(
      (host, agent) => opened.add('${host.name}/${agent.paneId}'),
    );
    expect(await invoke('open', {'id': 'h1/engine/development/p1'}, gesture), {
      'opened': true,
    });
    expect(opened, ['nyx/p1']);
    await expectLater(
      invoke('open', {'id': 'h1/engine/development/p1'}, gesture),
      throwsA(isA<PluginException>()),
    );
    await expectLater(
      invoke('answer', {
        'approval': 'gone',
        'allow': true,
      }, PluginHostGesture((_, _) {})),
      throwsA(
        isA<PluginException>().having(
          (error) => error.message,
          'message',
          'This approval is no longer pending',
        ),
      ),
    );
    expect(opened, ['nyx/p1']);
  });

  test('a plugin on screen holds the feed live until it lets go', () {
    final service = registry.services['agents']!;
    expect(container.read(pluginAgentsHeldProvider), 0);
    final release = service.hold!();
    expect(container.read(pluginAgentsHeldProvider), 1);
    release();
    expect(container.read(pluginAgentsHeldProvider), 0);
  });
}
