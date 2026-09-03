import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotline/application/agents.dart';
import 'package:hotline/data/enums.dart';
import 'package:hotline/data/repositories/host_repository.dart';
import 'package:hotline/features/home/agents_panel.dart';
import 'package:hotline/platform/herdr_client.dart';
import 'package:hotline/platform/keys.dart';

const hostA = Host(
  id: 'a',
  name: 'A',
  address: '100.1.1.1',
  user: 'ops',
  keyId: 'key-a',
);
const hostB = Host(
  id: 'b',
  name: 'B',
  address: '100.1.1.2',
  user: 'ops',
  keyId: 'key-b',
);

AgentSnapshot agent({
  required String pane,
  required String name,
  required String status,
  required String work,
  required int sequence,
}) => AgentSnapshot(
  paneId: pane,
  agent: name,
  agentStatus: status,
  terminalTitleStripped: work,
  workspaceId: 'wQ',
  cwd: '/workspace/hotline',
  stateChangeSeq: sequence,
);

AgentPanelState snapshotOf(
  List<AgentSnapshot> agents, {
  DateTime? receivedAt,
  Host on = hostA,
}) => AgentPanelState([
  HostOutcome(
    host: on,
    kind: AgentOutcomeKind.snapshot,
    agents: agents,
    lastGoodAt: receivedAt,
  ),
]);

Widget host(AgentPanelState state, {DateTime? now}) => ProviderScope(
  child: MaterialApp(
    home: Scaffold(
      body: AgentsPanel(state: state, now: now),
    ),
  ),
);

