import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotline/data/repositories/host_repository.dart';
import 'package:hotline/design/colors.dart';
import 'package:hotline/design/icons/hotline_icon.dart';
import 'package:hotline/features/shell/host_shell_screen.dart';
import 'package:hotline/features/shell/shell_sessions.dart';
import 'package:hotline/platform/shell/shell_connection.dart';

import 'support/fake_shell.dart';
import 'support/platform_channels.dart';

const _rose = Host(
  id: 'h1',
  name: 'rose',
  address: '100.64.0.1',
  port: 22,
  user: 'luis',
  keyId: 'key-1',
);

void main() {
  setUp(stubDeviceChannels);

  Widget app(ShellSessions sessions, {Widget? home}) => ProviderScope(
    overrides: [shellSessionsProvider.overrideWithValue(sessions)],
    child: MaterialApp(home: home ?? const HostShellRoute(host: _rose)),
  );

  /// The store dials off a microtask and the panels decode their headers over
  /// a few frames, so nothing is on screen after a single pump.
  Future<void> ready(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// The route holds a terminal that never settles on its own, so the tree is
  /// taken down by hand rather than left mounted at the end of a test.
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  testWidgets('the header says CONNECTING until the shell answers', (
    tester,
  ) async {
    final transport = FakeShellTransport()..stall = true;
    await tester.pumpWidget(app(fakeShellSessions(transport)));
    await ready(tester);

    expect(find.text('/ ROSE SHELL'), findsOneWidget);
    expect(find.text('CONNECTING'), findsOneWidget);
    // Nothing to go back to yet, so no way back is offered.
    expect(find.text('RETRY'), findsNothing);

    await unmount(tester);
  });

  testWidgets('a live session says nothing on the right', (tester) async {
    final transport = FakeShellTransport();
    await tester.pumpWidget(app(fakeShellSessions(transport)));
    await ready(tester);

    expect(find.text('/ ROSE SHELL'), findsOneWidget);
    expect(find.text('CONNECTING'), findsNothing);
    expect(find.text('RETRY'), findsNothing);

    await unmount(tester);
  });

  testWidgets('an exit becomes EXITED with the way back beside it', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    await tester.pumpWidget(app(fakeShellSessions(transport)));
    await ready(tester);

    transport.opened.single.exit(130);
    await ready(tester);

    expect(find.text('EXITED 130'), findsOneWidget);
    expect(find.text('RETRY'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('a refused shell draws its reason line', (tester) async {
    final transport = FakeShellTransport()
      ..refuse = const ShellFailure(ShellFailureKind.shellRefused);
    await tester.pumpWidget(app(fakeShellSessions(transport)));
    await ready(tester);

    expect(find.text('shell refused'), findsOneWidget);
    expect(find.text('RETRY'), findsOneWidget);

    // And the way back opens a fresh connection in the same tab.
    transport.refuse = null;
    await tester.tap(find.text('RETRY'));
    await ready(tester);

    expect(find.text('shell refused'), findsNothing);
    expect(find.byKey(const ValueKey('shell-tab-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('shell-tab-2')), findsNothing);

    await unmount(tester);
  });

  testWidgets('the plus opens a numbered tab and it becomes the active one', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions));
    await ready(tester);

    expect(find.byKey(const ValueKey('shell-tab-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('shell-tab-2')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('shell-tab-new')));
    await ready(tester);

    expect(find.byKey(const ValueKey('shell-tab-2')), findsOneWidget);
    expect(sessions.activeFor(_rose.id)?.number, 2);

    // And the first tab takes the user back to the shell it holds.
    await tester.tap(find.byKey(const ValueKey('shell-tab-1')));
    await ready(tester);
    expect(sessions.activeFor(_rose.id)?.number, 1);

    await unmount(tester);
  });

  testWidgets('the plus is gone once nine tabs are open', (tester) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    for (var i = 0; i < 9; i++) {
      sessions.open(_rose);
    }
    await tester.pumpWidget(app(sessions));
    await ready(tester);

    expect(find.byKey(const ValueKey('shell-tab-9')), findsOneWidget);
    expect(find.byKey(const ValueKey('shell-tab-new')), findsNothing);

    await unmount(tester);
  });

  testWidgets('closing a live session asks before it closes', (tester) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions));
    await ready(tester);
    await tester.tap(find.byKey(const ValueKey('shell-tab-new')));
    await ready(tester);

    await tester.tap(find.byKey(const ValueKey('shell-tab-close')));
    await ready(tester);

    expect(find.text('CLOSE SHELL 2?'), findsOneWidget);
    expect(sessions.forHost(_rose.id), hasLength(2));

    await tester.tap(find.text('CLOSE'));
    await ready(tester);

    expect(sessions.forHost(_rose.id), hasLength(1));
    expect(sessions.forHost(_rose.id).single.number, 1);

    await unmount(tester);
  });

  testWidgets('a session that already ended closes without asking', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions));
    await ready(tester);
    await tester.tap(find.byKey(const ValueKey('shell-tab-new')));
    await ready(tester);

    transport.opened.last.exit(0);
    await ready(tester);

    await tester.tap(find.byKey(const ValueKey('shell-tab-close')));
    await ready(tester);

    expect(find.text('CLOSE SHELL 2?'), findsNothing);
    expect(sessions.forHost(_rose.id), hasLength(1));

    await unmount(tester);
  });

  testWidgets('closing the last tab pops the route', (tester) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions, home: const _Launcher()));
    await tester.pump();

    await tester.tap(find.text('OPEN'));
    await ready(tester);
    expect(find.text('/ ROSE SHELL'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('shell-tab-close')));
    await ready(tester);
    await tester.tap(find.text('CLOSE'));
    await ready(tester);

    expect(sessions.forHost(_rose.id), isEmpty);
    expect(find.text('/ ROSE SHELL'), findsNothing);
    expect(find.text('OPEN'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('SUPER is drawn dim on the strip and does not arm', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    await tester.pumpWidget(app(fakeShellSessions(transport)));
    await ready(tester);

    await tester.tap(find.byKey(const ValueKey('rail-keys')));
    await ready(tester);

    Color tintOf(String label) => tester
        .widget<HotlineIcon>(
          find.descendant(
            of: find.byKey(ValueKey('key-$label')),
            matching: find.byType(HotlineIcon),
          ),
        )
        .color;

    expect(tintOf('SUPER'), HotlineColors.textMuted);
    await tester.tap(find.byKey(const ValueKey('key-SUPER')));
    await ready(tester);
    // An armed modifier goes accent. This one has nothing to arm for.
    expect(tintOf('SUPER'), HotlineColors.textMuted);

    await unmount(tester);
  });
}

/// A page to pop back to, so the last tab closing has somewhere to land.
class _Launcher extends StatelessWidget {
  const _Launcher();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: GestureDetector(
          onTap: () => openHostShell(context, _rose),
          child: const Text('OPEN'),
        ),
      ),
    );
  }
}
