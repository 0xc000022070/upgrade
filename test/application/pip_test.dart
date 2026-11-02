import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vector_graphics/vector_graphics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/application/agents/agent_state.dart';
import 'package:upgrade/application/agents/agents.dart';
import 'package:upgrade/application/pip.dart';
import 'package:upgrade/app/pip_host.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/design/colors.dart';
import 'package:upgrade/features/agents/pip_panel.dart';
import 'package:upgrade/features/home/agent_mark.dart';
import 'package:upgrade/features/home/agents_panel.dart';
import 'package:upgrade/platform/herdr/herdr_client.dart';

import '../support/fake_pip.dart';
import '../support/themed_app.dart';

const nyx = Host(
  id: 'a',
  name: 'nyx',
  address: '100.1.1.1',
  port: 22,
  user: 'ops',
  keyId: 'key-a',
);
const rose = Host(
  id: 'b',
  name: 'rose',
  address: '100.1.1.2',
  port: 22,
  user: 'ops',
  keyId: 'key-b',
);

AgentSnapshot agent(String name, String status) => AgentSnapshot(
  session: 'default',
  paneId: 'wQ:p$name',
  agent: name,
  state: AgentState.of(status),
  terminalTitleStripped: 'work',
  workspaceId: 'wQ',
  cwd: '/workspace/upgrade',
  stateChangeSeq: 1,
);

AgentPanelState panel(List<AgentSnapshot> agents, {Host on = nyx}) =>
    AgentPanelState([
      HostOutcome(host: on, kind: AgentOutcomeKind.snapshot, agents: agents),
    ]);

Widget harness(
  FakePip pip,
  Stream<AgentPanelState> agents,
  Widget child, {
  bool live = true,
  double textScale = 1.0,
}) => ProviderScope(
  overrides: [
    pipSurfaceProvider.overrideWithValue(pip),
    agentsFeedProvider.overrideWith((ref) => agents),
    agentsFeedLiveProvider.overrideWithValue(live),
  ],
  child: Theme(
    data: testTheme,
    child: Directionality(
      textDirection: TextDirection.ltr,
      // The window clamps the reader's text scale rather than ignoring it, and asking what the
      // scale is means there has to be something to ask.
      child: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: child,
      ),
    ),
  ),
);

/// A second harness pumped under the same scope keeps the first one's feed: a stream
/// override is read once.
Future<void> clear(WidgetTester tester) =>
    tester.pumpWidget(const SizedBox.shrink());

bool dimmed(WidgetTester tester) {
  final text = tester.widget<Text>(find.text('PIP'));
  return text.style?.color == UpgradeColors.textDisabled;
}

List<String> drawnRows(WidgetTester tester) => tester
    .widgetList<RichText>(find.byType(RichText))
    .map((text) => text.text.toPlainText())
    .toList();

List<String> markAssets(WidgetTester tester) => [
  for (final picture in tester.widgetList<VectorGraphic>(
    find.descendant(
      of: find.byType(AgentMark),
      matching: find.byType(VectorGraphic),
    ),
  ))
    if (picture.loader case final AssetBytesLoader loader) loader.assetName,
];

