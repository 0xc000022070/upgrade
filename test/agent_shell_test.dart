import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/application/agent_state.dart';
import 'package:dazzle/application/navigation.dart';
import 'package:dazzle/data/repositories/host_repository.dart';
import 'package:dazzle/features/agents/agent_shell.dart';
import 'package:dazzle/features/shell/shell_sessions.dart';
import 'package:dazzle/features/ssh/ssh_screen.dart';
import 'package:dazzle/platform/herdr_client.dart';
import 'package:dazzle/platform/shell/remote_shell.dart';

import 'support/fake_shell.dart';
import 'support/platform_channels.dart';

/// A tap on an agent row: the shell sheet on the agent's host, in the tab
/// attached to its pane, made once and found after that.

const _rose = Host(
  id: 'h1',
  name: 'rose',
  address: '100.64.0.1',
  port: 22,
  user: 'luis',
  keyId: 'key-1',
);

const _agent = AgentSnapshot(
  session: 'lab',
  paneId: 'w22:p1',
  agent: 'claude',
  state: WorkingState(),
  terminalTitleStripped: 'refactor',
  workspaceId: 'w22',
  cwd: '/home/luis/dazzle',
  stateChangeSeq: 4,
);

const _pane = (session: 'lab', pane: 'w22:p1');

const _attach =
    "env HERDR_SESSION='lab' herdr agent attach 'w22:p1' --takeover";

void main() {
  setUp(stubDeviceChannels);

  test("the attach line is the pane under the agent's own session", () {
    expect(HerdrCommands.attach(_pane), _attach);
    expect(_attach, isNot(contains('hub')));
    expect(
      HerdrCommands.attach((session: 'default', pane: 'w22:p1')),
      "env HERDR_SESSION='default' herdr agent attach 'w22:p1' --takeover",
    );
  });

  test('a pane or a session that is not one is refused before a line', () {
    expect(HerdrCommands.isPane(_pane), isTrue);
    expect(
      HerdrCommands.isPane((session: 'lab', pane: 'w22:p1; reboot')),
      isFalse,
    );
    expect(
      () => HerdrCommands.attach((session: 'lab', pane: 'w22:p1; reboot')),
      throwsA(isA<HerdrProtocolMismatch>()),
    );
    expect(
      () => HerdrCommands.attach((session: 'lab; reboot', pane: 'w22:p1')),
      throwsA(isA<HerdrProtocolMismatch>()),
    );
  });

  Widget app(ShellSessions sessions) => ProviderScope(
    overrides: [shellSessionsProvider.overrideWithValue(sessions)],
    child: const MaterialApp(home: _Launcher()),
  );

  Future<void> ready(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  final header = find.byKey(const ValueKey('shell-header'));

  testWidgets('a first tap opens a tab running the attach as its command', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions));
    final container = ProviderScope.containerOf(
      tester.element(find.text('OPEN')),
    );

    await tester.tap(find.text('OPEN'));
    await ready(tester);

    expect(header, findsOneWidget);
    expect(container.read(navIndexProvider), SshScreen.navIndex);
    final session = sessions.forHost(_rose.id).single;
    expect(session.pane, _pane);
    expect(session.command, _attach);
    // The channel's own command, and nothing typed at a shell: a line written
    // at a login shell races whatever that shell reads before its prompt.
    expect(transport.commands, [shellMarked(session.mark, command: _attach)]);
    expect(transport.opened.single.written, isEmpty);
    expect(
      transport.opened.single.execs.map((exec) => exec.command),
      everyElement(isNot(contains('agent attach'))),
    );

    await unmount(tester);
  });

  testWidgets('a second tap lands in the tab already attached', (tester) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions));

    await tester.tap(find.text('OPEN'));
    await ready(tester);
    final first = sessions.forHost(_rose.id).single;
    // A second tab on the host, so the tap has something to choose against.
    sessions.open(_rose);
    await ready(tester);
    expect(sessions.activeFor(_rose.id), isNot(same(first)));
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await ready(tester);
    expect(header, findsNothing);

    await tester.tap(find.text('OPEN'));
    await ready(tester);

    expect(header, findsOneWidget);
    expect(sessions.forHost(_rose.id), hasLength(2));
    expect(sessions.activeFor(_rose.id), same(first));
    expect(transport.opened, hasLength(2));

    await unmount(tester);
  });
}

class _Launcher extends ConsumerWidget {
  const _Launcher();

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    body: Center(
      child: TextButton(
        onPressed: () => openAgentShell(context, ref, _rose, _agent),
        child: const Text('OPEN'),
      ),
    ),
  );
}
