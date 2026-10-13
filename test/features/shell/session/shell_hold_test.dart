import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/features/shell/session/shell_hold.dart';
import 'package:upgrade/features/shell/session/shell_sessions.dart';
import 'package:upgrade/platform/shell/shell_connection.dart';

import '../../../support/fake_shell.dart';
import '../../../support/reasons.dart';

const _rose = Host(
  id: 'h1',
  name: 'rose',
  address: '100.64.0.1',
  port: 22,
  user: 'luis',
  keyId: 'key-1',
);

const _fig = Host(
  id: 'h2',
  name: 'fig',
  address: '100.64.0.2',
  port: 22,
  user: 'luis',
  keyId: 'key-1',
);

Future<void> _pumpDial(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

({FakeShellTransport transport, ShellSessions sessions, List<int> told})
_setUp() {
  final transport = FakeShellTransport();
  final sessions = fakeShellSessions(transport);
  final told = <int>[];
  final hold = ShellHold(sessions, (count) async => told.add(count));
  addTearDown(hold.dispose);
  return (transport: transport, sessions: sessions, told: told);
}

void main() {
  testWidgets('a live plain SSH tab is held and a Mosh one is not', (
    tester,
  ) async {
    final (:transport, :sessions, :told) = _setUp();

    sessions.open(_rose, intent: testIntent());
    await _pumpDial(tester);
    transport.transport = ShellTransport.mosh;
    sessions.open(_fig, intent: testIntent());
    await _pumpDial(tester);

    expect(told, [0, 1]);
  });

  testWidgets('a tab between dials keeps its hold until it lands elsewhere', (
    tester,
  ) async {
    final (:transport, :sessions, :told) = _setUp();
    final session = sessions.open(_rose, intent: testIntent())!;
    await _pumpDial(tester);

    transport.stall = true;
    transport.opened.single.drop();
    await tester.pump(shellReconnectDelays.first);
    await _pumpDial(tester);
    expect(transport.reasons, hasLength(2));
    expect(session.connection, isNull);
    expect(told, [0, 1]);

    transport
      ..transport = ShellTransport.mosh
      ..land();
    await _pumpDial(tester);

    expect(session.state, isA<ShellLive>());
    expect(told, [0, 1, 0]);
  });

  testWidgets('an exited tab lets go while it stays on screen', (tester) async {
    final (:transport, :sessions, :told) = _setUp();
    final session = sessions.open(_rose, intent: testIntent())!;
    await _pumpDial(tester);

    transport.opened.single.exit(1);
    await _pumpDial(tester);

    expect(session.state, isA<ShellExited>());
    expect(sessions.forHost(_rose.id), [session]);
    expect(told, [0, 1, 0]);
  });

  testWidgets('a closed tab lets go', (tester) async {
    final (:transport, :sessions, :told) = _setUp();
    final first = sessions.open(_rose, intent: testIntent())!;
    sessions.open(_rose, intent: testIntent());
    await _pumpDial(tester);
    expect(told.last, 2);

    await sessions.close(_rose.id, first, intent: testIntent());
    await _pumpDial(tester);

    expect(told.last, 1);
  });

  testWidgets('a refresh tells the same count again', (tester) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    final told = <int>[];
    final hold = ShellHold(sessions, (count) async => told.add(count));
    addTearDown(hold.dispose);
    sessions.open(_rose, intent: testIntent());
    await _pumpDial(tester);

    hold.refresh();

    expect(told, [0, 1, 1]);
  });
}
