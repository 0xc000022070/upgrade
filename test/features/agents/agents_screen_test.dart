import 'dart:async';

import '../../support/native_plugins.dart';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vector_graphics/vector_graphics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/platform/herdr/agent_state.dart';
import 'package:upgrade/application/agents/agents.dart';
import 'package:upgrade/application/pip.dart';
import 'package:upgrade/data/database.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/design/colors.dart';
import 'package:upgrade/design/components/list_row.dart';
import 'package:upgrade/features/agents/agents_screen.dart';
import 'package:upgrade/features/home/agent_mark.dart';
import 'package:upgrade/platform/herdr/herdr_client.dart';
import 'package:upgrade/application/providers.dart';

import '../../support/fake_pip.dart';
import '../../support/platform_channels.dart';
import '../../support/themed_app.dart';

const oak = Host(
  id: 'oak',
  name: 'Oak',
  address: '198.51.100.77',
  port: 22,
  user: 'developer',
  keyId: 'k1',
);
const pine = Host(
  id: 'pine',
  name: 'Pine',
  address: '100.1.1.2',
  port: 22,
  user: 'developer',
  keyId: 'k1',
);

AgentSnapshot agent(
  String name, {
  required String workspace,
  String status = 'working',
  String session = 'default',
  String? label,
  String title = 'work',
}) => AgentSnapshot(
  session: session,
  paneId: '$workspace:p1',
  agent: name,
  state: AgentState.of(status),
  terminalTitleStripped: title,
  workspaceId: workspace,
  cwd: '/workspace/upgrade',
  stateChangeSeq: 1,
  workspaceLabel: label,
);