void main() {
  test('no host keeps the polling provider idle', () async {
    var fetches = 0;
    final container = ProviderContainer(
      overrides: [
        homeAgentsVisibleProvider.overrideWith((ref) => true),
        herdrFetchProvider.overrideWithValue(({
          required String address,
          required String user,
          required String privateKey,
        }) async {
          fetches++;
          return const [];
        }),
      ],
    );
    addTearDown(container.dispose);

    await container.read(herdrHostsProvider.future);
    final state = await container.read(agentsFeedProvider.future);

    expect(state.noHost, isTrue);
    expect(fetches, 0);
  });

  test('the poll set is every host with HERDR on', () async {
    final hosts = InMemoryHostRepository();
    await hosts.save(hostA);
    await hosts.save(hostB);
    // §39.20's ruling: a registered host is not a herdr endpoint until the
    // integration says so, so B is invisible to the poller at the start.
    await hosts.setIntegration(hostA.id, IntegrationKind.herdr, true);
    final privateKeys = MemoryPrivateKeyStore();
    await privateKeys.write('key-a', 'private-a');
    await privateKeys.write('key-b', 'private-b');
    final addresses = <String>[];
    final states = <AgentPanelState>[];
    final container = ProviderContainer(
      overrides: [
        hostRepositoryProvider.overrideWithValue(hosts),
        privateKeyStoreProvider.overrideWithValue(privateKeys),
        homeAgentsVisibleProvider.overrideWith((ref) => true),
        herdrFetchProvider.overrideWithValue(({
          required String address,
          required String user,
          required String privateKey,
        }) async {
          addresses.add(address);
          if (address == hostB.address) throw const HerdrUnreachable();
          return [
            agent(
              pane: 'wQ:p1',
              name: 'codex',
              status: 'working',
              work: 'host A',
              sequence: 1,
            ),
          ];
        }),
      ],
    );
    addTearDown(container.dispose);
    await container.read(herdrHostsProvider.future);
    final subscription = container.listen(
      agentsFeedProvider,
      (_, next) => next.whenData(states.add),
      fireImmediately: true,
    );
    addTearDown(subscription.close);

    await _waitFor(() => addresses.contains(hostA.address));
    expect(addresses, isNot(contains(hostB.address)));

    await hosts.setIntegration(hostB.id, IntegrationKind.herdr, true);
    await _waitFor(() => addresses.contains(hostB.address));
    // One state carries both: B's failure does not take A's rows down with it.
    await _waitFor(
      () => states.any(
        (state) =>
            state.outcomes.length == 2 &&
            state.failures.length == 1 &&
            state.failures.single.kind == AgentOutcomeKind.unreachable &&
            state.agents.length == 1,
      ),
    );

    await hosts.setIntegration(hostA.id, IntegrationKind.herdr, false);
    await hosts.delete(hostB.id);
    await _waitFor(() => states.last.noHost);
    final fetches = addresses.length;
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(addresses, containsAllInOrder([hostA.address, hostB.address]));
    // Blocked means blocked: nothing is polled once the set empties.
    expect(addresses, hasLength(fetches));
  });

  testWidgets('shows working and blocked rows ordered by latest change', (
    tester,
  ) async {
    final state = snapshotOf([
      agent(
        pane: 'wQ:p1',
        name: 'claude',
        status: 'working',
        work: 'older work',
        sequence: 10,
      ),
      agent(
        pane: 'wQ:p2',
        name: 'codex',
        status: 'blocked',
        work: 'newer work',
        sequence: 20,
      ),
      agent(
        pane: 'wQ:p3',
        name: 'claude',
        status: 'idle',
        work: 'idle work',
        sequence: 30,
      ),
    ], receivedAt: DateTime(2026));
    await tester.pumpWidget(host(state));

    expect(find.text('AGENT'), findsOneWidget);
    expect(find.text('WORKING'), findsOneWidget);
    expect(find.text('BLOCKED'), findsOneWidget);
    expect(find.text('idle work'), findsNothing);
    expect(find.text('1 idle · 1 blocked'), findsOneWidget);
    final newer = tester.getTopLeft(find.text('newer work')).dy;
    final older = tester.getTopLeft(find.text('older work')).dy;
    expect(newer, lessThan(older));
  });

  testWidgets('rows merge across hosts', (tester) async {
    final state = AgentPanelState([
      snapshotOf([
        agent(
          pane: 'wQ:p1',
          name: 'claude',
          status: 'working',
          work: 'on A',
          sequence: 10,
        ),
      ]).outcomes.single,
      snapshotOf([
        agent(
          pane: 'wR:p1',
          name: 'claude',
          status: 'blocked',
          work: 'on B',
          sequence: 20,
        ),
      ], on: hostB).outcomes.single,
    ]);
    await tester.pumpWidget(host(state));

    // Same agent name on two machines is two agents; collapsing them by name
    // would hide half the work.
    expect(find.text('on A'), findsOneWidget);
    expect(find.text('on B'), findsOneWidget);
    expect(find.text('0 idle · 1 blocked'), findsOneWidget);
  });

  testWidgets('idle-only snapshot collapses to the footer', (tester) async {
    final state = snapshotOf([
      agent(
        pane: 'wQ:p1',
        name: 'claude',
        status: 'idle',
        work: 'waiting',
        sequence: 1,
      ),
    ], receivedAt: DateTime(2026));
    await tester.pumpWidget(host(state));

    expect(find.text('AGENT'), findsNothing);
    expect(find.text('waiting'), findsNothing);
    expect(find.text('1 idle · 0 blocked'), findsOneWidget);
  });

  testWidgets('unreachable state shows host and last snapshot age', (
    tester,
  ) async {
    final now = DateTime(2026, 9, 2, 12);
    final state = AgentPanelState([
      HostOutcome(
        host: const Host(
          id: 'nyx',
          name: 'Nyx',
          address: '100.118.60.77',
          user: 'luisnquin',
          keyId: 'k1',
        ),
        kind: AgentOutcomeKind.unreachable,
        lastGoodAt: now.subtract(const Duration(seconds: 12)),
      ),
    ]);
    await tester.pumpWidget(host(state, now: now));

    expect(find.text('nyx unreachable'), findsOneWidget);
    expect(find.text('12s ago'), findsOneWidget);
    expect(find.text('AGENT'), findsNothing);
    // Every host failed, so there is no footer to count: `0 idle` would read as
    // a healthy empty tmux rather than as nobody answering.
    expect(find.textContaining('idle ·'), findsNothing);
  });

  testWidgets('a failing host keeps the other hosts rendering', (tester) async {
    final now = DateTime(2026, 9, 2, 12);
    final state = AgentPanelState([
      HostOutcome(
        host: hostA,
        kind: AgentOutcomeKind.snapshot,
        agents: [
          agent(
            pane: 'wQ:p1',
            name: 'claude',
            status: 'working',
            work: 'still here',
            sequence: 1,
          ),
        ],
        lastGoodAt: now,
      ),
      const HostOutcome(host: hostB, kind: AgentOutcomeKind.keyRejected),
    ]);
    await tester.pumpWidget(host(state, now: now));

    expect(find.text('key rejected'), findsOneWidget);
    expect(find.text('still here'), findsOneWidget);
    expect(find.text('0 idle · 0 blocked'), findsOneWidget);
  });

  testWidgets('two failing hosts each say which host they are', (tester) async {
    const state = AgentPanelState([
      HostOutcome(host: hostA, kind: AgentOutcomeKind.keyRejected),
      HostOutcome(
        host: hostB,
        kind: AgentOutcomeKind.protocolMismatch,
        protocol: 9,
      ),
    ]);
    await tester.pumpWidget(host(state));

    // §39.20 words only the unreachable line with its host; with two failures
    // the bare lines would not say which machine, so the name goes back.
    expect(find.text('a · key rejected'), findsOneWidget);
    expect(find.text('b · protocol 9'), findsOneWidget);
  });

  testWidgets('no host is a blocked panel state without rows or footer', (
    tester,
  ) async {
    await tester.pumpWidget(host(const AgentPanelState.noHost()));

    expect(find.text('NO HOST · SET IN SYS'), findsOneWidget);
    expect(find.text('AGENT'), findsNothing);
    expect(find.textContaining('idle'), findsNothing);
    expect(find.textContaining('blocked'), findsNothing);
    expect(find.text('0'), findsNothing);
    expect(find.text('VIEW ALL'), findsNothing);
  });
}

Future<void> _waitFor(bool Function() condition) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(condition(), isTrue);
}
