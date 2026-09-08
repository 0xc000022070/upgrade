import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spectacle/application/agent_state.dart';
import 'package:spectacle/application/agents.dart';
import 'package:spectacle/application/providers.dart';
import 'package:spectacle/data/database.dart';
import 'package:spectacle/data/repositories/host_repository.dart';
import 'package:spectacle/design/colors.dart';
import 'package:spectacle/design/components/list_row.dart';
import 'package:spectacle/features/agents/agents_screen.dart';
import 'package:spectacle/features/home/agent_mark.dart';
import 'package:spectacle/platform/herdr_client.dart';

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
}) => AgentSnapshot(
  paneId: '$workspace:p1',
  agent: name,
  state: AgentState.of(status),
  terminalTitleStripped: 'work',
  workspaceId: workspace,
  cwd: '/workspace/spectacle',
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
  Widget host(AgentPanelState state) => ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(db),
      agentsFeedProvider.overrideWith((ref) => Stream.value(state)),
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

    // Naming the single host on every panel is noise, and one host is
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
    // The unknown kind is the third row's box, and the only `?` on screen.
    expect(find.text('?'), findsOneWidget);
    expect(find.text('C'), findsNothing);
    expect(find.text('X'), findsNothing);
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
    expect(rows['DONE'], SpectacleColors.textPrimary);
    expect(rows['IDLE'], SpectacleColors.textMuted);
    expect(rows['COMPACTING'], SpectacleColors.textMuted);
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
