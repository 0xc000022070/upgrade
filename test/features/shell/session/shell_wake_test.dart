import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/application/agents/agents.dart';
import 'package:upgrade/features/shell/session/shell_sessions.dart';
import 'package:upgrade/features/shell/session/shell_wake.dart';
import 'package:upgrade/platform/ssh/host_keys.dart';
import 'package:upgrade/platform/ssh/host_links.dart';
import 'package:upgrade/platform/shell/shell_connection.dart';

import '../../../support/fake_shell.dart';
import '../../../support/host_links.dart';
import '../../../support/platform_channels.dart';
import '../../../support/reasons.dart';
import '../../../support/shell_route.dart';
import '../../../support/themed_app.dart';

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
  final session = sessions.open(intent: testIntent(), rose)!;
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

Future<ShellSession> _live(WidgetTester tester, ShellSessions sessions) async {
  final session = sessions.open(intent: testIntent(), rose)!;
  await tester.pump();
  await tester.pump();
  expect(session.state, isA<ShellLive>());
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

    // A handover straight from wifi to cell is an arrival: the socket on the old network is
    // dead whether or not the phone was ever without one.
    await pushNetwork(true);
    await tester.pump();
    await tester.pump();

    expect(transport.verifiers, hasLength(spent + 1));
    expect(session.state, isA<ShellLive>());

    await sessions.close(intent: testIntent(), rose.id, session);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a network arriving ends a silent link no tab holds', (
    tester,
  ) async {
    final dial = FakeDial();
    final links = HostLinks(dial: dial.call);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          shellSessionsProvider.overrideWithValue(
            fakeShellSessions(FakeShellTransport()),
          ),
          hostLinksProvider.overrideWithValue(links),
        ],
        child: const ShellWakeHost(child: SizedBox.shrink()),
      ),
    );
    final held = await links.lease(
      address: '10.0.0.2',
      port: 22,
      user: 'dev',
      privateKey: 'key',
      verifier: HostKeyVerifier.pinnedOnly(
        PinnedHostKey(
          type: 'ssh-ed25519',
          fingerprint: 'SHA256:vm',
          pinnedAt: DateTime(2026),
        ),
      ),
      use: HostUse.send,
    );
    dial.clients.single.pong = Completer();

    await pushNetwork(true);
    await tester.pump();
    await tester.pump(links.answer);

    expect(held.closed, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    links.close();
  });

  testWidgets('a network going dials nothing', (tester) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(_host(sessions));

    final session = await _waiting(tester, transport, sessions);
    transport.refuse = null;
    final spent = transport.verifiers.length;

    await pushNetwork(false);
    await tester.pump();
    await tester.pump();

    expect(transport.verifiers, hasLength(spent));
    expect(session.state, isA<ShellWaiting>());

    await sessions.close(intent: testIntent(), rose.id, session);
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

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();

    expect(transport.verifiers, hasLength(spent + 1));
    expect(session.state, isA<ShellLive>());

    await sessions.close(intent: testIntent(), rose.id, session);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the shade pulled down over a live tab rehomes nothing', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(_host(sessions));

    final session = await _live(tester, sessions);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();

    expect(transport.opened.single.rehomes, 0);
    expect(session.state, isA<ShellLive>());

    await sessions.close(intent: testIntent(), rose.id, session);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the app coming back from a pocket rehomes a live tab', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(_host(sessions));

    final session = await _live(tester, sessions);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();

    expect(transport.opened.single.rehomes, 1);
    expect(transport.opened.single.networkRehomes, 0);

    await sessions.close(intent: testIntent(), rose.id, session);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the shade pulled down still dials a waiting tab', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(_host(sessions));

    final session = await _waiting(tester, transport, sessions);
    transport.refuse = null;
    final spent = transport.verifiers.length;

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();

    expect(transport.verifiers, hasLength(spent + 1));
    expect(session.state, isA<ShellLive>());

    await sessions.close(intent: testIntent(), rose.id, session);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a network arriving and the resume behind it rehome once', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(_host(sessions));

    final session = await _live(tester, sessions);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    await pushNetwork(true);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();

    expect(transport.opened.single.rehomes, 1);
    expect(transport.opened.single.networkRehomes, 1);

    await sessions.close(intent: testIntent(), rose.id, session);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
