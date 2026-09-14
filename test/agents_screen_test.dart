import 'dart:async';

import 'support/native_plugins.dart';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/application/agent_state.dart';
import 'package:dazzle/application/agents.dart';
import 'package:dazzle/data/database.dart';
import 'package:dazzle/data/repositories/host_repository.dart';
import 'package:dazzle/design/colors.dart';
import 'package:dazzle/design/components/list_row.dart';
import 'package:dazzle/features/agents/agents_screen.dart';
import 'package:dazzle/features/home/agent_mark.dart';
import 'package:dazzle/platform/herdr_client.dart';

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

AgentSnapshot agent(
  String name, {
  required String workspace,
  String status = 'working',
  String session = 'default',
}) => AgentSnapshot(
  session: session,
  paneId: '$workspace:p1',
  agent: name,
  state: AgentState.of(status),
  terminalTitleStripped: 'work',
  workspaceId: workspace,
  cwd: '/workspace/dazzle',
  stateChangeSeq: 1,
);

void main() {
  late AppDatabase db;

  setUp(() {
    stubDeviceChannels();
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() => db.close());

  /// The background grain is read out of the settings table by [StaticSurface],
  /// which
  /// every screen sits under, so the database is not optional even here.
  Widget host(AgentPanelState state, {AgentRetry? retry}) => ProviderScope(
    overrides: [
      ...featureTestOverrides(db),
      agentsFeedProvider.overrideWith((ref) => Stream.value(state)),
      if (retry != null) agentRetryProvider.overrideWithValue(retry),
    ],
    child: const MaterialApp(home: AgentsScreen()),
  );

  /// Panel titles render through [SignalText], which holds a scrambled string
  /// for the decode: a single pump reads a title mid-flipbook.
  Future<void> ready(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  testWidgets('a row hands its tap the host and the agent', (tester) async {
    final opened = <(Host, AgentSnapshot)>[];
    final claude = agent('claude', workspace: 'w22');
    final state = AgentPanelState([
      HostOutcome(
        host: nyx,
        kind: AgentOutcomeKind.snapshot,
        agents: [agent('codex', workspace: 'w9', status: 'idle')],
      ),
      HostOutcome(
        host: rose,
        kind: AgentOutcomeKind.snapshot,
        agents: [claude],
      ),
    ]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...featureTestOverrides(db),
          agentsFeedProvider.overrideWith((ref) => Stream.value(state)),
        ],
        child: MaterialApp(
          home: AgentsScreen(
            onOpen: (host, agent) => opened.add((host, agent)),
          ),
        ),
      ),
    );
    await ready(tester);

    await tester.tap(find.widgetWithText(ListRow, 'CLAUDE'));

    expect(opened, [(rose, claude)]);

    await unmount(tester);
  });

  testWidgets('VIEW ALL mirrors no-host and failure states', (tester) async {
    await tester.pumpWidget(host(const AgentPanelState.noHost()));
    await ready(tester);

    expect(find.text('TURN HERDR ON IN A HOST'), findsOneWidget);
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
    expect(find.text('HERDR check could not reach host'), findsOneWidget);
    expect(find.text('luisnquin@100.118.60.77:22'), findsOneWidget);
    expect(find.text('never connected'), findsOneWidget);
    expect(find.text('RETRY'), findsOneWidget);
    expect(find.text('WORKSPACES'), findsNothing);
    await unmount(tester);
  });

  testWidgets('a failed host retries and keeps raw errors off screen', (
    tester,
  ) async {
    final retried = Completer<HostOutcome>();
    Host? requested;
    await tester.pumpWidget(
      host(
        const AgentPanelState([
          HostOutcome(host: nyx, kind: AgentOutcomeKind.unreachable),
        ]),
        retry: (host) {
          requested = host;
          return retried.future;
        },
      ),
    );
    await ready(tester);

    await tester.tap(find.text('RETRY'));
    await tester.pump();

    expect(requested, nyx);
    expect(find.text('RETRYING'), findsOneWidget);

    retried.complete(
      const HostOutcome(host: nyx, kind: AgentOutcomeKind.keyRejected),
    );
    await ready(tester);

    expect(find.text('key rejected'), findsOneWidget);
    expect(find.text('check SSH key in HOSTS'), findsOneWidget);
    expect(find.text('RETRY'), findsNothing);
    expect(find.textContaining('private'), findsNothing);

    await unmount(tester);
  });

  testWidgets('an unexpected retry error is reduced to a safe diagnostic', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        const AgentPanelState([
          HostOutcome(host: nyx, kind: AgentOutcomeKind.unreachable),
        ]),
        retry: (_) => Future.error(
          StateError('private key material must not reach the screen'),
        ),
      ),
    );
    await ready(tester);

    await tester.tap(find.text('RETRY'));
    await ready(tester);

    expect(find.text('retry request failed'), findsOneWidget);
    expect(find.textContaining('private key material'), findsNothing);
    expect(find.text('RETRY'), findsOneWidget);

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

    // Naming the single host on every panel is noise, and one host is
    // the shape every install has until a second machine is registered.
    expect(find.text('WQ'), findsOneWidget);
    expect(find.text('WR'), findsOneWidget);
    expect(find.textContaining('NYX'), findsNothing);
    await unmount(tester);
  });

  testWidgets('a host with agents in two sessions names the session', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        AgentPanelState([
          HostOutcome(
            host: nyx,
            kind: AgentOutcomeKind.snapshot,
            agents: [
              agent('claude', workspace: 'wQ', session: 'lab'),
              agent('codex', workspace: 'wQ', session: 'default'),
            ],
          ),
        ]),
      ),
    );
    await ready(tester);

    // The same rule as the host's name: one session is nobody's business,
    // two have to be told apart, and the same workspace id lives in both.
    expect(find.text('DEFAULT / WQ'), findsOneWidget);
    expect(find.text('LAB / WQ'), findsOneWidget);
    expect(find.text('WQ'), findsNothing);
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

  testWidgets('the route rows carry the same marks as the panel', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        AgentPanelState([
          HostOutcome(
            host: nyx,
            kind: AgentOutcomeKind.snapshot,
            agents: [
              agent('claude', workspace: 'wQ'),
              agent('codex', workspace: 'wQ'),
              agent('gizmo', workspace: 'wQ'),
            ],
          ),
        ]),
      ),
    );
    await ready(tester);

    expect(markAssets(tester), [
      'assets/icons/agent-claude.svg',
      'assets/icons/agent-codex.svg',
    ]);
    // The unknown kind is the third row's box, drawn as its own initial. The
    // two that have a file are drawn from it and never fall back to a letter.
    expect(find.text('G'), findsOneWidget);
    expect(find.text('?'), findsNothing);
    expect(find.text('C'), findsNothing);
    expect(find.text('GIZMO'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('a finished agent is not dressed as an idle one', (tester) async {
    await tester.pumpWidget(
      host(
        AgentPanelState([
          HostOutcome(
            host: nyx,
            kind: AgentOutcomeKind.snapshot,
            agents: [
              agent('claude', workspace: 'wQ', status: 'done'),
              agent('codex', workspace: 'wQ', status: 'idle'),
              agent('gizmo', workspace: 'wQ', status: 'compacting'),
            ],
          ),
        ]),
      ),
    );
    await ready(tester);

    final rows = {
      for (final row in tester.widgetList<ListRow>(find.byType(ListRow)))
        row.value: row.valueColor,
    };
    // Work waiting to be read is brighter than work that was already seen,
    // and a word the app cannot place is drawn as itself rather than dropped.
    expect(rows['DONE'], DazzleColors.textPrimary);
    expect(rows['IDLE'], DazzleColors.textMuted);
    expect(rows['COMPACTING'], DazzleColors.textMuted);
    await unmount(tester);
  });

  testWidgets('an empty kind is ? in the box and ? as the name', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        AgentPanelState([
          HostOutcome(
            host: nyx,
            kind: AgentOutcomeKind.snapshot,
            agents: [agent('', workspace: 'wQ')],
          ),
        ]),
      ),
    );
    await ready(tester);

    expect(find.text('?'), findsNWidgets(2));
    expect(
      find.descendant(of: find.byType(AgentMark), matching: find.text('?')),
      findsOneWidget,
    );
    await unmount(tester);
  });
}

/// The assets behind the marks on screen, in row order. Read off the loaders
/// rather than the raster: the point is which file each row asked for.
List<String> markAssets(WidgetTester tester) => [
  for (final picture in tester.widgetList<SvgPicture>(
    find.descendant(
      of: find.byType(AgentMark),
      matching: find.byType(SvgPicture),
    ),
  ))
    if (picture.bytesLoader case final SvgAssetLoader loader) loader.assetName,
];
