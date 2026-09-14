import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/application/agent_state.dart';
import 'package:dazzle/application/agents.dart';
import 'package:dazzle/application/pip.dart';
import 'package:dazzle/app/pip_host.dart';
import 'package:dazzle/data/repositories/host_repository.dart';
import 'package:dazzle/features/agents/pip_panel.dart';
import 'package:dazzle/features/home/agent_mark.dart';
import 'package:dazzle/features/home/agents_panel.dart';
import 'package:dazzle/platform/herdr_client.dart';

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
  cwd: '/workspace/dazzle',
  stateChangeSeq: 1,
);

AgentPanelState panel(List<AgentSnapshot> agents, {Host on = nyx}) =>
    AgentPanelState([
      HostOutcome(host: on, kind: AgentOutcomeKind.snapshot, agents: agents),
    ]);

/// A window that records what it was told rather than asking an activity.
class FakePip implements PipSurface {
  FakePip({this.here = true});

  final bool here;
  var entries = 0;
  final modes = StreamController<bool>.broadcast();

  @override
  Future<bool> available() async => here;

  @override
  Future<bool> enter() async {
    entries++;
    return here;
  }

  @override
  Stream<bool> mode() => modes.stream;
}

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
  child: Directionality(
    textDirection: TextDirection.ltr,
    // The window clamps the reader's text scale rather than ignoring it, and
    // asking what the scale is means there has to be something to ask.
    child: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
      child: child,
    ),
  ),
);

/// The rows drawn on the window, in the order they were drawn, as the reader
/// sees them. They are spans rather than whole strings, so the plain text of
/// the paragraph is what there is to compare.
List<String> drawnRows(WidgetTester tester) => tester
    .widgetList<RichText>(find.byType(RichText))
    .map((text) => text.text.toPlainText())
    .toList();

/// The mark files the window asked for, in row order. Read off the loaders
/// rather than the raster: the point is which file each row named.
List<String> markAssets(WidgetTester tester) => [
  for (final picture in tester.widgetList<SvgPicture>(
    find.descendant(
      of: find.byType(AgentMark),
      matching: find.byType(SvgPicture),
    ),
  ))
    if (picture.bytesLoader case final SvgAssetLoader loader) loader.assetName,
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

    testWidgets('quiet, stale, and unsupported feeds have no button', (
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
      expect(find.text('PIP'), findsNothing);

      await tester.pumpWidget(
        harness(
          pip,
          Stream.value(panel([agent('claude', 'working')])),
          const AgentsPanel(),
          live: false,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('PIP'), findsNothing);

      await tester.pumpWidget(
        harness(
          FakePip(here: false),
          Stream.value(panel([agent('claude', 'working')])),
          const AgentsPanel(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('PIP'), findsNothing);
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
      // Still mounted, and still holding whatever state it had: offstage is not
      // gone.
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
      // Resting agents are not on the window at all.
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
      // herdr reports whatever it found in the pane, so the ones the app has
      // no file for are the normal case rather than the edge. One box with a
      // question mark for every one of them separates nothing.
      expect(agentMarkLetter('gemini'), 'G');
      expect(agentMarkLetter('aider'), 'A');
      expect(agentMarkLetter('goose-cli'), 'G');
      // The one case the question mark is honest in.
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

      // The count is still there to be read off the feed, and it is not the
      // headline: nothing can take this window down from inside the app, so the
      // choice is between a stale tally and saying that it is one.
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
      // Fewer rows, and the ones that came off are counted rather than clipped:
      // the window says five either way.
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

      // It rises, because a window that ignores the setting is a window the
      // reader it was set for cannot read. It stops, because the system decides
      // how big this is and nothing here can ask for more room.
      expect(huge.width, greaterThan(plain.width));
      expect(huge.width, closeTo(plain.width * 1.3, 0.01));
    });
  });
}