void main() {
  late AppDatabase db;

  setUp(() {
    stubDeviceChannels();
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() => db.close());

  /// [StaticSurface] reads the background grain out of the settings table, so the database
  /// is not optional even here.
  Widget host(AgentPanelState state, {AgentRetry? retry, FakePip? pip}) =>
      ProviderScope(
        retry: noRetry,
        overrides: [
          ...featureTestOverrides(db),
          agentsFeedProvider.overrideWith((ref) => Stream.value(state)),
          if (retry != null) agentRetryProvider.overrideWithValue(retry),
          if (pip != null) ...[
            pipSurfaceProvider.overrideWithValue(pip),
            agentsFeedLiveProvider.overrideWithValue(true),
          ],
        ],
        child: MaterialApp(theme: testTheme, home: AgentsScreen()),
      );

  /// Panel titles hold a scrambled string for the decode: a single pump reads a title
  /// mid-flipbook.
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
        host: oak,
        kind: AgentOutcomeKind.snapshot,
        agents: [agent('codex', workspace: 'w9', status: 'idle')],
      ),
      HostOutcome(
        host: pine,
        kind: AgentOutcomeKind.snapshot,
        agents: [claude],
      ),
    ]);
    await tester.pumpWidget(
      ProviderScope(
        retry: noRetry,
        overrides: [
          ...featureTestOverrides(db),
          agentsFeedProvider.overrideWith((ref) => Stream.value(state)),
        ],
        child: MaterialApp(
          theme: testTheme,
          home: AgentsScreen(
            onOpen: (_, host, agent) => opened.add((host, agent)),
          ),
        ),
      ),
    );
    await ready(tester);

    await tester.tap(find.widgetWithText(ListRow, 'CLAUDE · upgrade · Pine'));

    expect(opened, [(pine, claude)]);

    await unmount(tester);
  });

  testWidgets('task titles lead and blocked agents explain the next action', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        AgentPanelState([
          HostOutcome(
            host: oak,
            kind: AgentOutcomeKind.snapshot,
            agents: [
              agent(
                'claude',
                workspace: 'w1',
                status: 'blocked',
                title: 'Fix terminal reconnect',
              ),
              agent('codex', workspace: 'w2', title: ''),
            ],
          ),
        ]),
      ),
    );
    await ready(tester);
    final rows = tester.widgetList<ListRow>(find.byType(ListRow)).toList();
    expect(rows.first.title, 'Fix terminal reconnect');
    expect(rows.first.titleMaxLines, 2);
    expect(find.text('Needs attention · tap to open terminal'), findsOneWidget);
    expect(find.text('CODEX session'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('VIEW ALL mirrors no-host and failure states', (tester) async {
    await tester.pumpWidget(host(const AgentPanelState.noHost()));
    await ready(tester);

    expect(find.text('TURN AGENTS ON IN A HOST'), findsOneWidget);
    expect(find.text('WORKSPACES'), findsNothing);
    // Swapping the scope's overrides in place leaves the provider holding the value it
    // already had.
    await unmount(tester);

    await tester.pumpWidget(
      host(
        const AgentPanelState([
          HostOutcome(host: oak, kind: AgentOutcomeKind.unreachable),
        ]),
      ),
    );
    await ready(tester);

    expect(find.text('oak unreachable'), findsOneWidget);
    expect(find.text('HERDR check could not reach host'), findsOneWidget);
    expect(find.text('developer@198.51.100.77:22'), findsOneWidget);
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
          HostOutcome(host: oak, kind: AgentOutcomeKind.unreachable),
        ]),
        retry: (host, {source = AgentSource.herdr}) {
          requested = host;
          return retried.future;
        },
      ),
    );
    await ready(tester);

    await tester.tap(find.text('RETRY'));
    await tester.pump();

    expect(requested, oak);
    expect(find.text('RETRYING'), findsOneWidget);

    retried.complete(
      const HostOutcome(host: oak, kind: AgentOutcomeKind.keyRejected),
    );
    await ready(tester);

    expect(find.text('key rejected'), findsOneWidget);
    expect(find.text('check SSH key in MACHINES'), findsOneWidget);
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
          HostOutcome(host: oak, kind: AgentOutcomeKind.unreachable),
        ]),
        retry: (_, {source = AgentSource.herdr}) => Future.error(
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
            host: oak,
            kind: AgentOutcomeKind.snapshot,
            agents: [
              agent('claude', workspace: 'wK', label: 'upgrade 2'),
              agent('codex', workspace: 'wR'),
            ],
          ),
        ]),
      ),
    );
    await ready(tester);

    expect(find.text('UPGRADE 2'), findsOneWidget);
    expect(find.text('wR'), findsOneWidget);
    expect(find.text('WK'), findsNothing);
    expect(find.text('WR'), findsNothing);
    expect(find.textContaining('OAK'), findsNothing);
    await unmount(tester);
  });

  testWidgets('a host with agents in two sessions names the session', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        AgentPanelState([
          HostOutcome(
            host: oak,
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

    expect(find.text('DEFAULT / wQ'), findsOneWidget);
    expect(find.text('LAB / wQ'), findsOneWidget);
    expect(find.text('wQ'), findsNothing);
    await unmount(tester);
  });

  testWidgets('two hosts group by host then workspace', (tester) async {
    await tester.pumpWidget(
      host(
        AgentPanelState([
          HostOutcome(
            host: oak,
            kind: AgentOutcomeKind.snapshot,
            agents: [agent('claude', workspace: 'wQ')],
          ),
          HostOutcome(
            host: pine,
            kind: AgentOutcomeKind.snapshot,
            agents: [agent('codex', workspace: 'wQ', label: '~')],
          ),
        ]),
      ),
    );
    await ready(tester);

    expect(find.text('OAK / wQ'), findsOneWidget);
    expect(find.text('PINE / ~'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('a failing host is its own panel beside the others', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        AgentPanelState([
          HostOutcome(
            host: oak,
            kind: AgentOutcomeKind.snapshot,
            agents: [agent('claude', workspace: 'wQ')],
          ),
          const HostOutcome(host: pine, kind: AgentOutcomeKind.keyRejected),
        ]),
      ),
    );
    await ready(tester);

    expect(find.text('OAK / wQ'), findsOneWidget);
    expect(find.text('PINE'), findsOneWidget);
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
            host: oak,
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
    expect(find.text('G'), findsOneWidget);
    expect(find.text('?'), findsNothing);
    expect(find.text('C'), findsNothing);
    expect(find.text('GIZMO · upgrade · Oak'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('a finished agent is not dressed as an idle one', (tester) async {
    await tester.pumpWidget(
      host(
        AgentPanelState([
          HostOutcome(
            host: oak,
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
    expect(rows['DONE'], UpgradeColors.textPrimary);
    expect(rows['IDLE'], UpgradeColors.textMuted);
    expect(rows['COMPACTING'], UpgradeColors.textMuted);
    await unmount(tester);
  });

  testWidgets('an empty kind is ? in the box and ? as the name', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        AgentPanelState([
          HostOutcome(
            host: oak,
            kind: AgentOutcomeKind.snapshot,
            agents: [agent('', workspace: 'wQ')],
          ),
        ]),
      ),
    );
    await ready(tester);

    expect(find.text('? · upgrade · Oak'), findsOneWidget);
    expect(
      find.descendant(of: find.byType(AgentMark), matching: find.text('?')),
      findsOneWidget,
    );
    await unmount(tester);
  });

  testWidgets('the route carries the same PIP action as the panel', (
    tester,
  ) async {
    final pip = FakePip();
    await tester.pumpWidget(
      host(
        AgentPanelState([
          HostOutcome(
            host: oak,
            kind: AgentOutcomeKind.snapshot,
            agents: [agent('claude', workspace: 'wQ', status: 'working')],
          ),
        ]),
        pip: pip,
      ),
    );
    await ready(tester);

    expect(find.text('PIP'), findsOneWidget);
    await tester.tap(find.text('PIP'));
    await tester.pump();
    expect(pip.entries, 1);
    await unmount(tester);
  });
}

List<String> markAssets(WidgetTester tester) => [
  for (final picture in tester.widgetList<VectorGraphic>(
    find.descendant(
      of: find.byType(AgentMark),
      matching: find.byType(VectorGraphic),
    ),
  ))
    if (picture.loader case final AssetBytesLoader loader) loader.assetName,
];
