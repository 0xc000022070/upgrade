import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spectacle/application/agent_state.dart';
import 'package:spectacle/application/agents.dart';
import 'package:spectacle/application/navigation.dart';
import 'package:spectacle/data/repositories/host_repository.dart';
import 'package:spectacle/design/colors.dart';
import 'package:spectacle/features/agents/agent_status_bar.dart';
import 'package:spectacle/platform/herdr_client.dart';

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
  cwd: '/workspace/spectacle',
  stateChangeSeq: 1,
);

HostOutcome answering(List<AgentSnapshot> agents, {Host on = nyx}) =>
    HostOutcome(host: on, kind: AgentOutcomeKind.snapshot, agents: agents);

/// What a phone hands over when the reader raises the text size: a curve, not a
/// factor, which gives a small size most of the rise and a large one almost
/// none.
class _SystemCurve implements TextScaler {
  const _SystemCurve();

  @override
  double scale(double fontSize) =>
      fontSize <= 20 ? fontSize * 2 : fontSize * 1.05;

  @override
  double get textScaleFactor => 2;

  @override
  TextScaler clamp({double minScaleFactor = 0, double maxScaleFactor = 1}) =>
      this;
}

Future<void> pumpBar(
  WidgetTester tester,
  List<HostOutcome> outcomes, {
  int tab = 2,
  TextScaler? scaler,
}) async {
  const bar = AgentStatusBar();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        navIndexProvider.overrideWith((ref) => tab),
        agentsFeedProvider.overrideWith(
          (ref) => Stream.value(AgentPanelState(outcomes)),
        ),
      ],
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: scaler == null
            ? bar
            : Builder(
                builder: (context) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: scaler, size: const Size(400, 800)),
                  child: bar,
                ),
              ),
      ),
    ),
  );
  await tester.pump();
}

/// The colour of the block at the head of the line.
Color mark(WidgetTester tester) => tester
    .widget<ColoredBox>(
      find.descendant(
        of: find.byKey(const ValueKey('agent-status-mark')),
        matching: find.byType(ColoredBox),
      ),
    )
    .color;

/// Whatever the bar put on its one line, or null when there is no bar.
String? line(WidgetTester tester) {
  final texts = tester
      .widgetList<Text>(find.byType(Text))
      .map((text) => text.data)
      .whereType<String>()
      .where((text) => text != 'AGENTS')
      .toList();
  return texts.isEmpty ? null : texts.single;
}

