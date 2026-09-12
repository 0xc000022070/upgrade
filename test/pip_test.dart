import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spectacle/application/agent_state.dart';
import 'package:spectacle/application/agents.dart';
import 'package:spectacle/application/pip.dart';
import 'package:spectacle/app/pip_host.dart';
import 'package:spectacle/data/repositories/host_repository.dart';
import 'package:spectacle/features/agents/pip_panel.dart';
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

AgentPanelState panel(List<AgentSnapshot> agents, {Host on = nyx}) =>
    AgentPanelState([
      HostOutcome(host: on, kind: AgentOutcomeKind.snapshot, agents: agents),
    ]);

/// A window that records what it was told rather than asking an activity.
class FakePip implements PipSurface {
  FakePip({this.here = true});

  final bool here;
  final armings = <bool>[];
  final modes = StreamController<bool>.broadcast();

  @override
  Future<bool> available() async => here;

  @override
  Future<void> arm(bool armed) async => armings.add(armed);

  @override
  Stream<bool> mode() => modes.stream;
}

Widget harness(FakePip pip, Stream<AgentPanelState> agents, Widget child) =>
    ProviderScope(
      overrides: [
        pipSurfaceProvider.overrideWithValue(pip),
        agentsFeedProvider.overrideWith((ref) => agents),
      ],
      child: Directionality(textDirection: TextDirection.ltr, child: child),
    );

void main() {
  group('the window is armed by what is happening', () {
    testWidgets('nothing active leaves it disarmed', (tester) async {
      final pip = FakePip();
      await tester.pumpWidget(
        harness(
          pip,
          Stream.value(
            panel([agent('claude', 'done'), agent('codex', 'idle')]),
          ),
          const PipHost(child: SizedBox()),
        ),
      );
      await tester.pump();

      expect(pip.armings, [false]);
    });

    testWidgets('an agent at work arms it', (tester) async {
      final pip = FakePip();
      final feed = StreamController<AgentPanelState>();
      await tester.pumpWidget(
        harness(pip, feed.stream, const PipHost(child: SizedBox())),
      );
      feed.add(panel([agent('claude', 'working')]));
      await tester.pumpAndSettle();

      expect(pip.armings.last, isTrue);

      // And it is disarmed again the moment the work is over, so a trip to the
      // browser on a quiet night leaves nothing in the corner.
      feed.add(panel([agent('claude', 'done')]));
      await tester.pumpAndSettle();

      expect(pip.armings.last, isFalse);
    });

    testWidgets('a host the app has lost does not keep it armed', (
      tester,
    ) async {
      final pip = FakePip();
      final feed = StreamController<AgentPanelState>();
      await tester.pumpWidget(
        harness(pip, feed.stream, const PipHost(child: SizedBox())),
      );
      feed.add(panel([agent('claude', 'working')]));
      await tester.pumpAndSettle();

      expect(pip.armings.last, isTrue);

      // A failure carries the last agents its host was seen with, so that a
      // blink does not empty the panel. Armed off those, the window stayed up
      // over a machine that had simply been switched off for the night, and
      // nothing could bring it back down: the count only empties on a snapshot,
      // and the host that would send one is gone.
      feed.add(
        AgentPanelState([
          HostOutcome(
            host: nyx,
            kind: AgentOutcomeKind.unreachable,
            agents: [agent('claude', 'working')],
          ),
        ]),
      );
      await tester.pumpAndSettle();

      expect(pip.armings.last, isFalse);

      // What is asked is which agents the app can see, not whether anything
      // failed: another host still answering with work on it arms the window
      // while the first one is still down.
      feed.add(
        AgentPanelState([
          const HostOutcome(host: nyx, kind: AgentOutcomeKind.unreachable),
          HostOutcome(
            host: rose,
            kind: AgentOutcomeKind.snapshot,
            agents: [agent('amp', 'working')],
          ),
        ]),
      );
      await tester.pumpAndSettle();

      expect(pip.armings.last, isTrue);
    });

    testWidgets('a device without the window is never armed', (tester) async {
      final pip = FakePip(here: false);
      await tester.pumpWidget(
        harness(
          pip,
          Stream.value(panel([agent('claude', 'blocked')])),
          const PipHost(child: SizedBox()),
        ),
      );
      await tester.pump();

      expect(pip.armings, everyElement(isFalse));
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

      final rows = tester
          .widgetList<Text>(find.byType(Text))
          .map((text) => text.data)
          .whereType<String>()
          .toList();
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
}
