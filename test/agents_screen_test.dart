import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotline/application/agents.dart';
import 'package:hotline/application/providers.dart';
import 'package:hotline/data/database.dart';
import 'package:hotline/data/repositories/host_repository.dart';
import 'package:hotline/features/agents/agents_screen.dart';
import 'package:hotline/platform/herdr_client.dart';

import 'support/platform_channels.dart';

const nyx = Host(
  id: 'nyx',
  name: 'Nyx',
  address: '100.118.60.77',
  port: 22,
  user: 'luisnquin',
  keyId: 'k1',
);
const rose = Host(
  id: 'rose',
  name: 'Rose',
  address: '100.1.1.2',
  port: 22,
  user: 'luisnquin',
  keyId: 'k1',
);

AgentSnapshot agent(String name, {required String workspace}) => AgentSnapshot(
  paneId: '$workspace:p1',
  agent: name,
  agentStatus: 'working',
  terminalTitleStripped: 'work',
  workspaceId: workspace,
  cwd: '/workspace/hotline',
  stateChangeSeq: 1,
);

void main() {
  late AppDatabase db;

  setUp(() {
    stubDeviceChannels();
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() => db.close());

  /// §16b.1's grain is read out of the settings table by [StaticSurface], which
  /// every screen sits under, so the database is not optional even here.
  Widget host(AgentPanelState state) => ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(db),
      agentsFeedProvider.overrideWith((ref) => Stream.value(state)),
    ],
    child: const MaterialApp(home: AgentsScreen()),
  );

  /// Panel titles render through [SignalText], which holds a scrambled string
  /// for §16b's decode: a single pump reads a title mid-flipbook.
  Future<void> ready(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  testWidgets('VIEW ALL mirrors no-host and failure states', (tester) async {
    await tester.pumpWidget(host(const AgentPanelState.noHost()));
    await ready(tester);

    expect(find.text('NO HOST · SET IN SYS'), findsOneWidget);
    expect(find.text('WORKSPACES'), findsNothing);
    // Torn down between the two states: swapping the scope's overrides in place
    // leaves the provider holding the value it already had.
    await unmount(tester);

    await tester.pumpWidget(
      host(
        const AgentPanelState([
          HostOutcome(host: nyx, kind: AgentOutcomeKind.unreachable),
        ]),
      ),
    );
    await ready(tester);

    expect(find.text('nyx unreachable'), findsOneWidget);
    expect(find.text('WORKSPACES'), findsNothing);
    await unmount(tester);
  });

  testWidgets('one host collapses to workspace panels', (tester) async {
    await tester.pumpWidget(
      host(
        AgentPanelState([
          HostOutcome(
            host: nyx,
            kind: AgentOutcomeKind.snapshot,
            agents: [
              agent('claude', workspace: 'wQ'),
              agent('codex', workspace: 'wR'),
            ],
          ),
        ]),
      ),
    );
    await ready(tester);

    // §39.20.6: naming the single host on every panel is noise, and one host is
    // the shape every install has until a second machine is registered.
    expect(find.text('WQ'), findsOneWidget);
    expect(find.text('WR'), findsOneWidget);
    expect(find.textContaining('NYX'), findsNothing);
    await unmount(tester);
  });

  testWidgets('two hosts group by host then workspace', (tester) async {
    await tester.pumpWidget(
      host(
        AgentPanelState([
          HostOutcome(
            host: nyx,
            kind: AgentOutcomeKind.snapshot,
            agents: [agent('claude', workspace: 'wQ')],
          ),
          HostOutcome(
            host: rose,
            kind: AgentOutcomeKind.snapshot,
            agents: [agent('codex', workspace: 'wQ')],
          ),
        ]),
      ),
    );
    await ready(tester);

    // The same workspace id on two machines is two panels: `wQ` is a tmux name
    // and says nothing about which host it is on.
    expect(find.text('NYX / WQ'), findsOneWidget);
    expect(find.text('ROSE / WQ'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('a failing host is its own panel beside the others', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        AgentPanelState([
          HostOutcome(
            host: nyx,
            kind: AgentOutcomeKind.snapshot,
            agents: [agent('claude', workspace: 'wQ')],
          ),
          const HostOutcome(host: rose, kind: AgentOutcomeKind.keyRejected),
        ]),
      ),
    );
    await ready(tester);

    expect(find.text('NYX / WQ'), findsOneWidget);
    expect(find.text('ROSE'), findsOneWidget);
    expect(find.text('key rejected'), findsOneWidget);
    await unmount(tester);
  });
}