void main() {
  group('the picture-in-picture action', () {
    testWidgets('live work gets a separate button', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 800);
      addTearDown(tester.view.reset);
      final pip = FakePip();
      await tester.pumpWidget(
        harness(
          pip,
          Stream.value(panel([agent('claude', 'working')])),
          const AgentsPanel(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('PIP'), findsOneWidget);
      expect(pip.entries, 0);

      await tester.tap(find.text('PIP'));
      await tester.pump();

      expect(pip.entries, 1);
    });

    testWidgets('quiet and stale feeds keep a dim word that does nothing', (
      tester,
    ) async {
      final pip = FakePip();
      await tester.pumpWidget(
        harness(
          pip,
          Stream.value(panel([agent('claude', 'idle')])),
          const AgentsPanel(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('PIP'), findsOneWidget);
      expect(dimmed(tester), isTrue);
      await tester.tap(find.text('PIP'), warnIfMissed: false);
      await tester.pump();
      expect(pip.entries, 0);

      await clear(tester);
      await tester.pumpWidget(
        harness(
          pip,
          Stream.value(panel([agent('claude', 'working')])),
          const AgentsPanel(),
          live: false,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('PIP'), findsOneWidget);
      expect(dimmed(tester), isTrue);
      await tester.tap(find.text('PIP'), warnIfMissed: false);
      await tester.pump();
      expect(pip.entries, 0);
    });

    testWidgets('no window and no host leave nothing to draw', (tester) async {
      await tester.pumpWidget(
        harness(
          FakePip(here: false),
          Stream.value(panel([agent('claude', 'working')])),
          const AgentsPanel(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('PIP'), findsNothing);

      await clear(tester);
      await tester.pumpWidget(
        harness(
          FakePip(),
          Stream.value(const AgentPanelState.noHost()),
          const AgentsPanel(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('PIP'), findsNothing);
    });

    testWidgets('the corner window keeps the feed live', (tester) async {
      final container = ProviderContainer(
        overrides: [homeAgentsVisibleProvider.overrideWith((ref) => true)],
      );
      addTearDown(container.dispose);
      final live = container.listen(agentsFeedLiveProvider, (_, _) {});
      addTearDown(live.close);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(Duration.zero);
      expect(container.read(agentsFeedLiveProvider), isTrue);

      // Entering picture-in-picture pauses the activity, which the framework reports as
      // inactive.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump(Duration.zero);
      expect(container.read(agentsFeedLiveProvider), isTrue);
      expect(container.read(appForegroundProvider), isFalse);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(Duration.zero);
      expect(container.read(agentsFeedLiveProvider), isFalse);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(Duration.zero);
      expect(container.read(agentsFeedLiveProvider), isTrue);
      expect(container.read(appForegroundProvider), isTrue);
    });
  });

  group('the window itself', () {
    testWidgets('the tree under it is kept, not replaced', (tester) async {
      final pip = FakePip();
      await tester.pumpWidget(
        harness(
          pip,
          Stream.value(panel([agent('claude', 'working')])),
          const PipHost(child: Text('the app')),
        ),
      );
      await tester.pump();

      expect(find.byType(PipPanel), findsNothing);

      pip.modes.add(true);
      await tester.pumpAndSettle();

      expect(find.byType(PipPanel), findsOneWidget);
      expect(find.text('the app', skipOffstage: false), findsOneWidget);
      expect(find.text('the app'), findsNothing);

      pip.modes.add(false);
      await tester.pumpAndSettle();

      expect(find.byType(PipPanel), findsNothing);
      expect(find.text('the app'), findsOneWidget);
    });

    testWidgets('it says what the shade says', (tester) async {
      final pip = FakePip();
      await tester.pumpWidget(
        harness(
          pip,
          Stream.value(
            AgentPanelState([
              HostOutcome(
                host: nyx,
                kind: AgentOutcomeKind.snapshot,
                agents: [agent('claude', 'blocked'), agent('codex', 'working')],
              ),
              HostOutcome(
                host: rose,
                kind: AgentOutcomeKind.snapshot,
                agents: [agent('amp', 'working')],
              ),
            ]),
          ),
          const PipPanel(),
        ),
      );
      await tester.pump();

      expect(find.text('1 BLOCKED · 2 WORKING'), findsOneWidget);
    });

    testWidgets('the blocked agent is the first row', (tester) async {
      final pip = FakePip();
      await tester.pumpWidget(
        harness(
          pip,
          Stream.value(
            panel([
              agent('amp', 'working'),
              agent('claude', 'blocked'),
              agent('codex', 'idle'),
            ]),
          ),
          const PipPanel(),
        ),
      );
      await tester.pump();

      final rows = drawnRows(tester);
      expect(rows, contains('CLAUDE · nyx'));
      expect(rows, contains('AMP · nyx'));
      expect(rows, isNot(contains('CODEX · nyx')));
      expect(rows.indexOf('CLAUDE · nyx'), lessThan(rows.indexOf('AMP · nyx')));
    });

    testWidgets('more agents than fit are counted', (tester) async {
      final pip = FakePip();
      await tester.pumpWidget(
        harness(
          pip,
          Stream.value(
            panel([
              for (final name in ['a', 'b', 'c', 'd', 'e'])
                agent(name, 'working'),
            ]),
          ),
          const PipPanel(),
        ),
      );
      await tester.pump();

      expect(find.text('+2 MORE'), findsOneWidget);
    });

    testWidgets('a host that is down takes the line', (tester) async {
      final pip = FakePip();
      await tester.pumpWidget(
        harness(
          pip,
          Stream.value(
            const AgentPanelState([
              HostOutcome(host: nyx, kind: AgentOutcomeKind.unreachable),
            ]),
          ),
          const PipPanel(),
        ),
      );
      await tester.pump();

      expect(find.text('NYX UNREACHABLE'), findsOneWidget);
    });
  });

  group('an agent is told apart before its name is read', () {
    test('a name the app cannot place keeps its own letter', () {
      expect(agentMarkLetter('gemini'), 'G');
      expect(agentMarkLetter('aider'), 'A');
      expect(agentMarkLetter('goose-cli'), 'G');
      expect(agentMarkLetter(''), '?');
    });

    testWidgets('the agents the app ships a mark for are drawn with it', (
      tester,
    ) async {
      final pip = FakePip();
      await tester.pumpWidget(
        harness(
          pip,
          Stream.value(
            panel([agent('claude', 'blocked'), agent('codex', 'working')]),
          ),
          const PipPanel(),
        ),
      );
      await tester.pump();

      expect(find.byType(AgentMark), findsNWidgets(2));
      expect(markAssets(tester), [
        'assets/icons/agent-claude.svg',
        'assets/icons/agent-codex.svg',
      ]);
    });

    testWidgets('an agent with no mark file falls back to its letter', (
      tester,
    ) async {
      final pip = FakePip();
      await tester.pumpWidget(
        harness(
          pip,
          Stream.value(
            panel([agent('aider', 'working'), agent('gemini', 'working')]),
          ),
          const PipPanel(),
        ),
      );
      await tester.pump();

      expect(markAssets(tester), isEmpty);
      expect(find.text('A'), findsOneWidget);
      expect(find.text('G'), findsOneWidget);
    });
  });

  group('the window is honest about its own age', () {
    testWidgets('nothing dialling is said, not drawn as a count', (
      tester,
    ) async {
      final pip = FakePip();
      await tester.pumpWidget(
        harness(
          pip,
          Stream.value(
            panel([agent('claude', 'blocked'), agent('codex', 'working')]),
          ),
          const PipPanel(),
          live: false,
        ),
      );
      await tester.pump();

      expect(find.text('NOT WATCHING'), findsOneWidget);
      expect(find.text('1 BLOCKED · 1 WORKING'), findsNothing);
      expect(find.text('LAST SEEN 1 BLOCKED · 1 WORKING'), findsOneWidget);
      expect(drawnRows(tester).where((row) => row.contains(' · nyx')), isEmpty);
    });

    testWidgets('the whole window is one sentence to a reader', (tester) async {
      final pip = FakePip();
      await tester.pumpWidget(
        harness(
          pip,
          Stream.value(
            panel([agent('claude', 'blocked'), agent('codex', 'working')]),
          ),
          const PipPanel(),
        ),
      );
      await tester.pump();

      expect(
        tester
            .widgetList<Semantics>(find.byType(Semantics))
            .map((node) => node.properties.label)
            .whereType<String>(),
        contains(
          '1 BLOCKED, 1 WORKING. claude blocked on nyx. codex working on nyx',
        ),
      );
    });
  });

  group('the window is the size the system made it', () {
    testWidgets('rows come off rather than off the bottom', (tester) async {
      final pip = FakePip();
      Future<void> draw(double height) => tester.pumpWidget(
        harness(
          pip,
          Stream.value(
            panel([
              for (final name in ['a', 'b', 'c', 'd', 'e'])
                agent(name, 'working'),
            ]),
          ),
          Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 300,
              height: height,
              child: const PipPanel(),
            ),
          ),
        ),
      );

      await draw(300);
      await tester.pump();
      final tall = drawnRows(tester);
      expect(tall.where((row) => row.contains(' · nyx')), hasLength(3));
      expect(find.text('+2 MORE'), findsOneWidget);

      await draw(72);
      await tester.pump();
      final short = drawnRows(tester);
      final listed = short.where((row) => row.contains(' · nyx')).length;
      expect(listed, lessThan(3));
      expect(find.text('+${5 - listed} MORE'), findsOneWidget);
    });

    testWidgets('the text size stops rising before the window does', (
      tester,
    ) async {
      final pip = FakePip();
      Future<void> draw(double scale) => tester.pumpWidget(
        harness(
          pip,
          Stream.value(panel([agent('claude', 'working')])),
          const PipPanel(),
          textScale: scale,
        ),
      );

      await draw(1.0);
      await tester.pump();
      final plain = tester.getSize(find.byType(AgentMark).first);

      await draw(3.0);
      await tester.pump();
      final huge = tester.getSize(find.byType(AgentMark).first);

      expect(huge.width, greaterThan(plain.width));
      expect(huge.width, closeTo(plain.width * 1.3, 0.01));
    });
  });
}
