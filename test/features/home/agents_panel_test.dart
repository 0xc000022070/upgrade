import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import 'dart:async';

import 'package:vector_graphics/vector_graphics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/application/agents/agent_kind.dart';
import 'package:upgrade/application/agents/agent_state.dart';
import 'package:upgrade/application/agents/agents.dart';
import 'package:upgrade/application/agents/send.dart';
import 'package:upgrade/application/agents/send_queue.dart';
import 'package:upgrade/application/alerts/toasts.dart';
import 'package:upgrade/application/navigation.dart';
import 'package:upgrade/data/enums.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/data/repositories/path_repository.dart';
import 'package:upgrade/design/components/dot_spinner.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/features/home/agent_mark.dart';
import 'package:upgrade/features/home/agents_panel.dart';
import 'package:upgrade/features/hosts/hosts_screen.dart';
import 'package:upgrade/platform/herdr/herdr_client.dart';
import 'package:upgrade/platform/ssh/keys.dart';
import 'package:upgrade/platform/ssh/host_keys.dart';
import 'package:upgrade/application/providers.dart';

import '../../support/fake_shell.dart';
import '../../support/reasons.dart';
import '../../support/themed_app.dart';

const hostA = Host(
  id: 'a',
  name: 'A',
  address: '100.1.1.1',
  port: 22,
  user: 'ops',
  keyId: 'key-a',
);
const hostB = Host(
  id: 'b',
  name: 'B',
  address: '100.1.1.2',
  port: 357,
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
  session: 'default',
  paneId: pane,
  agent: name,
  state: AgentState.of(status),
  terminalTitleStripped: work,
  workspaceId: 'wQ',
  cwd: '/workspace/upgrade',
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
  retry: noRetry,
  child: MaterialApp(
    theme: testTheme,
    home: Scaffold(
      body: AgentsPanel(state: state, now: now),
    ),
  ),
);