void main() {
  group('the line stands up for what is worth standing up for', () {
    testWidgets('a screen that is not HOME gets the counts', (tester) async {
      await pumpBar(tester, [
        answering([
          agent('claude', 'blocked'),
          agent('codex', 'working'),
          agent('amp', 'done'),
          agent('opencode', 'idle'),
        ]),
      ]);

      // All four states herdr classifies, blocked first because it is the count
      // about to cost the user something.
      expect(line(tester), '1 BLOCKED · 1 WORKING · 1 DONE · 1 IDLE');
    });

    testWidgets('HOME has the panel, so it has no bar', (tester) async {
      await pumpBar(tester, [
        answering([agent('claude', 'working')]),
      ], tab: 0);

      expect(find.byKey(const ValueKey('agent-status')), findsNothing);
    });

    testWidgets('a quiet night leaves no bar at all', (tester) async {
      await pumpBar(tester, [
        answering([agent('claude', 'idle'), agent('codex', 'idle')]),
      ]);

      // Height is the scarce thing on this window, and a row reporting that
      // there is nothing to report is the row the reader stops seeing.
      expect(find.byKey(const ValueKey('agent-status')), findsNothing);
    });

    testWidgets('work that finished unwatched stands it up', (tester) async {
      await pumpBar(tester, [
        answering([agent('claude', 'done')]),
      ]);

      // Nothing is running, so the shade's tally is empty and the corner window
      // is disarmed. An agent that finished at three in the morning is still
      // the thing the phone is picked up to find out.
      expect(line(tester), '1 DONE');
    });

    testWidgets('no host registered is not a bar', (tester) async {
      await pumpBar(tester, const []);

      expect(find.byKey(const ValueKey('agent-status')), findsNothing);
    });
  });

  group('a host that stopped answering', () {
    testWidgets('says so beside the hosts that did', (tester) async {
      await pumpBar(tester, [
        const HostOutcome(host: nyx, kind: AgentOutcomeKind.unreachable),
        answering([agent('claude', 'working')], on: rose),
      ]);

      // The shade drops its tally under a failure because the count it could
      // draw came off the host that went away. This count is taken over the
      // hosts that answered, so both are true at once and the bar has the width
      // to say both.
      expect(line(tester), 'NYX UNREACHABLE · 1 WORKING');
    });

    testWidgets('is not counted from the agents it left behind', (
      tester,
    ) async {
      await pumpBar(tester, [
        HostOutcome(
          host: nyx,
          kind: AgentOutcomeKind.unreachable,
          // The watcher sends the last agents a host was seen with so that a
          // blink does not empty the panel. Counting those is counting work the
          // app has lost sight of.
          agents: [agent('claude', 'working'), agent('codex', 'blocked')],
        ),
      ]);

      expect(line(tester), 'NYX UNREACHABLE');
    });

    testWidgets('one line names one of them and counts the rest', (
      tester,
    ) async {
      await pumpBar(tester, const [
        HostOutcome(host: nyx, kind: AgentOutcomeKind.unreachable),
        HostOutcome(host: rose, kind: AgentOutcomeKind.keyRejected),
      ]);

      expect(line(tester), 'NYX UNREACHABLE +1');
    });
  });

  group('the mark', () {
    testWidgets('is the plain one while the work is only running', (
      tester,
    ) async {
      await pumpBar(tester, [
        answering([agent('claude', 'working')]),
      ]);

      expect(mark(tester), SpectacleColors.textPrimary);
    });

    testWidgets('warns when a host has stopped answering', (tester) async {
      await pumpBar(tester, [
        const HostOutcome(host: nyx, kind: AgentOutcomeKind.unreachable),
        answering([agent('claude', 'working')], on: rose),
      ]);

      expect(mark(tester), SpectacleColors.warning);
    });

    testWidgets('goes to blocked over a host being down', (tester) async {
      await pumpBar(tester, [
        const HostOutcome(host: nyx, kind: AgentOutcomeKind.unreachable),
        answering([agent('claude', 'blocked')], on: rose),
      ]);

      // A machine nobody can reach is the app failing to look, and an agent
      // stopped at a question is the user being waited on.
      expect(mark(tester), SpectacleColors.accent);
    });

    testWidgets('grows by what the line beside it grew by', (tester) async {
      Future<double> mark(TextScaler? scaler) async {
        await pumpBar(tester, [
          answering([agent('claude', 'working')]),
        ], scaler: scaler);
        return tester
            .getSize(find.byKey(const ValueKey('agent-status-mark')))
            .height;
      }

      expect(await mark(null), agentStatusMarkSize);

      // A phone does not raise every size by the same factor. Held at the size
      // it was drawn at, the block shrank against its own text until it read as
      // a speck of dust on the bar.
      expect(await mark(const _SystemCurve()), agentStatusMarkSize * 2);
    });
  });

  testWidgets('the bar leads to the panel', (tester) async {
    late ProviderContainer container;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          navIndexProvider.overrideWith((ref) => 3),
          agentsFeedProvider.overrideWith(
            (ref) => Stream.value(
              AgentPanelState([
                answering([agent('claude', 'blocked')]),
              ]),
            ),
          ),
        ],
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Consumer(
            builder: (context, ref, _) {
              container = ProviderScope.containerOf(context);
              return const AgentStatusBar();
            },
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('agent-status')));
    await tester.pump();

    // The count is not the answer: a blocked agent is answered in the pane it
    // is blocked in, and the panel is the door to it.
    expect(container.read(navIndexProvider), 0);
  });
}
