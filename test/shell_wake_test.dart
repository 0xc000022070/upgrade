/// The two moments the phone dials a waiting shell again: the app coming back
/// in front, and a network arriving under it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/features/shell/shell_sessions.dart';
import 'package:dazzle/features/shell/shell_wake.dart';
import 'package:dazzle/platform/shell/shell_connection.dart';

import 'support/fake_shell.dart';
import 'support/platform_channels.dart';
import 'support/shell_route.dart';
import 'support/themed_app.dart';

Widget _host(ShellSessions sessions) => ProviderScope(
  overrides: [shellSessionsProvider.overrideWithValue(sessions)],
  child: ShellWakeHost(
    child: MaterialApp(
      theme: testTheme,
      home: Scaffold(body: SizedBox.shrink()),
    ),
  ),
);

/// A tab whose whole schedule ran out with nothing answering.
Future<ShellSession> _waiting(
  WidgetTester tester,
  FakeShellTransport transport,
  ShellSessions sessions,
) async {
  final session = sessions.open(rose)!;
  await tester.pump();
  await tester.pump();
  transport.refuse = const ShellFailure(ShellFailureKind.unreachable);
  transport.opened.single.drop();
  await tester.pump();
  for (final delay in shellReconnectDelays) {
    await tester.pump(delay);
    await tester.pump();
    await tester.pump();
  }
  expect(session.state, isA<ShellWaiting>());
  return session;
}

void main() {
  setUp(stubDeviceChannels);

  testWidgets('a network arriving dials a waiting tab', (tester) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(_host(sessions));

    final session = await _waiting(tester, transport, sessions);
    transport.refuse = null;
    final spent = transport.verifiers.length;

    // A handover straight from wifi to cell is an arrival: the socket on the
    // old network is dead whether or not the phone was ever without one.
    await pushNetwork(true);
    await tester.pump();
    await tester.pump();

    expect(transport.verifiers, hasLength(spent + 1));
    expect(session.state, isA<ShellLive>());

    await sessions.close(rose.id, session);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a network going dials nothing', (tester) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(_host(sessions));

    final session = await _waiting(tester, transport, sessions);
    transport.refuse = null;
    final spent = transport.verifiers.length;

    // The loss is what put the tab where it is. Dialling over nothing would
    // spend the fresh schedule for nothing.
    await pushNetwork(false);
    await tester.pump();
    await tester.pump();

    expect(transport.verifiers, hasLength(spent));
    expect(session.state, isA<ShellWaiting>());

    await sessions.close(rose.id, session);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the app coming back in front dials a waiting tab', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(_host(sessions));

    final session = await _waiting(tester, transport, sessions);
    transport.refuse = null;
    final spent = transport.verifiers.length;

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(transport.verifiers, hasLength(spent));

    // The phone in a pocket is where the schedule was spent, so this is the
    // first moment anybody is looking at the tab again.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();

    expect(transport.verifiers, hasLength(spent + 1));
    expect(session.state, isA<ShellLive>());

    await sessions.close(rose.id, session);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