void main() {
  testWidgets('a send still going is a row ahead of the agents', (
    tester,
  ) async {
    final container = ProviderContainer(retry: noRetry);
    addTearDown(container.dispose);
    final answer = Completer<SendState>();
    container
        .read(sendQueueProvider.notifier)
        .start(
          itemId: 'item-1',
          title: 'a drop on its way',
          target: PathTarget(
            path: AgentPath(
              id: 'path-1',
              hostId: 'a',
              directory: '~/src/upgrade',
              label: 'upgrade',
              createdAt: DateTime.utc(2026, 9, 3),
            ),
            host: hostA,
          ),
          kind: AgentKind.all.last,
          run: (_) => answer.future,
        );
    final state = snapshotOf([
      agent(
        pane: 'wQ:p1',
        name: 'claude',
        status: 'working',
        work: 'other work',
        sequence: 10,
      ),
    ]);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: testTheme,
          home: Scaffold(body: AgentsPanel(state: state)),
        ),
      ),
    );

    expect(find.text('STARTING'), findsOneWidget);
    expect(find.text('CODEX'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('a drop on its way')).dy,
      lessThan(tester.getTopLeft(find.text('other work')).dy),
    );

    answer.complete(const SendFailed('spawn timed out'));
    await tester.pump();
    final failed = tester.widget<Text>(find.text('FAILED'));
    expect(failed.style?.color, UpgradeTokens.house.danger);
    expect(find.text('STARTING'), findsNothing);
    await tester.pump(toastHold);
  });

  testWidgets('a row hands its tap the host and the agent', (tester) async {
    final opened = <(Host, AgentSnapshot)>[];
    final claude = agent(
      pane: 'w22:p1',
      name: 'claude',
      status: 'working',
      work: 'refactor',
      sequence: 4,
    );
    final state = AgentPanelState([
      HostOutcome(
        host: hostA,
        kind: AgentOutcomeKind.snapshot,
        agents: [
          agent(
            pane: 'w9:p1',
            name: 'codex',
            status: 'idle',
            work: 'done',
            sequence: 9,
          ),
        ],
      ),
      HostOutcome(
        host: hostB,
        kind: AgentOutcomeKind.snapshot,
        agents: [claude],
      ),
    ]);
    await tester.pumpWidget(
      ProviderScope(
        retry: noRetry,
        child: MaterialApp(
          theme: testTheme,
          home: Scaffold(
            body: AgentsPanel(
              state: state,
              onOpen: (_, host, agent) => opened.add((host, agent)),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('CLAUDE'));

    expect(opened, [(hostB, claude)]);
  });

  test('no host keeps the polling provider idle', () async {
    var fetches = 0;
    final container = ProviderContainer(
      retry: noRetry,
      overrides: [
        homeAgentsVisibleProvider.overrideWith((ref) => true),
        herdrFetchProvider.overrideWithValue(({
          required String address,
          required int port,
          required String user,
          required String privateKey,
          HostKeyVerifier? verifier,
        }) async {
          fetches++;
          return const [];
        }),
      ],
    );
    addTearDown(container.dispose);

    await container.listen(agentChannelsProvider.future, (_, _) {}).read();
    final state = await container
        .listen(agentsFeedProvider.future, (_, _) {})
        .read();

    expect(state.noHost, isTrue);
    expect(fetches, 0);
  });

  test(
    'the poll dials with a verifier that refuses an unpinned host',
    () async {
      final hosts = InMemoryHostRepository();
      await hosts.save(hostA);
      await hosts.setIntegration(hostA.id, IntegrationKind.herdr, true);
      final privateKeys = MemoryPrivateKeyStore();
      await privateKeys.write('key-a', 'private-a');
      final verifiers = <HostKeyVerifier?>[];
      final container = ProviderContainer(
        retry: noRetry,
        overrides: [
          hostRepositoryProvider.overrideWithValue(hosts),
          privateKeyStoreProvider.overrideWithValue(privateKeys),
          homeAgentsVisibleProvider.overrideWith((ref) => true),
          herdrFetchProvider.overrideWithValue(({
            required String address,
            required int port,
            required String user,
            required String privateKey,
            HostKeyVerifier? verifier,
          }) async {
            verifiers.add(verifier);
            return const <AgentSnapshot>[];
          }),
        ],
      );
      addTearDown(container.dispose);
      await container.listen(agentChannelsProvider.future, (_, _) {}).read();
      final subscription = container.listen(agentsFeedProvider, (_, _) {});
      addTearDown(subscription.close);

      await _waitFor(() => verifiers.isNotEmpty);
      final verifier = verifiers.first!;

      expect(verifier.prompt, isNull);
      expect(
        await verifier.verifyFingerprint('ssh-ed25519', 'SHA256:whatever'),
        isFalse,
      );
      expect(verifier.refusal, HostKeyRefusal.unverified);
    },
  );

  testWidgets('the poll set is every host with HERDR on', (tester) async {
    final hosts = InMemoryHostRepository();
    await hosts.save(hostA);
    await hosts.save(hostB);
    await hosts.setIntegration(hostA.id, IntegrationKind.herdr, true);
    final privateKeys = MemoryPrivateKeyStore();
    await privateKeys.write('key-a', 'private-a');
    await privateKeys.write('key-b', 'private-b');
    final addresses = <String>[];
    String dialled(Host host) => '${host.address}:${host.port}';
    final states = <AgentPanelState>[];
    final container = ProviderContainer(
      retry: noRetry,
      overrides: [
        hostRepositoryProvider.overrideWithValue(hosts),
        privateKeyStoreProvider.overrideWithValue(privateKeys),
        homeAgentsVisibleProvider.overrideWith((ref) => true),
        herdrFetchProvider.overrideWithValue(({
          required String address,
          required int port,
          required String user,
          required String privateKey,
          HostKeyVerifier? verifier,
        }) async {
          addresses.add('$address:$port');
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
    await container.listen(agentChannelsProvider.future, (_, _) {}).read();
    final subscription = container.listen(
      agentsFeedProvider,
      (_, next) => next.whenData(states.add),
      fireImmediately: true,
    );
    addTearDown(subscription.close);

    await _pumpFor(tester, () => addresses.contains(dialled(hostA)));
    expect(addresses, isNot(contains(dialled(hostB))));

    await hosts.setIntegration(hostB.id, IntegrationKind.herdr, true);
    await _pumpFor(tester, () => addresses.contains(dialled(hostB)));
    await _pumpFor(
      tester,
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
    await _pumpFor(tester, () => states.last.noHost);
    final fetches = addresses.length;
    await tester.pump(const Duration(seconds: 11));

    expect(addresses, containsAllInOrder([dialled(hostA), dialled(hostB)]));
    expect(addresses, hasLength(fetches));
  });

  testWidgets('a feed that has stopped goes on handing out its last state', (
    tester,
  ) async {
    final hosts = InMemoryHostRepository();
    await hosts.save(hostA);
    await hosts.setIntegration(hostA.id, IntegrationKind.herdr, true);
    final privateKeys = MemoryPrivateKeyStore();
    await privateKeys.write('key-a', 'private-a');
    var fetches = 0;
    final container = ProviderContainer(
      retry: noRetry,
      overrides: [
        hostRepositoryProvider.overrideWithValue(hosts),
        privateKeyStoreProvider.overrideWithValue(privateKeys),
        herdrFetchProvider.overrideWithValue(({
          required String address,
          required int port,
          required String user,
          required String privateKey,
          HostKeyVerifier? verifier,
        }) async {
          fetches++;
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
    container.read(homeAgentsVisibleProvider.notifier).state = true;
    await container.listen(agentChannelsProvider.future, (_, _) {}).read();
    final subscription = container.listen(agentsFeedProvider, (_, _) {});
    addTearDown(subscription.close);
    await tester.pump();
    expect(container.read(agentsFeedProvider).value?.agents, isNotEmpty);
    expect(container.read(agentsFeedLiveProvider), isTrue);

    container.read(homeAgentsVisibleProvider.notifier).state = false;
    final dialled = fetches;
    await tester.pump(const Duration(seconds: 11));

    expect(fetches, dialled);
    expect(container.read(agentsFeedProvider).value?.agents, hasLength(1));
    expect(container.read(agentsFeedLiveProvider), isFalse);
  });

  testWidgets('a host that hangs does not hold back the one that answered', (
    tester,
  ) async {
    final hosts = InMemoryHostRepository();
    await hosts.save(hostA);
    await hosts.save(hostB);
    await hosts.setIntegration(hostA.id, IntegrationKind.herdr, true);
    await hosts.setIntegration(hostB.id, IntegrationKind.herdr, true);
    final privateKeys = MemoryPrivateKeyStore();
    await privateKeys.write('key-a', 'private-a');
    await privateKeys.write('key-b', 'private-b');
    final states = <AgentPanelState>[];
    final container = ProviderContainer(
      retry: noRetry,
      overrides: [
        hostRepositoryProvider.overrideWithValue(hosts),
        privateKeyStoreProvider.overrideWithValue(privateKeys),
        homeAgentsVisibleProvider.overrideWith((ref) => true),
        herdrFetchProvider.overrideWithValue(({
          required String address,
          required int port,
          required String user,
          required String privateKey,
          HostKeyVerifier? verifier,
        }) async {
          if (address == hostB.address) {
            await Future<void>.delayed(const Duration(seconds: 10));
            throw const HerdrUnreachable('no answer in 10s');
          }
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
    await container.listen(agentChannelsProvider.future, (_, _) {}).read();
    final subscription = container.listen(
      agentsFeedProvider,
      (_, next) => next.whenData(states.add),
      fireImmediately: true,
    );

    var waited = Duration.zero;
    await tester.pump();
    while (states.isEmpty && waited < const Duration(seconds: 30)) {
      await tester.pump(const Duration(seconds: 1));
      waited += const Duration(seconds: 1);
    }

    expect(waited, Duration.zero);
    expect(states.single.outcomes.map((outcome) => outcome.host.id), ['a']);
    expect(states.single.agents, hasLength(1));

    await tester.pump(const Duration(seconds: 10));
    final both = states.last;
    expect(both.outcomes.map((outcome) => outcome.host.id), ['a', 'b']);
    expect(both.failures.single.kind, AgentOutcomeKind.unreachable);
    expect(both.agents, hasLength(1));

    subscription.close();
    container.dispose();
    await tester.pump(const Duration(seconds: 30));
  });

  testWidgets(
    'a host that does not answer is dialled further and further apart',
    (tester) async {
      final poll = await _pollFailing(
        tester,
        const HerdrUnreachable('connection refused'),
      );

      var elapsed = 0;
      for (final (index, at) in [10, 30, 70, 130, 190].indexed) {
        await tester.pump(Duration(seconds: at - 1 - elapsed));
        expect(poll.dials(), index + 1, reason: 'dials before ${at}s');
        await tester.pump(const Duration(seconds: 1));
        expect(poll.dials(), index + 2, reason: 'dials at ${at}s');
        elapsed = at;
      }
      await poll.stop();
    },
  );

  testWidgets('a host that answers without herdr keeps the ten second beat', (
    tester,
  ) async {
    final poll = await _pollFailing(tester, const HerdrMissing('no herdr'));

    await tester.pump(const Duration(seconds: 60));
    expect(poll.dials(), 7);
    await poll.stop();
  });

  for (final refusal in const <HerdrFailure>[
    HerdrHostKeyChanged('offered another key'),
    HerdrKeyRejected('publickey'),
  ]) {
    testWidgets(
      '${refusal.runtimeType} is not dialled again until the app wakes',
      (tester) async {
        final poll = await _pollFailing(tester, refusal);

        await tester.pump(const Duration(minutes: 5));
        expect(poll.dials(), 1);

        poll.container.read(agentsWakeProvider.notifier).state++;
        await tester.pump(const Duration(seconds: 1));
        expect(poll.dials(), 2);

        await tester.pump(const Duration(minutes: 5));
        expect(poll.dials(), 2);
        await poll.stop();
      },
    );
  }

  test('a name that never resolved is its own outcome', () async {
    final hosts = InMemoryHostRepository();
    await hosts.save(hostA);
    await hosts.setIntegration(hostA.id, IntegrationKind.herdr, true);
    final privateKeys = MemoryPrivateKeyStore();
    await privateKeys.write('key-a', 'private-a');
    final states = <AgentPanelState>[];
    final container = ProviderContainer(
      retry: noRetry,
      overrides: [
        hostRepositoryProvider.overrideWithValue(hosts),
        privateKeyStoreProvider.overrideWithValue(privateKeys),
        homeAgentsVisibleProvider.overrideWith((ref) => true),
        herdrFetchProvider.overrideWithValue(({
          required String address,
          required int port,
          required String user,
          required String privateKey,
          HostKeyVerifier? verifier,
        }) async {
          throw const HerdrUnresolved("Failed host lookup: 'nope.invalid'");
        }),
      ],
    );
    addTearDown(container.dispose);
    await container.listen(agentChannelsProvider.future, (_, _) {}).read();
    final subscription = container.listen(
      agentsFeedProvider,
      (_, next) => next.whenData(states.add),
      fireImmediately: true,
    );
    addTearDown(subscription.close);

    await _waitFor(
      () => states.any(
        (state) =>
            state.failures.length == 1 &&
            state.failures.single.kind == AgentOutcomeKind.unresolved,
      ),
    );
  });

  testWidgets('an unresolved host says so by name', (tester) async {
    final now = DateTime(2026, 9, 3, 12);
    final state = AgentPanelState([
      HostOutcome(
        host: const Host(
          id: 'oak',
          name: 'Oak',
          address: 'nope.invalid',
          port: 357,
          user: 'luisnquin',
          keyId: 'k1',
        ),
        kind: AgentOutcomeKind.unresolved,
        lastGoodAt: now.subtract(const Duration(seconds: 12)),
      ),
    ]);
    await tester.pumpWidget(host(state, now: now));

    expect(find.text('oak unresolved'), findsOneWidget);
    expect(find.text('oak unreachable'), findsNothing);
    expect(find.text('12s ago'), findsOneWidget);
  });

  testWidgets('two failing hosts do not say the unresolved host twice', (
    tester,
  ) async {
    const state = AgentPanelState([
      HostOutcome(host: hostA, kind: AgentOutcomeKind.unresolved),
      HostOutcome(host: hostB, kind: AgentOutcomeKind.keyRejected),
    ]);
    await tester.pumpWidget(host(state));

    expect(find.text('a unresolved'), findsOneWidget);
    expect(find.text('b · key rejected'), findsOneWidget);
  });

  testWidgets('a host down on herdr and the engine is said once', (
    tester,
  ) async {
    final now = DateTime(2026, 9, 30, 20, 19);
    final state = AgentPanelState([
      HostOutcome(
        host: hostA,
        kind: AgentOutcomeKind.unreachable,
        lastGoodAt: now.subtract(const Duration(minutes: 1)),
      ),
      HostOutcome(
        host: hostA,
        kind: AgentOutcomeKind.unreachable,
        source: AgentSource.engine,
        lastGoodAt: now.subtract(const Duration(seconds: 50)),
      ),
    ]);
    await tester.pumpWidget(host(state, now: now));

    expect(state.failures, hasLength(1));
    expect(find.text('a unreachable'), findsOneWidget);
    expect(find.text('50s ago'), findsOneWidget);
    expect(find.textContaining('idle ·'), findsNothing);
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

    expect(find.text('AGENT'), findsNothing);
    expect(
      tester.getTopLeft(find.text('newer work')).dy,
      lessThan(tester.getTopLeft(find.text('CODEX')).dy),
    );
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

  testWidgets('an agent that finished unseen work is counted, not lost', (
    tester,
  ) async {
    final state = snapshotOf([
      agent(
        pane: 'wQ:p1',
        name: 'claude',
        status: 'done',
        work: 'finished',
        sequence: 1,
      ),
      agent(
        pane: 'wQ:p2',
        name: 'codex',
        status: 'idle',
        work: 'waiting',
        sequence: 2,
      ),
    ], receivedAt: DateTime(2026));
    await tester.pumpWidget(host(state));

    expect(find.text('2 idle · 0 blocked'), findsOneWidget);
    expect(find.text('finished'), findsNothing);
  });

  testWidgets('a word the app cannot place is still one of the agents', (
    tester,
  ) async {
    final state = snapshotOf([
      agent(
        pane: 'wQ:p1',
        name: 'claude',
        status: 'compacting',
        work: 'somewhere',
        sequence: 1,
      ),
    ], receivedAt: DateTime(2026));
    await tester.pumpWidget(host(state));

    expect(find.text('0 idle · 0 blocked'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
  });

  testWidgets('unreachable state shows host and last snapshot age', (
    tester,
  ) async {
    final now = DateTime(2026, 9, 2, 12);
    final state = AgentPanelState([
      HostOutcome(
        host: const Host(
          id: 'oak',
          name: 'Oak',
          address: '198.51.100.77',
          port: 22,
          user: 'luisnquin',
          keyId: 'k1',
        ),
        kind: AgentOutcomeKind.unreachable,
        lastGoodAt: now.subtract(const Duration(seconds: 12)),
      ),
    ]);
    await tester.pumpWidget(host(state, now: now));

    expect(find.text('oak unreachable'), findsOneWidget);
    expect(find.text('12s ago'), findsOneWidget);
    expect(find.text('AGENT'), findsNothing);
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

    expect(find.text('a · key rejected'), findsOneWidget);
    expect(find.text('b · protocol 9'), findsOneWidget);
  });

  testWidgets('a tab whose program reports itself is a row with no host on', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.runAsync(() async {
      sessions.open(intent: testIntent(), hostA);
      await Future<void>.delayed(Duration.zero);
      transport.opened.single
        ..emit(
          '\x1b]7501;state=blocked:kind=permission:app=claude-code'
          ':msg=QWxsb3cgcm0/\x07',
        )
        ..emit('\x1b]7501;state=done:id=old:app=cargo\x07');
      await Future<void>.delayed(Duration.zero);
    });

    await tester.pumpWidget(
      ProviderScope(
        retry: noRetry,
        child: MaterialApp(
          theme: testTheme,
          home: Scaffold(
            body: AgentsPanel(
              state: const AgentPanelState.noHost(),
              programs: sessions.programs,
            ),
          ),
        ),
      ),
    );

    expect(find.text('TURN AGENTS ON IN A HOST'), findsNothing);
    expect(find.text('Allow rm?'), findsOneWidget);
    expect(find.text('CLAUDE · A 1'), findsOneWidget);
    expect(find.text('BLOCKED'), findsOneWidget);
    expect(markAsset(tester), AgentKind.of('claude').markAsset);
    expect(find.textContaining('idle', findRichText: true), findsNothing);
    expect(find.text('VIEW ALL'), findsNothing);
  });

  testWidgets('a program the app has no mark for is named, not marked', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.runAsync(() async {
      sessions.open(intent: testIntent(), hostA);
      await Future<void>.delayed(Duration.zero);
      transport.opened.single.emit(
        '\x1b]7501;state=working:app=cargo:title=YnVpbGQ=\x07',
      );
      await Future<void>.delayed(Duration.zero);
    });

    await tester.pumpWidget(
      ProviderScope(
        retry: noRetry,
        child: MaterialApp(
          theme: testTheme,
          home: Scaffold(
            body: AgentsPanel(
              state: const AgentPanelState.noHost(),
              programs: sessions.programs,
            ),
          ),
        ),
      ),
    );

    expect(find.text('build'), findsOneWidget);
    expect(find.text('CARGO · A 1'), findsOneWidget);
    expect(find.byType(AgentMark), findsNothing);
  });

  testWidgets('a finished record alone leaves the way to a host', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.runAsync(() async {
      sessions.open(intent: testIntent(), hostA);
      await Future<void>.delayed(Duration.zero);
      transport.opened.single.emit('\x1b]7501;state=done:app=cargo\x07');
      await Future<void>.delayed(Duration.zero);
    });

    await tester.pumpWidget(
      ProviderScope(
        retry: noRetry,
        child: MaterialApp(
          theme: testTheme,
          home: Scaffold(
            body: AgentsPanel(
              state: const AgentPanelState.noHost(),
              programs: sessions.programs,
            ),
          ),
        ),
      ),
    );

    expect(find.text('TURN AGENTS ON IN A HOST'), findsOneWidget);
  });

  testWidgets('no host points to the host that must enable herdr', (
    tester,
  ) async {
    await tester.pumpWidget(host(const AgentPanelState.noHost()));

    final action = find.text('TURN AGENTS ON IN A HOST');
    final container = ProviderScope.containerOf(
      tester.element(find.byType(AgentsPanel)),
    );

    expect(action, findsOneWidget);
    expect(find.text('AGENT'), findsNothing);
    expect(find.textContaining('idle'), findsNothing);
    expect(find.textContaining('blocked'), findsNothing);
    expect(find.text('0'), findsNothing);
    expect(find.text('VIEW ALL'), findsNothing);

    await tester.tap(action);
    await tester.pump();

    expect(container.read(navIndexProvider), HostsScreen.navIndex);
  });

  testWidgets('a claude row renders the claude mark and no C', (tester) async {
    await tester.pumpWidget(
      host(
        snapshotOf([
          agent(
            pane: 'wQ:p1',
            name: 'claude',
            status: 'working',
            work: 'wire agents panel',
            sequence: 10,
          ),
        ], receivedAt: DateTime(2026)),
      ),
    );

    expect(markAsset(tester), 'assets/icons/agent-claude.svg');
    expect(find.text('C'), findsNothing);
    expect(find.text('?'), findsNothing);
    expect(find.text('CLAUDE'), findsOneWidget);
  });

  testWidgets('a codex row renders the codex mark and no X', (tester) async {
    await tester.pumpWidget(
      host(
        snapshotOf([
          agent(
            pane: 'wQ:p2',
            name: 'codex',
            status: 'blocked',
            work: 'wire alerts',
            sequence: 10,
          ),
        ], receivedAt: DateTime(2026)),
      ),
    );

    expect(markAsset(tester), 'assets/icons/agent-codex.svg');
    expect(find.text('X'), findsNothing);
    expect(find.text('CODEX'), findsOneWidget);
  });

  testWidgets('a kind with no mark file keeps its own letter', (tester) async {
    await tester.pumpWidget(
      host(
        snapshotOf([
          agent(
            pane: 'wQ:p3',
            name: 'gizmo',
            status: 'working',
            work: 'something',
            sequence: 10,
          ),
        ], receivedAt: DateTime(2026)),
      ),
    );

    expect(
      find.descendant(
        of: find.byType(AgentMark),
        matching: find.byType(VectorGraphic),
      ),
      findsNothing,
    );
    expect(find.text('G'), findsOneWidget);
    expect(find.text('?'), findsNothing);
    expect(find.text('GIZMO'), findsOneWidget);
  });

  testWidgets('an empty kind is ? in the box and ? as the name', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        snapshotOf([
          agent(
            pane: 'wQ:p4',
            name: '',
            status: 'working',
            work: 'something',
            sequence: 10,
          ),
        ], receivedAt: DateTime(2026)),
      ),
    );

    expect(find.text('?'), findsNWidgets(2));
    expect(
      find.descendant(of: find.byType(AgentMark), matching: find.text('?')),
      findsOneWidget,
    );
  });

  testWidgets('a feed reload keeps the last rows on screen', (tester) async {
    // A rebuilt StreamProvider sits in loading until its first event lands.
    final reloads = StateProvider((ref) => 0);
    final feed = StreamController<AgentPanelState>.broadcast();
    addTearDown(feed.close);
    final container = ProviderContainer(
      retry: noRetry,
      overrides: [
        agentsFeedProvider.overrideWith((ref) {
          ref.watch(reloads);
          return feed.stream;
        }),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: testTheme,
          home: Scaffold(body: AgentsPanel()),
        ),
      ),
    );
    feed.add(
      snapshotOf([
        agent(
          pane: 'wQ:p1',
          name: 'claude',
          status: 'working',
          work: 'live work',
          sequence: 10,
        ),
      ], receivedAt: DateTime(2026)),
    );
    await tester.pump();
    expect(find.text('live work'), findsOneWidget);

    // The broadcast stream replays nothing, so the rebuilt provider stays in loading.
    container.read(reloads.notifier).state++;
    await tester.pump();

    expect(find.text('live work'), findsOneWidget);
    expect(find.text('0 idle · 0 blocked'), findsOneWidget);
    expect(find.byType(DelayedSpinner), findsNothing);
  });
}

Future<
  ({
    int Function() dials,
    ProviderContainer container,
    Future<void> Function() stop,
  })
>
_pollFailing(WidgetTester tester, HerdrFailure failure) async {
  final hosts = InMemoryHostRepository();
  await hosts.save(hostA);
  await hosts.setIntegration(hostA.id, IntegrationKind.herdr, true);
  final privateKeys = MemoryPrivateKeyStore();
  await privateKeys.write('key-a', 'private-a');
  var dials = 0;
  final container = ProviderContainer(
    retry: noRetry,
    overrides: [
      hostRepositoryProvider.overrideWithValue(hosts),
      privateKeyStoreProvider.overrideWithValue(privateKeys),
      homeAgentsVisibleProvider.overrideWith((ref) => true),
      herdrFetchProvider.overrideWithValue(({
        required String address,
        required int port,
        required String user,
        required String privateKey,
        HostKeyVerifier? verifier,
      }) async {
        dials++;
        throw failure;
      }),
    ],
  );
  await container.listen(agentChannelsProvider.future, (_, _) {}).read();
  final subscription = container.listen(agentsFeedProvider, (_, _) {});
  await tester.pump();
  expect(dials, 1);
  return (
    dials: () => dials,
    container: container,
    stop: () async {
      subscription.close();
      container.dispose();
      await tester.pump(const Duration(minutes: 1));
    },
  );
}

Future<void> _pumpFor(WidgetTester tester, bool Function() condition) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await tester.pump(const Duration(milliseconds: 5));
  }
  expect(condition(), isTrue);
}

Future<void> _waitFor(bool Function() condition) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(condition(), isTrue);
}

String? markAsset(WidgetTester tester) {
  final marks = find.descendant(
    of: find.byType(AgentMark),
    matching: find.byType(VectorGraphic),
  );
  if (marks.evaluate().isEmpty) return null;
  final loader = tester.widget<VectorGraphic>(marks).loader;
  return loader is AssetBytesLoader ? loader.assetName : null;
}
