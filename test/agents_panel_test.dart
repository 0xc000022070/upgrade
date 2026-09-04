import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'dart:io';

import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotline/application/agents.dart';
import 'package:hotline/data/enums.dart';
import 'package:hotline/data/repositories/host_repository.dart';
import 'package:hotline/features/home/agent_mark.dart';
import 'package:hotline/features/home/agents_panel.dart';
import 'package:hotline/platform/herdr_client.dart';
import 'package:hotline/platform/keys.dart';
import 'package:hotline/platform/host_keys.dart';

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

    await container.read(herdrHostsProvider.future);
    final state = await container.read(agentsFeedProvider.future);

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
      await container.read(herdrHostsProvider.future);
      final subscription = container.listen(agentsFeedProvider, (_, _) {});
      addTearDown(subscription.close);

      await _waitFor(() => verifiers.isNotEmpty);
      final verifier = verifiers.first!;

      // A poll happens with the phone in a pocket. There is nobody to put a
      // fingerprint in front of, so the host is not trusted for the first time
      // here — it is left for a route where the user can look at it.
      expect(verifier.prompt, isNull);
      expect(
        await verifier.verifyFingerprint('ssh-ed25519', 'SHA256:whatever'),
        isFalse,
      );
      expect(verifier.refusal, HostKeyRefusal.unverified);
    },
  );

  test('the poll set is every host with HERDR on', () async {
    final hosts = InMemoryHostRepository();
    await hosts.save(hostA);
    await hosts.save(hostB);
    // A registered host is not a herdr endpoint until the integration says
    // so, so B is invisible to the poller at the start.
    await hosts.setIntegration(hostA.id, IntegrationKind.herdr, true);
    final privateKeys = MemoryPrivateKeyStore();
    await privateKeys.write('key-a', 'private-a');
    await privateKeys.write('key-b', 'private-b');
    // What the transport was actually asked to dial, address and port
    // together, so a build that hardcodes 22 fails here rather than on a phone.
    final addresses = <String>[];
    String dialled(Host host) => '${host.address}:${host.port}';
    final states = <AgentPanelState>[];
    final container = ProviderContainer(
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
    await container.read(herdrHostsProvider.future);
    final subscription = container.listen(
      agentsFeedProvider,
      (_, next) => next.whenData(states.add),
      fireImmediately: true,
    );
    addTearDown(subscription.close);

    await _waitFor(() => addresses.contains(dialled(hostA)));
    expect(addresses, isNot(contains(dialled(hostB))));

    await hosts.setIntegration(hostB.id, IntegrationKind.herdr, true);
    // B's sshd is on 357: the host carries the port and the poll uses it.
    await _waitFor(() => addresses.contains(dialled(hostB)));
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

    expect(addresses, containsAllInOrder([dialled(hostA), dialled(hostB)]));
    // Blocked means blocked: nothing is polled once the set empties.
    expect(addresses, hasLength(fetches));
  });

  test('a name that never resolved is its own outcome', () async {
    final hosts = InMemoryHostRepository();
    await hosts.save(hostA);
    await hosts.setIntegration(hostA.id, IntegrationKind.herdr, true);
    final privateKeys = MemoryPrivateKeyStore();
    await privateKeys.write('key-a', 'private-a');
    final states = <AgentPanelState>[];
    final container = ProviderContainer(
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
    await container.read(herdrHostsProvider.future);
    final subscription = container.listen(
      agentsFeedProvider,
      (_, next) => next.whenData(states.add),
      fireImmediately: true,
    );
    addTearDown(subscription.close);

    // Not folded into unreachable: the two send the user to different places,
    // a typo in the address against a port, a firewall or a dead machine.
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
          id: 'nyx',
          name: 'Nyx',
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

    expect(find.text('nyx unresolved'), findsOneWidget);
    expect(find.text('nyx unreachable'), findsNothing);
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

    // The unresolved line already carries its host, like the unreachable
    // one; only the lines that do not get the prefix.
    expect(find.text('a unresolved'), findsOneWidget);
    expect(find.text('b · key rejected'), findsOneWidget);
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
          port: 22,
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

    // Only the unreachable line carries its host; with two failures the bare
    // lines would not say which machine, so the name goes back.
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

  test('every listed kind has its mark file', () {
    // The manifest in [agentMarkKinds] is what the row trusts, so a kind
    // listed without its file is an empty box rather than the `?` it would
    // have fallen back to. Nothing at runtime can catch that; this does.
    for (final kind in agentMarkKinds) {
      expect(
        File(agentMarkAsset(kind)!).existsSync(),
        isTrue,
        reason: 'agentMarkKinds lists $kind but assets/icons has no file',
      );
    }
    // These two are required; the rest land as the artist traces them.
    expect(agentMarkKinds, containsAll(<String>['claude', 'codex']));
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
    // The letter box is gone, not merely covered: `C` was the whole glyph.
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

  testWidgets('a kind with no mark file keeps the ? box', (tester) async {
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
        matching: find.byType(SvgPicture),
      ),
      findsNothing,
    );
    expect(find.text('?'), findsOneWidget);
    // The fallback is the box only. The name is still what herdr reported.
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

    // Two: the box and the name. An empty name would otherwise render as an
    // empty cell that reads as a layout bug rather than as missing data.
    expect(find.text('?'), findsNWidgets(2));
    expect(
      find.descendant(of: find.byType(AgentMark), matching: find.text('?')),
      findsOneWidget,
    );
  });
}

Future<void> _waitFor(bool Function() condition) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(condition(), isTrue);
}

/// The asset behind the one [AgentMark] on screen, or null when it fell back
/// to `?`. Read off the loader rather than the raster: the point is which file
/// the row asked for.
String? markAsset(WidgetTester tester) {
  final marks = find.descendant(
    of: find.byType(AgentMark),
    matching: find.byType(SvgPicture),
  );
  if (marks.evaluate().isEmpty) return null;
  final loader = tester.widget<SvgPicture>(marks).bytesLoader;
  return loader is SvgAssetLoader ? loader.assetName : null;
}
