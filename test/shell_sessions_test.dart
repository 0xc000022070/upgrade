import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotline/data/repositories/host_repository.dart';
import 'package:hotline/data/repositories/shell_tab_repository.dart';
import 'package:hotline/features/shell/host_shell_screen.dart';
import 'package:hotline/features/shell/shell_sessions.dart';
import 'package:hotline/platform/shell/shell_connection.dart';
import 'package:hotline/platform/vnc/keysyms.dart';

import 'support/fake_shell.dart';

const _rose = Host(
  id: 'h1',
  name: 'rose',
  address: '100.64.0.1',
  port: 22,
  user: 'luis',
  keyId: 'key-1',
);

const _nyx = Host(
  id: 'h2',
  name: 'nyx',
  address: '100.64.0.2',
  port: 357,
  user: 'luis',
  keyId: 'key-1',
);

/// The store dials on a microtask, so every assertion about a connection has
/// to let those run first.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

/// The store's own clock is the test binding's inside [testWidgets], so a
/// reconnect's wait is advanced by pumping rather than waited out.
Future<void> _pumpDial(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

void main() {
  test('numbers run from one in open order and are never reused', () async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);

    final first = sessions.open(_rose)!;
    final second = sessions.open(_rose)!;
    final third = sessions.open(_rose)!;
    expect([first.number, second.number, third.number], [1, 2, 3]);

    await _settle();
    await sessions.close(_rose.id, second);
    final fourth = sessions.open(_rose)!;

    // The gap stays a gap: `2` is spent for this visit.
    expect(fourth.number, 4);
    expect(sessions.forHost(_rose.id).map((session) => session.number), [
      1,
      3,
      4,
    ]);
  });

  test('the ninth session is the last one a host can open', () async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);

    for (var i = 0; i < 9; i++) {
      expect(sessions.open(_rose), isNotNull);
    }
    expect(sessions.canOpen(_rose.id), isFalse);
    expect(sessions.open(_rose), isNull);
    expect(sessions.forHost(_rose.id), hasLength(9));
    await _settle();
  });

  test('closing drops exactly one session and closes its connection', () async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);

    final first = sessions.open(_rose)!;
    final second = sessions.open(_rose)!;
    await _settle();

    await sessions.close(_rose.id, first);

    expect(sessions.forHost(_rose.id), [second]);
    expect(transport.opened.first.closed, isTrue);
    expect(transport.opened.last.closed, isFalse);
  });

  testWidgets('a reconnect reopens in the slot the session already holds', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    final session = sessions.open(_rose)!;
    await _pumpDial(tester);

    // What the dead shell printed stays on screen, so the terminal is the same
    // object after the reconnect as before it.
    final terminal = session.terminal;
    transport.opened.single.drop();
    await tester.pump();
    await tester.pump(shellReconnectDelays.first);
    await _pumpDial(tester);

    expect(sessions.forHost(_rose.id), [session]);
    expect(session.number, 1);
    expect(session.terminal, same(terminal));
    expect(session.state, isA<ShellLive>());

    await sessions.close(_rose.id, session);
  });

  test('bytes flow both ways through the connection', () async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);

    final session = sessions.open(_rose)!;
    await _settle();
    final connection = transport.opened.single;

    connection.emit('hotline');
    await _settle();
    expect(session.terminal.buffer.getText(), contains('hotline'));

    sessions.send(session, Uint8List.fromList([0x03]));
    expect(connection.writes.single, [0x03]);
  });

  test('a character split across two reads survives the boundary', () async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);

    final session = sessions.open(_rose)!;
    await _settle();
    final connection = transport.opened.single;

    // The two bytes of `ñ`, arriving as two reads the way a busy channel
    // delivers them.
    connection.emitBytes([0xC3]);
    await _settle();
    connection.emitBytes([0xB1]);
    await _settle();

    expect(session.terminal.buffer.getText(), contains('ñ'));
  });

  test('an armed modifier reaches what the keyboard types, once', () async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);

    final session = sessions.open(_rose)!;
    await _settle();
    final connection = transport.opened.single;

    sessions.arm(session, {StickyModifier.ctrl});
    // What the soft keyboard puts in, which never passes through the bar.
    session.terminal.textInput('c');

    expect(connection.writes.single, [0x03]);
    expect(session.sticky, isEmpty);

    session.terminal.textInput('c');
    expect(connection.writes.last, [0x63]);
  });

  test(
    'the return the keyboard inserts goes out as a carriage return',
    () async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);

      final session = sessions.open(_rose)!;
      await _settle();

      session.terminal.textInput('ls\n');

      expect(transport.opened.single.written, 'ls\r');
    },
  );

  test('a paste goes out whole, with its line breaks as returns', () async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);

    final session = sessions.open(_rose)!;
    await _settle();

    session.terminal.paste('uname -a\n');

    expect(transport.opened.single.written, 'uname -a\r');
  });

  test('what the shell calls itself becomes the session title', () async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);

    final session = sessions.open(_rose)!;
    await _settle();
    expect(session.title, isNull);

    transport.opened.single.emit('\x1b]0;luis@nyx: ~\x07');
    await _settle();

    expect(session.title, 'luis@nyx: ~');
  });

  testWidgets('a reconnected session starts without the last one\'s title or '
      'keys', (tester) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    final session = sessions.open(_rose)!;
    await _pumpDial(tester);
    transport.opened.single.emit('\x1b]0;luis@nyx: ~\x07');
    await _pumpDial(tester);
    sessions.arm(session, {StickyModifier.ctrl});

    transport.opened.single.drop();
    await tester.pump();
    await tester.pump(shellReconnectDelays.first);
    await _pumpDial(tester);

    expect(session.title, isNull);
    expect(session.sticky, isEmpty);

    await sessions.close(_rose.id, session);
  });

  test('a resize is forwarded once per size', () async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);

    final session = sessions.open(_rose)!;
    await _settle();
    final connection = transport.opened.single;

    session.terminal.resize(100, 40);
    session.terminal.resize(100, 40);
    session.terminal.resize(120, 40);

    expect(connection.resizes, [
      [100, 40],
      [120, 40],
    ]);
  });

  test('the exit code becomes the exited state', () async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);

    final session = sessions.open(_rose)!;
    await _settle();
    expect(session.state, isA<ShellLive>());

    transport.opened.single.exit(130);
    await _settle();

    expect(session.state, isA<ShellExited>());
    expect((session.state as ShellExited).code, 130);
  });

  test('a missing key is a rejected key and nothing is dialled', () async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport, privateKey: null);

    final session = sessions.open(_rose)!;
    await _settle();

    expect(session.state, isA<ShellFailed>());
    expect((session.state as ShellFailed).kind, ShellFailureKind.keyRejected);
    expect(transport.opened, isEmpty);
    expect(transport.sizes, isEmpty);
  });

  test('every failure carries the reason line the header draws', () {
    expect(
      shellReason(ShellFailureKind.unreachable, 'ROSE'),
      'rose unreachable',
    );
    expect(shellReason(ShellFailureKind.unresolved, 'ROSE'), 'rose unresolved');
    expect(shellReason(ShellFailureKind.keyRejected, 'ROSE'), 'key rejected');
    expect(shellReason(ShellFailureKind.shellRefused, 'ROSE'), 'shell refused');
    expect(shellReason(ShellFailureKind.streamClosed, 'ROSE'), 'stream closed');
  });

  testWidgets('the store keeps its sessions across a route dispose', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [shellSessionsProvider.overrideWithValue(sessions)],
        child: const MaterialApp(home: HostShellRoute(host: _rose)),
      ),
    );
    await tester.pump();
    expect(sessions.forHost(_rose.id), hasLength(1));

    // Leaving the route, which is the thing that must not take the shell down.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    expect(sessions.forHost(_rose.id), hasLength(1));
    expect(transport.opened.single.closed, isFalse);
  });

  testWidgets('a live shell that loses its link is dialled again', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    final session = sessions.open(_rose)!;
    await _pumpDial(tester);
    expect(session.state, isA<ShellLive>());

    transport.opened.single.drop();
    await tester.pump();

    // The dial does not go out until the first wait is up.
    expect(session.state, isA<ShellDropped>());
    expect((session.state as ShellDropped).attempt, 1);
    expect(transport.opened, hasLength(1));

    await tester.pump(shellReconnectDelays.first);
    await _pumpDial(tester);

    expect(session.state, isA<ShellLive>());
    expect(transport.opened, hasLength(2));
    // The scrollback the dead shell left, then the mark, then the new one.
    expect(session.terminal.buffer.getText(), contains('-- reconnected --'));
    // Nothing on a timer asks about a host key: the schedule runs with nobody
    // looking at the route.
    expect(transport.verifiers.last?.prompt, isNull);

    await sessions.close(_rose.id, session);
  });

  testWidgets('a first dial that never lands is waited out too', (
    tester,
  ) async {
    final transport = FakeShellTransport()
      ..refuse = const ShellFailure(ShellFailureKind.unreachable);
    final sessions = fakeShellSessions(transport);
    final session = sessions.open(_rose)!;
    await _pumpDial(tester);

    // Opening a tab on a host the phone cannot reach yet is the same problem
    // as losing one mid-session, and it is the app that dials again.
    expect(session.state, isA<ShellDropped>());

    transport.refuse = null;
    await tester.pump(shellReconnectDelays.first);
    await _pumpDial(tester);

    expect(session.state, isA<ShellLive>());
    expect(transport.opened, hasLength(1));

    await sessions.close(_rose.id, session);
  });

  testWidgets('six waits and then the session gives up', (tester) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    final session = sessions.open(_rose)!;
    await _pumpDial(tester);

    transport.refuse = const ShellFailure(ShellFailureKind.unreachable);
    transport.opened.single.drop();
    await tester.pump();

    for (final delay in shellReconnectDelays) {
      expect(session.state, isA<ShellDropped>());
      await tester.pump(delay);
      await _pumpDial(tester);
    }

    // Six dials after the first, and the reason row once the last one is
    // spent — carrying what the last dial actually hit, not the drop that
    // started the schedule.
    expect(transport.verifiers, hasLength(1 + shellReconnectDelays.length));
    expect(session.state, isA<ShellFailed>());
    expect((session.state as ShellFailed).kind, ShellFailureKind.unreachable);

    await sessions.close(_rose.id, session);
  });

  testWidgets('a key the host refuses stops the schedule at once', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    final session = sessions.open(_rose)!;
    await _pumpDial(tester);

    transport.refuse = const ShellFailure(ShellFailureKind.hostKeyUnverified);
    transport.opened.single.drop();
    await tester.pump();
    await tester.pump(shellReconnectDelays.first);
    await _pumpDial(tester);

    // An answer, not an accident: dialling again would only get the same one.
    expect(session.state, isA<ShellFailed>());
    expect(
      (session.state as ShellFailed).kind,
      ShellFailureKind.hostKeyUnverified,
    );

    await sessions.close(_rose.id, session);
  });

  testWidgets('a shell the user exited is not reconnected', (tester) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    final session = sessions.open(_rose)!;
    await _pumpDial(tester);

    transport.opened.single.exit(0);
    await _pumpDial(tester);
    await tester.pump(const Duration(minutes: 1));

    expect(session.state, isA<ShellExited>());
    expect(transport.opened, hasLength(1));

    await sessions.close(_rose.id, session);
  });

  testWidgets('STOP parks the session where the schedule was', (tester) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    final session = sessions.open(_rose)!;
    await _pumpDial(tester);

    transport.opened.single.drop();
    await tester.pump();
    sessions.stopReconnect(session);
    await tester.pump(const Duration(minutes: 1));

    expect(session.state, isA<ShellFailed>());
    expect(transport.opened, hasLength(1));

    await sessions.close(_rose.id, session);
  });

  testWidgets('closing the tab takes the schedule with it', (tester) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    final session = sessions.open(_rose)!;
    await _pumpDial(tester);

    transport.opened.single.drop();
    await tester.pump();
    await sessions.close(_rose.id, session);
    await tester.pump(const Duration(minutes: 1));

    expect(transport.opened, hasLength(1));
  });

  group('tabs that outlive the process', () {
    Future<List<Host>> hosts() async => [_rose, _nyx];

    test('an open tab is written down and a closed one is taken out', () async {
      final tabs = InMemoryShellTabRepository();
      final sessions = fakeShellSessions(FakeShellTransport(), tabs: tabs);

      sessions.open(_rose);
      final second = sessions.open(_rose)!;
      await _settle();
      expect((await tabs.all()).map((tab) => tab.number), [1, 2]);

      await sessions.close(_rose.id, second);
      await _settle();
      expect((await tabs.all()).map((tab) => tab.number), [1]);
    });

    test('the table follows the tab the user is looking at', () async {
      final tabs = InMemoryShellTabRepository();
      final sessions = fakeShellSessions(FakeShellTransport(), tabs: tabs);

      final first = sessions.open(_rose)!;
      final second = sessions.open(_rose)!;
      await _settle();
      expect((await tabs.all()).map((tab) => [tab.number, tab.active]), [
        [1, false],
        [2, true],
      ]);

      sessions.activate(_rose.id, first);
      await _settle();
      expect((await tabs.all()).map((tab) => [tab.number, tab.active]), [
        [1, true],
        [2, false],
      ]);

      // The tab the user was on closing moves the flag with the route.
      await sessions.close(_rose.id, first);
      await _settle();
      expect((await tabs.all()).single.active, isTrue);
      expect(second.number, 2);
    });

    test('a killed app comes back on the tabs it had', () async {
      final tabs = InMemoryShellTabRepository();
      final before = fakeShellSessions(FakeShellTransport(), tabs: tabs);
      before.open(_rose);
      before.open(_rose);
      before.open(_nyx);
      before.activate(_rose.id, before.forHost(_rose.id).first);
      await _settle();

      // A second store over the same table is what the next process is: the
      // connections are gone, the rows are not.
      final transport = FakeShellTransport();
      final after = fakeShellSessions(transport, tabs: tabs);
      expect(await after.restore(hosts), 3);

      expect(after.forHost(_rose.id).map((session) => session.number), [1, 2]);
      expect(after.forHost(_nyx.id).map((session) => session.number), [1]);
      // Each restored tab is a fresh shell on the host it was on.
      await _settle();
      expect(transport.opened, hasLength(3));
      // And the tab the user left in front is the one that comes back in front.
      expect(after.activeFor(_rose.id)!.number, 1);
    });

    test('numbering carries on past the tabs that came back', () async {
      final tabs = InMemoryShellTabRepository();
      final before = fakeShellSessions(FakeShellTransport(), tabs: tabs);
      before.open(_rose);
      final second = before.open(_rose)!;
      before.open(_rose);
      await _settle();
      await before.close(_rose.id, second);
      await _settle();

      final after = fakeShellSessions(FakeShellTransport(), tabs: tabs);
      await after.restore(hosts);

      expect(after.open(_rose)!.number, 4);
      await _settle();
    });

    test('a tab on a host that was deleted is dropped, not dialled', () async {
      final tabs = InMemoryShellTabRepository();
      await tabs.open('gone', 1);
      await tabs.open(_rose.id, 1);

      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport, tabs: tabs);
      expect(await sessions.restore(hosts), 1);
      await _settle();

      expect(sessions.forHost('gone'), isEmpty);
      expect(transport.opened, hasLength(1));
      expect((await tabs.all()).map((tab) => tab.hostId), [_rose.id]);
    });

    test('restore runs once however often it is called', () async {
      final tabs = InMemoryShellTabRepository();
      await tabs.open(_rose.id, 1);

      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport, tabs: tabs);
      expect(await sessions.restore(hosts), 1);
      expect(await sessions.restore(hosts), 0);
      await _settle();

      expect(sessions.forHost(_rose.id), hasLength(1));
      expect(transport.opened, hasLength(1));
    });

    test('a restored tab dials unattended', () async {
      final tabs = InMemoryShellTabRepository();
      await tabs.open(_rose.id, 1);

      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport, tabs: tabs);
      await sessions.restore(hosts);
      await _settle();

      // No prompt, so a host whose key was never pinned is refused here rather
      // than asking a user who is still on the boot log.
      expect(transport.verifiers.single!.prompt, isNull);
    });
  });
}
