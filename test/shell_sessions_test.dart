import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spectacle/data/repositories/host_repository.dart';
import 'package:spectacle/data/repositories/shell_tab_repository.dart';
import 'package:spectacle/features/shell/host_shell_screen.dart';
import 'package:spectacle/features/shell/shell_card.dart';
import 'package:spectacle/features/shell/shell_sessions.dart';
import 'package:spectacle/platform/shell/shell_connection.dart';
import 'package:spectacle/platform/vnc/keysyms.dart';
import 'package:xterm/xterm.dart';

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

  test('a seeded session types its line the moment the shell is up', () async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);

    final session = sessions.open(_rose, seed: "cd '/srv/gate'")!;
    await _settle();

    // With the return on it: a line the user has to press enter on themselves
    // is not a shell that opened where it was asked to.
    expect(transport.opened.single.written, "cd '/srv/gate'\r");
    // Spent once. A reconnect after the user has walked somewhere else must
    // not drag them back to where the workspace was.
    expect(session.seed, isNull);
  });

  test('an unseeded session writes nothing on its own', () async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);

    sessions.open(_rose);
    await _settle();

    expect(transport.opened.single.written, isEmpty);
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

    connection.emit('spectacle');
    await _settle();
    expect(session.terminal.buffer.getText(), contains('spectacle'));

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

  group('a modifier armed for more than one key', () {
    test('two keys go through it, and the third does not', () async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);

      final session = sessions.open(_rose)!;
      await _settle();
      final connection = transport.opened.single;

      sessions.arm(session, {StickyModifier.ctrl}, repeat: 2);
      session.terminal.textInput('d');
      expect(session.sticky, {StickyModifier.ctrl});
      expect(session.stickyRepeat, 1);

      session.terminal.textInput('d');
      expect(session.sticky, isEmpty);
      expect(session.stickyRepeat, 1);

      session.terminal.textInput('d');

      expect(connection.writes, [
        [0x04],
        [0x04],
        [0x64],
      ]);
    });

    test('a key off the bar spends one of the count too', () async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);

      final session = sessions.open(_rose)!;
      await _settle();

      sessions.arm(session, {StickyModifier.alt}, repeat: 2);
      // What the bar hands down, already mapped to bytes.
      sessions.send(session, Uint8List.fromList([0x1b, 0x5b, 0x41]));

      expect(session.sticky, {StickyModifier.alt});
      expect(session.stickyRepeat, 1);

      sessions.send(session, Uint8List.fromList([0x1b, 0x5b, 0x41]));
      expect(session.sticky, isEmpty);
    });

    test(
      'what the terminal answers on its own is not one of the keys',
      () async {
        final transport = FakeShellTransport();
        final sessions = fakeShellSessions(transport);

        final session = sessions.open(_rose)!;
        await _settle();
        final connection = transport.opened.single;

        sessions.arm(session, {StickyModifier.ctrl}, repeat: 2);
        // DSR 6, "where is the cursor": what an agent asks the terminal while
        // the user is deciding what to press.
        session.terminal.write('\x1b[6n');

        expect(session.sticky, {StickyModifier.ctrl});
        expect(session.stickyRepeat, 2);

        session.terminal.textInput('d');
        session.terminal.textInput('d');

        expect(connection.writes, [
          [0x1b, 0x5b, 0x30, 0x3b, 0x30, 0x52],
          [0x04],
          [0x04],
        ]);
      },
    );

    test('every query the terminal answers leaves the count alone', () async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);

      final session = sessions.open(_rose)!;
      await _settle();

      sessions.arm(session, {StickyModifier.ctrl}, repeat: 3);
      // Device attributes, operating status, cursor position, size: every
      // reply xterm makes without being typed at.
      for (final query in [
        '\x1b[c',
        '\x1b[>c',
        '\x1b[5n',
        '\x1b[6n',
        '\x1b[18t',
      ]) {
        session.terminal.write(query);
      }

      expect(session.stickyRepeat, 3);
      expect(session.sticky, {StickyModifier.ctrl});
    });

    test('ALT is not put in front of a reply', () async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);

      final session = sessions.open(_rose)!;
      await _settle();
      final connection = transport.opened.single;

      sessions.arm(session, {StickyModifier.alt}, repeat: 2);
      session.terminal.write('\x1b[6n');

      // The program asked where the cursor is; a meta prefix would make it
      // read the answer as something else entirely.
      expect(connection.writes, [
        [0x1b, 0x5b, 0x30, 0x3b, 0x30, 0x52],
      ]);
    });

    test('a mouse report is not one of the keys either', () async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);

      final session = sessions.open(_rose)!;
      await _settle();
      final connection = transport.opened.single;

      // Mouse reporting on, as an agent on the alternate screen leaves it.
      session.terminal.write('\x1b[?1000h');
      sessions.arm(session, {StickyModifier.ctrl}, repeat: 2);
      session.terminal.mouseInput(
        TerminalMouseButton.left,
        TerminalMouseButtonState.down,
        const CellOffset(0, 0),
      );

      expect(session.sticky, {StickyModifier.ctrl});
      expect(session.stickyRepeat, 2);
      expect(connection.writes, [
        [0x1b, 0x5b, 0x4d, 0x20, 0x21, 0x22],
      ]);
    });

    test('a paste is one key, however long it is', () async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);

      final session = sessions.open(_rose)!;
      await _settle();

      sessions.arm(session, {StickyModifier.ctrl}, repeat: 2);
      session.terminal.paste('abc');

      expect(session.stickyRepeat, 1);
      expect(session.sticky, {StickyModifier.ctrl});
    });

    test('every change to the count reaches whatever is drawing it', () async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);

      final session = sessions.open(_rose)!;
      await _settle();
      var notices = 0;
      // The tab's own notifier: the count is drawn by the bar under this
      // terminal and by nothing on the screen behind it.
      session.addListener(() => notices++);

      sessions.arm(session, {StickyModifier.ctrl}, repeat: 2);
      expect(notices, 1);
      session.terminal.textInput('d');
      expect(notices, 2);
      session.terminal.textInput('d');
      expect(notices, 3);
      // Nothing armed, nothing to redraw.
      session.terminal.textInput('d');
      expect(notices, 3);
    });

    test('an empty arming carries no count', () async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);

      final session = sessions.open(_rose)!;
      await _settle();

      sessions.arm(session, {StickyModifier.ctrl}, repeat: 3);
      sessions.arm(session, const {}, repeat: 3);

      expect(session.sticky, isEmpty);
      expect(session.stickyRepeat, 1);
    });

    test('one session\'s count is not another\'s', () async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);

      final first = sessions.open(_rose)!;
      final second = sessions.open(_rose)!;
      await _settle();

      sessions.arm(first, {StickyModifier.ctrl}, repeat: 2);
      sessions.activate(_rose.id, second);

      expect(second.sticky, isEmpty);
      expect(second.stickyRepeat, 1);

      // Coming back finds the arming where it was left, count and all.
      sessions.activate(_rose.id, first);
      expect(first.sticky, {StickyModifier.ctrl});
      expect(first.stickyRepeat, 2);
    });

    test('a closed session takes its count with it', () async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);

      final session = sessions.open(_rose)!;
      await _settle();
      sessions.arm(session, {StickyModifier.ctrl}, repeat: 3);

      await sessions.close(_rose.id, session);

      expect(session.sticky, isEmpty);
      expect(session.stickyRepeat, 1);
    });
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
    sessions.arm(session, {StickyModifier.ctrl}, repeat: 2);

    transport.opened.single.drop();
    await tester.pump();
    await tester.pump(shellReconnectDelays.first);
    await _pumpDial(tester);

    expect(session.title, isNull);
    expect(session.sticky, isEmpty);
    expect(session.stickyRepeat, 1);

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

  test('a failure carries the words the transport failed with', () async {
    final transport = FakeShellTransport()
      ..refuse = const ShellFailure(
        ShellFailureKind.keyRejected,
        detail: 'SSHAuthFailError: publickey',
      );
    final sessions = fakeShellSessions(transport);

    final session = sessions.open(_rose)!;
    await _settle();

    final state = session.state as ShellFailed;
    expect(state.kind, ShellFailureKind.keyRejected);
    expect(state.detail, 'SSHAuthFailError: publickey');
  });

  testWidgets('an error nobody mapped keeps its own words', (tester) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    final session = sessions.open(_rose)!;
    await _pumpDial(tester);

    transport.opened.single.drop(StateError('no route to host'));
    await tester.pump();
    sessions.stopReconnect(session);
    await tester.pump();

    // The one failure the app has no word for is the one whose text is
    // always kept, and giving up shows what the last dial hit.
    final state = session.state as ShellFailed;
    expect(state.kind, ShellFailureKind.streamClosed);
    expect(state.detail, contains('no route to host'));

    await sessions.close(_rose.id, session);
  });

  testWidgets('a shell that came back carries no detail', (tester) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    final session = sessions.open(_rose)!;
    await _pumpDial(tester);

    transport.opened.single.drop(StateError('gone'));
    await tester.pump();
    await tester.pump(shellReconnectDelays.first);
    await _pumpDial(tester);
    expect(session.state, isA<ShellLive>());

    transport.opened.last.drop(const ShellFailure(ShellFailureKind.keyRejected));
    await tester.pump();

    expect((session.state as ShellFailed).detail, isNull);

    await sessions.close(_rose.id, session);
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

  group('a session lets go of what it owns', () {
    /// A listenable that has been disposed refuses a new listener, which is
    /// the only thing one says about itself from the outside.
    void expectDisposed(ChangeNotifier notifier, String what) {
      expect(
        () => notifier.addListener(() {}),
        throwsFlutterError,
        reason: '$what should be disposed',
      );
    }

    void expectAlive(ChangeNotifier notifier, String what) {
      void listener() {}
      expect(
        () => notifier
          ..addListener(listener)
          ..removeListener(listener),
        returnsNormally,
        reason: '$what should still be alive',
      );
    }

    testWidgets('closing a tab disposes its controllers once the frame has '
        'run', (tester) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      final session = sessions.open(_rose)!;
      await _pumpDial(tester);

      await sessions.close(_rose.id, session);
      // Still alive in the frame the tab was dropped in: the view holding
      // them has not been rebuilt out of the tree yet.
      expectAlive(session.controller, 'the selection controller');

      await tester.pump();
      expectDisposed(session.controller, 'the selection controller');
      expectDisposed(session.focusNode, 'the focus node');
      expectDisposed(session.scrollController, 'the scroll controller');
    });

    testWidgets('closing one tab leaves another tab alone', (tester) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      final first = sessions.open(_rose)!;
      final second = sessions.open(_rose)!;
      await _pumpDial(tester);

      await sessions.close(_rose.id, first);
      await tester.pump();

      expectDisposed(first.controller, "the closed tab's controller");
      expectAlive(second.controller, "the open tab's controller");
      expectAlive(second.focusNode, "the open tab's focus node");
      expectAlive(second.scrollController, "the open tab's scroll controller");
    });

    testWidgets('a shell that exits clean disposes its own', (tester) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      final session = sessions.open(_rose)!;
      await _pumpDial(tester);

      transport.opened.single.exit(shellCleanExit);
      await _pumpDial(tester);
      await tester.pump();

      expect(sessions.forHost(_rose.id), isEmpty);
      expectDisposed(session.controller, "the exited tab's controller");
      expectDisposed(session.scrollController, "the exited tab's scroll");
    });

    testWidgets('the view drawing the closed tab detaches without raising', (
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
      final first = sessions.forHost(_rose.id).single;
      final second = sessions.open(_rose)!;
      await _pumpDial(tester);
      await tester.pump();

      // The tab on screen goes, so its view is the one leaving the tree while
      // the store retires what it was drawing with.
      await sessions.close(_rose.id, second);
      await tester.pump();
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(sessions.forHost(_rose.id), [first]);
    });

    test('retiring twice is a no-op', () async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      final session = sessions.open(_rose)!;
      await _settle();

      session.dispose();
      expect(session.dispose, returnsNormally);
    });
  });

  group('a dial holds a claim on its tab', () {
    testWidgets('a tab closed while a reconnect shuts the old shell down '
        'opens no new one', (tester) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      final session = sessions.open(_rose)!;
      await _pumpDial(tester);
      expect(session.state, isA<ShellLive>());

      transport.opened.single.drop();
      await tester.pump();
      expect(session.state, isA<ShellDropped>());

      // The wait runs out and the redial starts, which parks it on the close
      // of the shell that died. The tab goes while it is parked there.
      final hold = Completer<void>();
      transport.opened.single.hold = hold;
      await tester.pump(shellReconnectDelays.first);
      final dials = transport.sizes.length;
      unawaited(sessions.close(_rose.id, session));
      await _pumpDial(tester);
      hold.complete();
      await _pumpDial(tester);

      expect(transport.sizes, hasLength(dials));
      expect(session.state, isNot(isA<ShellLive>()));
      expect(sessions.forHost(_rose.id), isEmpty);
    });

    testWidgets('a dial that lands after the tab was closed closes what it '
        'opened', (tester) async {
      final transport = FakeShellTransport()..stall = true;
      final sessions = fakeShellSessions(transport);
      final session = sessions.open(_rose)!;
      await _pumpDial(tester);
      expect(session.state, isA<ShellConnecting>());

      await sessions.close(_rose.id, session);
      // The dial the closed tab started now lands, on a host that never heard
      // it had been given up on.
      transport.land();
      await _pumpDial(tester);

      expect(transport.opened.single.closed, isTrue);
      expect(session.state, isNot(isA<ShellLive>()));
      expect(session.connection, isNull);
    });

    testWidgets('a tab closed during the wait leaves the schedule dead', (
      tester,
    ) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      final session = sessions.open(_rose)!;
      await _pumpDial(tester);

      transport.opened.single.drop();
      await tester.pump();
      expect(session.state, isA<ShellDropped>());

      await sessions.close(_rose.id, session);
      final dials = transport.sizes.length;
      await tester.pump(shellReconnectDelays.first);
      await _pumpDial(tester);

      expect(transport.sizes, hasLength(dials));
    });
  });

  group('a change reaches the tab it happened to', () {
    /// What each notifier said since it was wired, so a test can name where a
    /// change was announced rather than only that something was.
    ({int Function() store, int Function() session}) counts(
      ShellSessions sessions,
      ShellSession session,
    ) {
      var storeSaid = 0;
      var sessionSaid = 0;
      sessions.addListener(() => storeSaid++);
      session.addListener(() => sessionSaid++);
      return (store: () => storeSaid, session: () => sessionSaid);
    }

    test('arming a modifier and spending it leave the store silent', () async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      final session = sessions.open(_rose)!;
      await _settle();
      final said = counts(sessions, session);

      sessions.arm(session, {StickyModifier.ctrl}, repeat: 2);
      sessions.send(session, Uint8List.fromList([4]));
      sessions.send(session, Uint8List.fromList([4]));

      // Armed, spent once, spent out: three changes, all of them this tab's.
      expect(said.session(), 3);
      expect(said.store(), 0);

      await sessions.close(_rose.id, session);
    });

    testWidgets('a state tells the session and not the list', (tester) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      final session = sessions.open(_rose)!;
      await _pumpDial(tester);
      final said = counts(sessions, session);

      transport.opened.single.drop();
      await tester.pump();
      expect(session.state, isA<ShellDropped>());

      expect(said.session(), greaterThan(0));
      expect(said.store(), 0);

      await sessions.close(_rose.id, session);
    });

    test('a title tells the tab that named itself', () async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      final first = sessions.open(_rose)!;
      final second = sessions.open(_rose)!;
      await _settle();
      var otherSaid = 0;
      second.addListener(() => otherSaid++);
      final said = counts(sessions, first);

      transport.opened.first.emit('\x1b]0;htop\x07');
      await _settle();

      expect(first.title, 'htop');
      expect(said.session(), greaterThan(0));
      expect(said.store(), 0);
      expect(otherSaid, 0);

      await sessions.close(_rose.id, first);
      await sessions.close(_rose.id, second);
    });

    test('opening, closing and activating tell the store', () async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      var storeSaid = 0;
      sessions.addListener(() => storeSaid++);

      final session = sessions.open(_rose)!;
      await _settle();
      expect(storeSaid, 1);

      sessions.activate(_rose.id, session);
      expect(storeSaid, 2);

      await sessions.close(_rose.id, session);
      expect(storeSaid, 3);
    });

    testWidgets('a change announced after retiring reaches nobody', (
      tester,
    ) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      final session = sessions.open(_rose)!;
      await _pumpDial(tester);

      await sessions.close(_rose.id, session);
      await tester.pump();

      expect(session.changed, returnsNormally);
    });

    testWidgets('a card follows its own tab and the store stays out of it', (
      tester,
    ) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      final first = sessions.open(_rose)!;
      final second = sessions.open(_rose)!;
      await _pumpDial(tester);
      var storeSaid = 0;
      sessions.addListener(() => storeSaid++);

      await tester.pumpWidget(
        MaterialApp(
          home: Row(
            children: [
              ShellCard(host: _rose, session: first),
              ShellCard(host: _rose, session: second),
            ],
          ),
        ),
      );

      transport.opened.first.emit('\x1b]0;htop\x07');
      await tester.pump();
      await tester.pump();

      // The title is on the card without the store having said a word.
      expect(find.text('htop'), findsOneWidget);
      expect(storeSaid, 0);

      await tester.pumpWidget(const SizedBox.shrink());
      await sessions.close(_rose.id, first);
      await sessions.close(_rose.id, second);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    });
  });
}
