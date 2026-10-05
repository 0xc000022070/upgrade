import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/application/pin_alerts.dart';
import 'package:upgrade/data/enums.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/data/repositories/shell_tab_repository.dart';
import 'package:upgrade/data/shell_snapshot_store.dart';
import 'package:upgrade/design/components/dot_spinner.dart';
import 'package:upgrade/features/shell/host_shell_screen.dart';
import 'package:upgrade/features/shell/shell_card.dart';
import 'package:upgrade/features/shell/shell_sessions.dart';
import 'package:upgrade/platform/herdr_client.dart';
import 'package:upgrade/platform/shell/host_system.dart';
import 'package:upgrade/platform/shell/remote_shell.dart';
import 'package:upgrade/platform/shell/shell_connection.dart';
import 'package:upgrade/platform/vnc/keysyms.dart';
import 'package:upgrade/features/shell/shell_terminal.dart';
import 'package:flterm/flterm.dart';

import 'support/fake_shell.dart';
import 'support/shell_route.dart' show noWorkspaces;
import 'support/themed_app.dart';

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

/// The store dials on a microtask.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

int _systemProbes(FakeShellConnection connection) => connection.execs
    .where((exec) => exec.command.contains(systemProbeScript))
    .length;

String _text(TerminalController terminal) {
  final formatter = terminal.createFormatter(format: FormatterFormat.plain);
  try {
    return formatter.format();
  } finally {
    formatter.dispose();
  }
}

Future<void> _restored(WidgetTester tester, ShellSession session) async {
  for (var i = 0; i < 100; i++) {
    if (session.terminal.restoration != RestorationState.restoring) return;
    await tester.pump(const Duration(milliseconds: 10));
  }
}

Future<void> _pumpView(WidgetTester tester, ShellSession session, Size size) =>
    tester.pumpWidget(
      Theme(
        data: testTheme,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox.fromSize(
              size: size,
              child: ShellTerminalView(session: session, fontSize: 12),
            ),
          ),
        ),
      ),
    );

class _DelayedShellTabs extends InMemoryShellTabRepository {
  final release = Completer<void>();
  var started = false;

  @override
  Future<void> open(
    String hostId,
    int number, {
    String? remoteSession,
    String? herdrSession,
    String? herdrPane,
    String? launch,
    DateTime? openedAt,
  }) async {
    started = true;
    await release.future;
    await super.open(
      hostId,
      number,
      remoteSession: remoteSession,
      herdrSession: herdrSession,
      herdrPane: herdrPane,
      launch: launch,
      openedAt: openedAt,
    );
  }
}

/// The store's own clock is the test binding's inside [testWidgets], so a reconnect's
/// wait is advanced by pumping rather than waited out.
Future<void> _pumpDial(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

/// Runs a live session's whole schedule out with nothing answering. Leaves the transport
/// refusing.
Future<void> _spend(
  WidgetTester tester,
  FakeShellTransport transport,
  ShellSession session,
) async {
  transport.refuse = const ShellFailure(ShellFailureKind.unreachable);
  transport.opened.single.drop();
  await tester.pump();
  for (final delay in shellReconnectDelays) {
    expect(session.state, isA<ShellDropped>());
    await tester.pump(delay);
    await _pumpDial(tester);
  }
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

    expect(fourth.number, 4);
    expect(sessions.forHost(_rose.id).map((session) => session.number), [
      1,
      3,
      4,
    ]);
  });

  test("a directory is the tab's command, not a typed line", () async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);

    final session = sessions.open(_rose, command: shellIn('/srv/gate'))!;
    await _settle();

    expect(session.command, "cd '/srv/gate' && exec \$SHELL -l");
    expect(transport.commands, [
      shellMarked(session.mark, command: session.command),
    ]);
    // A line written at a login shell races whatever that shell reads before its prompt.
    expect(transport.opened.single.written, isEmpty);
  });

  test('a plain session writes nothing on its own', () async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);

    sessions.open(_rose);
    await _settle();

    expect(transport.opened.single.written, isEmpty);
  });

  test('a live shell asks its host what system it runs, once', () async {
    final transport = FakeShellTransport()
      ..opening = (connection) =>
          connection.answerWith('Linux\nNAME=NixOS\nID=nixos\n');
    final recorded = <(String, HostSystem)>[];
    final sessions = fakeShellSessions(
      transport,
      recordSystem: (hostId, system) async => recorded.add((hostId, system)),
    );

    sessions.open(_rose);
    sessions.open(_rose);
    await _settle();
    await _settle();

    expect(recorded, [('h1', HostSystem.nixos)]);
    expect(transport.opened.map(_systemProbes), [1, 0]);
  });

  test('a known system is not written again', () async {
    final transport = FakeShellTransport()
      ..opening = (connection) => connection.answerWith('Darwin\n');
    final recorded = <(String, HostSystem)>[];
    final sessions = fakeShellSessions(
      transport,
      recordSystem: (hostId, system) async => recorded.add((hostId, system)),
    );

    sessions.open(
      const Host(
        id: 'h1',
        name: 'rose',
        address: '100.64.0.1',
        port: 22,
        user: 'luis',
        keyId: 'key-1',
        system: HostSystem.darwin,
      ),
    );
    await _settle();
    await _settle();

    expect(_systemProbes(transport.opened.single), 1);
    expect(recorded, isEmpty);
  });

  test('a probe that fails is asked again on the next shell', () async {
    final transport = FakeShellTransport()
      ..opening = (connection) => connection.answerWith('', exitCode: 1);
    final recorded = <(String, HostSystem)>[];
    final sessions = fakeShellSessions(
      transport,
      recordSystem: (hostId, system) async => recorded.add((hostId, system)),
    );

    sessions.open(_rose);
    await _settle();
    await _settle();
    sessions.open(_rose);
    await _settle();
    await _settle();

    expect(transport.opened.map(_systemProbes), [1, 1]);
    expect(recorded, isEmpty);
  });

  testWidgets('the spinner holds the page until the host draws on it', (
    tester,
  ) async {
    final transport = FakeShellTransport()..stall = true;
    final sessions = fakeShellSessions(transport);

    final session = sessions.open(_rose)!;
    await _pumpView(tester, session, const Size(400, 600));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(DotSpinner), findsNothing);
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.byType(DotSpinner), findsOneWidget);

    transport.land();
    await _pumpDial(tester);
    expect(session.state, isA<ShellLive>());
    expect(find.byType(DotSpinner), findsOneWidget);

    transport.opened.single.emit('\$ ');
    await _pumpDial(tester);
    expect(find.byType(DotSpinner), findsNothing);

    await sessions.close(_rose.id, session);
  });

  testWidgets('a dial that fails takes the spinner with it', (tester) async {
    final transport = FakeShellTransport()..stall = true;
    final sessions = fakeShellSessions(transport);

    final session = sessions.open(_rose)!;
    await _pumpView(tester, session, const Size(400, 600));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byType(DotSpinner), findsOneWidget);

    session.state = const ShellFailed(ShellFailureKind.keyRejected);
    session.changed();
    await tester.pump();
    expect(find.byType(DotSpinner), findsNothing);

    await sessions.close(_rose.id, session);
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

    connection.emit('upgrade');
    await _settle();
    expect(_text(session.terminal), contains('upgrade'));

    sessions.send(session, Uint8List.fromList([0x03]));
    expect(connection.writes.single, [0x03]);
  });

  test(
    'a snapshot replaces the terminal and later bytes land on the new one',
    () async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);

      final session = sessions.open(_rose)!;
      await _settle();
      final connection = transport.opened.single;
      final first = session.terminal;
      connection.emit('stale');
      await _settle();

      final source = TerminalController()..write(utf8.encode('restored'));
      final snapshot = source.snapshot();
      source.dispose();
      connection.emitSnapshot(snapshot);
      await _settle();
      await session.terminal.restored;

      expect(session.terminal, isNot(same(first)));
      expect(_text(session.terminal), contains('restored'));
      expect(_text(session.terminal), isNot(contains('stale')));

      connection.emit(' after');
      await _settle();
      expect(_text(session.terminal), contains('restored after'));
    },
  );

  test('a character split across two reads survives the boundary', () async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);

    final session = sessions.open(_rose)!;
    await _settle();
    final connection = transport.opened.single;

    // The two bytes of `ñ`, arriving as two reads the way a busy channel delivers them.
    connection.emitBytes([0xC3]);
    await _settle();
    connection.emitBytes([0xB1]);
    await _settle();

    expect(_text(session.terminal), contains('ñ'));
  });

  test('an armed modifier reaches what the keyboard types, once', () async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);

    final session = sessions.open(_rose)!;
    await _settle();
    final connection = transport.opened.single;

    sessions.arm(session, {StickyModifier.ctrl});
    session.terminal.sendText('c');

    expect(connection.writes.single, [0x03]);
    expect(session.sticky, isEmpty);

    session.terminal.sendText('c');
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
      session.terminal.sendText('d');
      expect(session.sticky, {StickyModifier.ctrl});
      expect(session.stickyRepeat, 1);

      session.terminal.sendText('d');
      expect(session.sticky, isEmpty);
      expect(session.stickyRepeat, 1);

      session.terminal.sendText('d');

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
        // DSR 6, "where is the cursor".
        connection.emit('\x1b[6n');
        await _settle();

        expect(session.sticky, {StickyModifier.ctrl});
        expect(session.stickyRepeat, 2);

        session.terminal.sendText('d');
        session.terminal.sendText('d');

        expect(connection.writes, [
          utf8.encode('\x1b[1;1R'),
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
      final connection = transport.opened.single;

      sessions.arm(session, {StickyModifier.ctrl}, repeat: 3);
      // Device attributes, operating status, cursor position, size: every reply the
      // terminal makes without being typed at.
      for (final query in [
        '\x1b[c',
        '\x1b[>c',
        '\x1b[5n',
        '\x1b[6n',
        '\x1b[18t',
      ]) {
        connection.emit(query);
      }
      await _settle();
      expect(connection.writes, hasLength(5));

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
      connection.emit('\x1b[6n');
      await _settle();

      expect(connection.writes, [utf8.encode('\x1b[1;1R')]);
    });

    testWidgets('a mouse report is not one of the keys either', (tester) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);

      final session = sessions.open(_rose)!;
      await _pumpDial(tester);
      final connection = transport.opened.single;
      await _pumpView(tester, session, const Size(400, 600));

      // Mouse reporting on, as an agent on the alternate screen leaves it.
      connection.emit('\x1b[?1000h');
      await _pumpDial(tester);
      sessions.arm(session, {StickyModifier.ctrl}, repeat: 2);
      await tester.tapAt(const Offset(40, 40), kind: PointerDeviceKind.mouse);
      await tester.pump();

      expect(session.sticky, {StickyModifier.ctrl});
      expect(session.stickyRepeat, 2);
      expect(connection.writes, isNotEmpty);
      for (final report in connection.writes) {
        expect(report.take(3), [0x1b, 0x5b, 0x4d]);
      }

      await sessions.close(_rose.id, session);
    });

    test('a report is told from a key by its shape alone', () {
      bool report(String text) => isViewReport(utf8.encode(text));

      expect(report('\x1b[<0;12;4M'), isTrue);
      expect(report('\x1b[<0;12;4m'), isTrue);
      expect(report('\x1b[<65;3;9M'), isTrue);
      expect(report('\x1b[M !"'), isTrue);
      expect(report('\x1b[32;12;4M'), isTrue);
      expect(report('\x1b[I'), isTrue);
      expect(report('\x1b[O'), isTrue);

      expect(report('\x1b[A'), isFalse);
      expect(report('\x1b[1;5A'), isFalse);
      expect(report('\x1b[3~'), isFalse);
      expect(report('\x1bOM'), isFalse);
      expect(report('M'), isFalse);
      expect(report('\x1b[200~ls\x1b[201~'), isFalse);
    });

    test('plain Mosh shells may disable mouse reporting', () async {
      final transport = FakeShellTransport()..transport = ShellTransport.mosh;
      final sessions = fakeShellSessions(transport);
      final session = sessions.open(_rose)!;
      await _settle();

      final connection = transport.opened.single;
      connection.emit('\x1b[?1002h\x1b[?1002l\x1b[?1006h');
      await _settle();

      expect(session.terminal.mouseTracking, MouseTracking.none);
      expect(connection.writes, isEmpty);
      expect(session.terminal.activeScreen, TerminalScreen.primary);
    });

    test('a Herdr pane over Mosh starts in the alternate buffer', () async {
      final transport = FakeShellTransport()..transport = ShellTransport.mosh;
      final sessions = fakeShellSessions(transport);
      final session = sessions.open(
        _rose,
        command: 'attach',
        pane: const (session: 'default', pane: 'w1:p1'),
      )!;
      await _settle();

      expect(session.terminal.activeScreen, TerminalScreen.alternate);
    });

    test('Herdr over SSH may disable mouse reporting', () async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      final session = sessions.open(
        _rose,
        command: 'attach',
        pane: const (session: 'default', pane: 'w1:p1'),
      )!;
      await _settle();

      final connection = transport.opened.single;
      connection.emit('\x1b[?1002h\x1b[?1002l\x1b[?1006h');
      await _settle();

      expect(session.terminal.mouseTracking, MouseTracking.none);
      expect(connection.writes, isEmpty);
      expect(session.terminal.activeScreen, TerminalScreen.primary);
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
      session.addListener(() => notices++);

      sessions.arm(session, {StickyModifier.ctrl}, repeat: 2);
      expect(notices, 1);
      session.terminal.sendText('d');
      expect(notices, 2);
      session.terminal.sendText('d');
      expect(notices, 3);
      session.terminal.sendText('d');
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

  group('a modifier held down', () {
    test('every key goes through it and it stays up', () async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);

      final session = sessions.open(_rose)!;
      await _settle();
      final connection = transport.opened.single;

      sessions.arm(session, {StickyModifier.ctrl}, locked: true);
      session.terminal.sendText('d');
      session.terminal.sendText('d');
      session.terminal.sendText('d');

      expect(session.sticky, {StickyModifier.ctrl});
      expect(session.stickyLocked, isTrue);
      expect(connection.writes, [
        [0x04],
        [0x04],
        [0x04],
      ]);
    });

    test('a key off the bar spends nothing either', () async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);

      final session = sessions.open(_rose)!;
      await _settle();

      sessions.arm(session, {StickyModifier.alt}, locked: true);
      sessions.send(session, Uint8List.fromList([0x1b, 0x5b, 0x41]));
      sessions.send(session, Uint8List.fromList([0x1b, 0x5b, 0x41]));

      expect(session.sticky, {StickyModifier.alt});
      expect(session.stickyLocked, isTrue);
    });

    test('an empty arming carries no latch', () async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);

      final session = sessions.open(_rose)!;
      await _settle();

      sessions.arm(session, {StickyModifier.ctrl}, locked: true);
      sessions.arm(session, const {}, locked: true);

      expect(session.sticky, isEmpty);
      expect(session.stickyLocked, isFalse);
    });

    testWidgets('a reconnect drops the latch with the set', (tester) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      final session = sessions.open(_rose)!;
      await _pumpDial(tester);
      sessions.arm(session, {StickyModifier.ctrl}, locked: true);

      transport.opened.single.drop();
      await tester.pump();

      expect(session.sticky, isEmpty);
      expect(session.stickyLocked, isFalse);

      await tester.pump(shellReconnectDelays.first);
      await _pumpDial(tester);

      expect(session.sticky, isEmpty);
      expect(session.stickyLocked, isFalse);

      await sessions.close(_rose.id, session);
    });
  });

  testWidgets('the return the keyboard sends goes out as a carriage return', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);

    final session = sessions.open(_rose)!;
    await _pumpDial(tester);
    await _pumpView(tester, session, const Size(400, 600));
    session.focusNode.requestFocus();
    await tester.pump();

    session.terminal.sendText('ls');
    await tester.testTextInput.receiveAction(TextInputAction.newline);
    await tester.pump(const Duration(seconds: 1));

    expect(transport.opened.single.written, 'ls\r');

    await sessions.close(_rose.id, session);
  });

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

  testWidgets('a reconnect takes the dead application\'s mouse reporting and '
      'its screen with it', (tester) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    final session = sessions.open(_rose)!;
    await _pumpDial(tester);

    transport.opened.single.emit('\x1b[?1049h\x1b[?1002h\x1b[?1006h');
    await _pumpDial(tester);
    expect(session.terminal.mouseTracking, isNot(MouseTracking.none));
    expect(session.terminal.activeScreen, TerminalScreen.alternate);

    transport.opened.single.drop();
    await tester.pump();
    await tester.pump(shellReconnectDelays.first);
    await _pumpDial(tester);

    expect(session.terminal.mouseTracking, MouseTracking.none);
    expect(session.terminal.activeScreen, TerminalScreen.primary);

    await sessions.close(_rose.id, session);
  });

  testWidgets('a pane that outlived the link keeps what its application set', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    const pane = (session: 'lab', pane: 'w22:p1');
    final session = sessions.open(_rose, command: 'attach', pane: pane)!;
    await _pumpDial(tester);

    transport.opened.single.emit('\x1b[?1002h\x1b[?1006h');
    await _pumpDial(tester);

    transport.opened.single.drop();
    await tester.pump();
    await tester.pump(shellReconnectDelays.first);
    await _pumpDial(tester);

    expect(session.terminal.mouseTracking, isNot(MouseTracking.none));

    await sessions.close(_rose.id, session);
  });

  test('a tab opened on a pane is the one the store hands back for it', () {
    final sessions = fakeShellSessions(FakeShellTransport());

    const pane = (session: 'lab', pane: 'w22:p1');
    final bare = sessions.open(_rose)!;
    final attached = sessions.open(_rose, command: 'attach', pane: pane)!;
    sessions.open(_nyx, command: 'attach', pane: pane);

    expect(bare.pane, isNull);
    expect(attached.pane, pane);
    expect(sessions.holding(_rose.id, pane), same(attached));
    expect(
      sessions.holding(_rose.id, (session: 'lab', pane: 'w26:p1')),
      isNull,
    );
    expect(
      sessions.holding(_rose.id, (session: 'default', pane: 'w22:p1')),
      isNull,
    );
    expect(sessions.holding(_nyx.id, pane), isNot(same(attached)));
  });

  testWidgets('a reconnect comes back on the same pane', (tester) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    const pane = (session: 'lab', pane: 'w22:p1');
    final session = sessions.open(_rose, command: 'attach', pane: pane)!;
    await _pumpDial(tester);
    expect(sessions.holding(_rose.id, pane), same(session));

    transport.opened.single.drop();
    await tester.pump();
    await tester.pump(shellReconnectDelays.first);
    await _pumpDial(tester);

    expect(session.pane, pane);
    expect(sessions.holding(_rose.id, pane), same(session));
    final marked = shellMarked(session.mark, command: 'attach');
    expect(transport.commands, [marked, marked]);
    expect(transport.opened.last.written, isEmpty);

    await sessions.close(_rose.id, session);
  });

  testWidgets('a resize is forwarded once per size', (tester) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);

    final session = sessions.open(_rose)!;
    await _pumpDial(tester);
    final connection = transport.opened.single;

    await _pumpView(tester, session, const Size(400, 600));
    await _pumpView(tester, session, const Size(401, 600));
    await _pumpView(tester, session, const Size(600, 600));

    expect(connection.resizes, hasLength(2));
    expect(
      connection.resizes.last[0],
      greaterThan(connection.resizes.first[0]),
    );
    expect(connection.resizes.last[1], connection.resizes.first[1]);

    await sessions.close(_rose.id, session);
  });

  testWidgets('a size the view settles on mid-dial reaches the remote', (
    tester,
  ) async {
    final transport = FakeShellTransport()..stall = true;
    final sessions = fakeShellSessions(transport);

    final session = sessions.open(_rose)!;
    await _pumpDial(tester);
    await _pumpView(tester, session, const Size(600, 600));
    transport.land();
    await _pumpDial(tester);

    final dialed = transport.sizes.single;
    final connection = transport.opened.single;
    expect(connection.resizes, hasLength(1));
    expect(connection.resizes.single, isNot(dialed));

    await sessions.close(_rose.id, session);
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

  testWidgets('a machine that did not answer names the dial in its detail', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    final session = sessions.open(_rose)!;
    await _pumpDial(tester);

    await _spend(tester, transport, session);
    transport.refuse = const ShellFailure(
      ShellFailureKind.unreachable,
      detail: 'connection refused',
    );
    sessions.wakeAll();
    await _pumpDial(tester);
    for (final delay in shellReconnectDelays) {
      expect(session.state, isA<ShellDropped>());
      await tester.pump(delay);
      await _pumpDial(tester);
    }

    final state = session.state as ShellWaiting;
    expect(state.kind, ShellFailureKind.unreachable);
    expect(state.detail, 'luis@100.64.0.1:22 · connection refused');

    await sessions.close(_rose.id, session);
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

    transport.opened.last.drop(
      const ShellFailure(ShellFailureKind.keyRejected),
    );
    await tester.pump();

    expect((session.state as ShellFailed).detail, isNull);

    await sessions.close(_rose.id, session);
  });

  test('every failure carries the reason line the header draws', () {
    expect(ShellFailureKind.unreachable.line.on('ROSE'), 'rose unreachable');
    expect(ShellFailureKind.unresolved.line.on('ROSE'), 'rose unresolved');
    expect(ShellFailureKind.keyRejected.line.on('ROSE'), 'key rejected');
    expect(ShellFailureKind.shellRefused.line.on('ROSE'), 'shell refused');
    expect(ShellFailureKind.streamClosed.line.on('ROSE'), 'stream closed');
  });

  testWidgets('the store keeps its sessions across a route dispose', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          shellSessionsProvider.overrideWithValue(sessions),
          noWorkspaces,
        ],
        child: MaterialApp(
          theme: testTheme,
          home: HostShellRoute(host: _rose),
        ),
      ),
    );
    await tester.pump();
    expect(sessions.forHost(_rose.id), hasLength(1));

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

    expect(session.state, isA<ShellDropped>());
    expect((session.state as ShellDropped).attempt, 1);
    expect(transport.opened, hasLength(1));

    await tester.pump(shellReconnectDelays.first);
    await _pumpDial(tester);

    expect(session.state, isA<ShellLive>());
    expect(transport.opened, hasLength(2));
    expect(_text(session.terminal), contains('-- reconnected --'));
    expect(transport.verifiers.last?.prompt, isNull);

    await sessions.close(_rose.id, session);
  });

  testWidgets('an engine tab writes its reconnect line into the screen that '
      'replaces it', (tester) async {
    final transport = FakeShellTransport()..transport = ShellTransport.engine;
    final sessions = fakeShellSessions(transport);
    final session = sessions.open(_rose)!;
    await _pumpDial(tester);

    transport.opened.single.drop();
    await tester.pump();
    await tester.pump(shellReconnectDelays.first);
    await _pumpDial(tester);

    expect(transport.opened, hasLength(2));
    expect(_text(session.terminal), isNot(contains('-- reconnected --')));

    final source = TerminalController()..write(utf8.encode('restored'));
    final snapshot = source.snapshot();
    source.dispose();
    transport.opened.last.emitSnapshot(snapshot);
    await tester.pump();
    await _restored(tester, session);

    expect(_text(session.terminal), contains('restored'));
    expect(_text(session.terminal), contains('-- reconnected --'));

    final again = TerminalController()..write(utf8.encode('later'));
    final second = again.snapshot();
    again.dispose();
    transport.opened.last.emitSnapshot(second);
    await tester.pump();
    await _restored(tester, session);
    expect(_text(session.terminal), isNot(contains('-- reconnected --')));

    await sessions.close(_rose.id, session);
  });

  test('a measured cell gives an engine pty its pixel size', () async {
    final transport = FakeShellTransport()..transport = ShellTransport.engine;
    final sessions = fakeShellSessions(transport);
    final session = sessions.open(_rose)!;
    await _settle();
    final connection = transport.opened.single;
    final opened = connection.resizes.length;

    session.measuredCell(20, 42);
    session.measuredCell(20, 42);
    expect(connection.resizes.length, opened + 1);
    final [columns, rows] = connection.resizes.last;
    expect(connection.pixels.last, [columns * 20, rows * 42]);
  });

  testWidgets('the view measures its cells and a resize carries the pixels', (
    tester,
  ) async {
    final transport = FakeShellTransport()..transport = ShellTransport.engine;
    final sessions = fakeShellSessions(transport);
    final session = sessions.open(_rose)!;
    await _pumpDial(tester);
    final connection = transport.opened.single;

    await _pumpView(tester, session, const Size(400, 600));
    await _pumpView(tester, session, const Size(600, 600));

    final [columns, rows] = connection.resizes.last;
    final [width, height] = connection.pixels.last;
    expect(width, greaterThan(0));
    expect(height, greaterThan(0));
    expect(width % columns, 0);
    expect(height % rows, 0);

    await sessions.close(_rose.id, session);
  });

  test('a measured cell leaves a Mosh link alone', () async {
    final transport = FakeShellTransport()..transport = ShellTransport.mosh;
    final sessions = fakeShellSessions(transport);
    final session = sessions.open(_rose)!;
    await _settle();
    final connection = transport.opened.single;
    final opened = connection.resizes.length;

    session.measuredCell(20, 42);
    expect(connection.resizes, hasLength(opened));
  });

  testWidgets(
    'a roaming shell reports stalled and recovered transport health',
    (tester) async {
      final transport = FakeShellTransport()..transport = ShellTransport.mosh;
      final sessions = fakeShellSessions(transport);
      final session = sessions.open(_rose)!;
      await _pumpDial(tester);

      transport.opened.single.setHealth(ShellConnectionHealth.reconnecting);
      await tester.pump();
      expect(session.state, isA<ShellReconnecting>());

      transport.opened.single.setHealth(ShellConnectionHealth.disconnected);
      await tester.pump();
      expect(session.state, isA<ShellDisconnected>());

      transport.opened.single.setHealth(ShellConnectionHealth.connected);
      await tester.pump();
      expect(session.state, isA<ShellLive>());

      await sessions.close(_rose.id, session);
    },
  );

  testWidgets('a first dial that never lands is waited out too', (
    tester,
  ) async {
    final transport = FakeShellTransport()
      ..refuse = const ShellFailure(ShellFailureKind.unreachable);
    final sessions = fakeShellSessions(transport);
    final session = sessions.open(_rose)!;
    await _pumpDial(tester);

    expect(session.state, isA<ShellDropped>());

    transport.refuse = null;
    await tester.pump(shellReconnectDelays.first);
    await _pumpDial(tester);

    expect(session.state, isA<ShellLive>());
    expect(transport.opened, hasLength(1));

    await sessions.close(_rose.id, session);
  });

  testWidgets('six waits and then the tab waits, off every clock', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    final session = sessions.open(_rose)!;
    await _pumpDial(tester);

    await _spend(tester, transport, session);

    expect(transport.verifiers, hasLength(1 + shellReconnectDelays.length));
    expect(session.state, isA<ShellWaiting>());
    expect((session.state as ShellWaiting).kind, ShellFailureKind.unreachable);
    expect(session.state.failure?.kind, ShellFailureKind.unreachable);

    await tester.pump(const Duration(minutes: 5));
    await _pumpDial(tester);
    expect(transport.verifiers, hasLength(1 + shellReconnectDelays.length));

    await sessions.close(_rose.id, session);
  });

  testWidgets('a wake dials the same command against the same pane', (
    tester,
  ) async {
    const pane = (session: 'work', pane: '%3');
    const attach = 'herdr attach work %3';
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    final session = sessions.open(_rose, command: attach, pane: pane)!;
    await _pumpDial(tester);

    await _spend(tester, transport, session);
    transport.refuse = null;
    sessions.wakeAll();
    await _pumpDial(tester);

    expect(session.state, isA<ShellLive>());
    expect(transport.commands.last, shellMarked(session.mark, command: attach));
    expect(session.pane, pane);
    expect(_text(session.terminal), contains('-- reattached --'));

    await sessions.close(_rose.id, session);
  });

  testWidgets('a wake rehomes a live transport without redialling', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    final session = sessions.open(_rose)!;
    await _pumpDial(tester);

    sessions.wakeAll();
    await _pumpDial(tester);

    expect(transport.opened, hasLength(1));
    expect(transport.opened.single.rehomes, 1);
    expect(session.state, isA<ShellLive>());
    await sessions.close(_rose.id, session);
  });

  testWidgets('a network arriving just after a plain wake still rehomes', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    final session = sessions.open(_rose)!;
    await _pumpDial(tester);
    final connection = transport.opened.single;

    sessions.wakeAll();
    sessions.wakeAll(network: true);
    await _pumpDial(tester);
    expect(connection.rehomes, 2);
    expect(connection.networkRehomes, 1);

    await tester.pump(shellRehomeSettle);
    sessions.wakeAll();
    await _pumpDial(tester);
    sessions.wakeAll(network: true);
    await _pumpDial(tester);
    sessions.wakeAll(network: true);
    sessions.wakeAll();
    await _pumpDial(tester);
    expect(connection.rehomes, 4);
    expect(connection.networkRehomes, 2);

    await sessions.close(_rose.id, session);
  });

  testWidgets('a tab out of sight past the grace sleeps until the return', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    final session = sessions.open(_rose)!;
    await _pumpDial(tester);
    final connection = transport.opened.single;

    sessions.leave();
    await tester.pump(const Duration(seconds: 5));
    sessions.returned();
    await tester.pump(const Duration(seconds: 10));
    expect(connection.suspends, 0);

    sessions.leave();
    await tester.pump(const Duration(seconds: 10));
    expect(connection.suspends, 1);
    final asked = connection.execs.length;

    sessions
      ..returned()
      ..wakeAll();
    await _pumpDial(tester);
    expect(connection.resumes, 1);
    expect(connection.rehomes, 0);
    expect(connection.execs.length, asked + 1);
    expect(session.state, isA<ShellLive>());

    await sessions.close(_rose.id, session);
  });

  testWidgets('a second wake inside a second of the first rehomes nothing', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    final session = sessions.open(_rose)!;
    await _pumpDial(tester);

    sessions.wakeAll();
    await _pumpDial(tester);
    sessions.wakeAll();
    await _pumpDial(tester);
    expect(transport.opened.single.rehomes, 1);

    await tester.pump(shellRehomeSettle);
    sessions.wakeAll();
    await _pumpDial(tester);
    expect(transport.opened.single.rehomes, 2);

    await sessions.close(_rose.id, session);
  });

  testWidgets('a wake is the first of a fresh schedule, not one dial', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    final session = sessions.open(_rose)!;
    await _pumpDial(tester);

    await _spend(tester, transport, session);
    final spent = transport.verifiers.length;
    sessions.wakeAll();
    await _pumpDial(tester);

    expect(transport.verifiers, hasLength(spent + 1));
    expect(session.state, isA<ShellDropped>());
    expect((session.state as ShellDropped).attempt, 2);

    transport.refuse = null;
    await tester.pump(shellReconnectDelays[1]);
    await _pumpDial(tester);
    expect(session.state, isA<ShellLive>());

    await sessions.close(_rose.id, session);
  });

  testWidgets('a wait that ran out while the phone slept dials on the wake', (
    tester,
  ) async {
    var clock = DateTime(2026, 9, 24, 8);
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport, now: () => clock);
    final session = sessions.open(_rose)!;
    await _pumpDial(tester);

    transport.refuse = const ShellFailure(ShellFailureKind.unreachable);
    transport.opened.single.drop();
    await tester.pump();
    for (final delay in shellReconnectDelays.take(5)) {
      clock = clock.add(delay);
      await tester.pump(delay);
      await _pumpDial(tester);
    }
    expect((session.state as ShellDropped).attempt, 6);
    final spent = transport.verifiers.length;

    clock = clock.add(const Duration(minutes: 5));
    sessions.wakeAll();
    await _pumpDial(tester);
    var awake = Duration.zero;
    while (transport.verifiers.length == spent &&
        awake < shellReconnectDelays.last) {
      await tester.pump(const Duration(seconds: 1));
      awake += const Duration(seconds: 1);
    }
    await _pumpDial(tester);

    expect(awake, Duration.zero);
    expect(transport.verifiers, hasLength(spent + 1));
    expect(session.state, isA<ShellWaiting>());

    await sessions.close(_rose.id, session);
  });

  testWidgets('a live tab and a tab that failed on an answer are not woken', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    final live = sessions.open(_rose)!;
    await _pumpDial(tester);

    transport.refuse = const ShellFailure(ShellFailureKind.hostKeyChanged);
    final refused = sessions.open(_nyx)!;
    await _pumpDial(tester);
    transport.refuse = null;
    final dialled = transport.verifiers.length;

    sessions.wakeAll();
    await _pumpDial(tester);

    expect(live.state, isA<ShellLive>());
    expect(refused.state, isA<ShellFailed>());
    expect(transport.verifiers, hasLength(dialled));

    await sessions.close(_rose.id, live);
    await sessions.close(_nyx.id, refused);
  });

  testWidgets('a sheet holds every wake until it comes down', (tester) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    final session = sessions.open(_rose)!;
    await _pumpDial(tester);

    await _spend(tester, transport, session);
    transport.refuse = null;
    final spent = transport.verifiers.length;

    final release = sessions.hold();
    final second = sessions.hold();
    sessions.wakeAll();
    await _pumpDial(tester);

    expect(transport.verifiers, hasLength(spent));
    expect(session.state, isA<ShellWaiting>());

    release();
    sessions.wakeAll();
    await _pumpDial(tester);
    expect(transport.verifiers, hasLength(spent));

    second();
    sessions.wakeAll();
    await _pumpDial(tester);
    expect(session.state, isA<ShellLive>());

    await sessions.close(_rose.id, session);
  });

  testWidgets('STOP on a waiting tab ends it on the words it was showing', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    final session = sessions.open(_rose)!;
    await _pumpDial(tester);

    await _spend(tester, transport, session);
    sessions.stopReconnect(session);
    transport.refuse = null;
    final spent = transport.verifiers.length;

    expect(session.state, isA<ShellFailed>());
    expect((session.state as ShellFailed).kind, ShellFailureKind.unreachable);

    sessions.wakeAll();
    await _pumpDial(tester);
    expect(transport.verifiers, hasLength(spent));

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

    expect(session.state, isA<ShellFailed>());
    expect(
      (session.state as ShellFailed).kind,
      ShellFailureKind.hostKeyUnverified,
    );

    await sessions.close(_rose.id, session);
  });

  group('a passphrase the host asks for', () {
    const id = '0123456789abcdef';
    String osc(Map<String, Object?> payload) =>
        '\x1b]7771;pin;$id;${base64Encode(utf8.encode(jsonEncode(payload)))}\x07';

    test(
      'a request becomes the tab\'s, and done for its id clears it',
      () async {
        final transport = FakeShellTransport();
        final sessions = fakeShellSessions(transport);
        final session = sessions.open(_rose)!;
        await _settle();
        final connection = transport.opened.single;
        var told = 0;
        session.addListener(() => told++);

        connection.emit(
          osc({
            'mode': 'pin',
            'desc': 'Please enter the passphrase\n  SHA256:abc',
            'prompt': 'Passphrase:',
            'error': 'Bad Passphrase (try 2 of 3)',
          }),
        );
        await _settle();
        final request = session.pin!;
        expect(request.id, id);
        expect(request.desc, 'Please enter the passphrase\n  SHA256:abc');
        expect(request.promptLabel, 'PASSPHRASE');
        expect(request.error, 'Bad Passphrase (try 2 of 3)');
        expect(request.okLabel, 'UNLOCK');
        expect(request.cancelLabel, 'CANCEL');
        expect(told, 1);
        expect(_text(session.terminal), isNot(contains('7771')));

        connection.emit('\x1b]7771;done;fedcba9876543210\x07');
        await _settle();
        expect(session.pin, isNotNull);

        connection.emit('\x1b]7771;done;$id\x07');
        await _settle();
        expect(session.pin, isNull);
        expect(told, 2);

        await sessions.close(_rose.id, session);
      },
    );

    test('a confirm carries the agent\'s own labels', () async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      final session = sessions.open(_rose)!;
      await _settle();

      transport.opened.single.emit(
        osc({
          'mode': 'confirm',
          'desc': 'Really?',
          'ok': '_Yes',
          'cancel': '_No',
        }),
      );
      await _settle();
      expect(session.pin!.okLabel, 'YES');
      expect(session.pin!.cancelLabel, 'NO');
      expect(session.pin!.promptLabel, 'PASSPHRASE');

      await sessions.close(_rose.id, session);
    });

    test(
      'a shell that comes up marks its pty, then asks what is open',
      () async {
        final transport = FakeShellTransport();
        final sessions = fakeShellSessions(transport);
        final session = sessions.open(_rose)!;
        await _settle();

        final execs = transport.opened.single.execs;
        expect(execs.map((exec) => exec.command), [
          pinentryMarkCommand(session.tab),
          pinentryOpenCommand(),
        ]);
        expect(execs.map((exec) => exec.stdin), everyElement(isNull));

        await sessions.close(_rose.id, session);
      },
    );

    test('a request already open is found as the tab comes up', () async {
      final transport = FakeShellTransport();
      final payload = base64Encode(
        utf8.encode(jsonEncode({'mode': 'pin', 'desc': 'the key'})),
      );
      transport.opening = (connection) =>
          connection.answerWith('$id $payload\n');
      final sessions = fakeShellSessions(transport);
      final session = sessions.open(_rose)!;
      await _settle();
      await _settle();

      expect(session.pin?.id, id);
      expect(session.pin?.desc, 'the key');

      await sessions.close(_rose.id, session);
    });

    test('a bell asks the host what is open and takes the answer', () async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      final session = sessions.open(_rose)!;
      await _settle();
      final connection = transport.opened.single;
      final payload = base64Encode(
        utf8.encode(jsonEncode({'mode': 'pin', 'desc': 'the key'})),
      );
      connection.answerWith('../x $payload\n$id $payload\n');

      connection.emit('\x07');
      await _settle();
      await _settle();

      expect(connection.execs.last.command, pinentryOpenCommand());
      expect(connection.execs.last.stdin, isNull);
      expect(session.pin?.id, id);
      expect(session.pin?.desc, 'the key');

      await sessions.close(_rose.id, session);
    });

    test('a bell with nothing open withdraws the request', () async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      final session = sessions.open(_rose)!;
      await _settle();
      final connection = transport.opened.single;

      connection.emit(osc({'mode': 'pin'}));
      await _settle();
      expect(session.pin, isNotNull);

      connection.emit('\x07');
      await _settle();
      await _settle();
      expect(session.pin, isNull);

      await sessions.close(_rose.id, session);
    });

    test(
      'bells that land while the host is asked fold into one more',
      () async {
        final transport = FakeShellTransport();
        final sessions = fakeShellSessions(transport);
        final session = sessions.open(_rose)!;
        await _settle();
        final connection = transport.opened.single;
        final quiet = connection.execs
            .where((exec) => exec.command == pinentryOpenCommand())
            .length;

        connection.emit('\x07\x07\x07\x07');
        await _settle();
        await _settle();
        await _settle();

        final asks = connection.execs
            .where((exec) => exec.command == pinentryOpenCommand())
            .length;
        expect(asks - quiet, 2);

        await sessions.close(_rose.id, session);
      },
    );

    test('a shell that comes up out of sight asks on the return', () async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(
        transport,
        sleepGrace: const Duration(milliseconds: 10),
      );
      sessions.leave();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final session = sessions.open(_rose)!;
      await _settle();
      final connection = transport.opened.single;

      expect(connection.execs.map((exec) => exec.command), [
        pinentryMarkCommand(session.tab),
      ]);
      expect(connection.suspends, 1);

      sessions.returned();
      await _settle();
      expect(connection.resumes, 1);
      expect(connection.execs.last.command, pinentryOpenCommand());

      await sessions.close(_rose.id, session);
    });

    test('a tab holding a request does not ask while asleep', () async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(
        transport,
        sleepGrace: const Duration(milliseconds: 20),
        pinRecheck: const Duration(milliseconds: 10),
      );
      final session = sessions.open(_rose)!;
      await _settle();
      final connection = transport.opened.single;
      final payload = base64Encode(
        utf8.encode(jsonEncode({'mode': 'pin', 'desc': 'the key'})),
      );
      int asks() => connection.execs
          .where((exec) => exec.command == pinentryOpenCommand())
          .length;
      connection.answerWith('$id $payload\n');
      connection.emit('\x07');
      await _settle();
      expect(session.pin?.id, id);

      sessions.leave();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      final asleep = asks();
      connection.emit('\x07');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(asks(), asleep);

      sessions.returned();
      await _settle();
      expect(asks(), greaterThan(asleep));

      await sessions.close(_rose.id, session);
    });

    test('a tab holding a request asks again until it is gone', () async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(
        transport,
        pinRecheck: const Duration(milliseconds: 10),
      );
      final session = sessions.open(_rose)!;
      await _settle();
      final connection = transport.opened.single;
      final payload = base64Encode(
        utf8.encode(jsonEncode({'mode': 'pin', 'desc': 'the key'})),
      );
      int asks() => connection.execs
          .where((exec) => exec.command == pinentryOpenCommand())
          .length;

      final quiet = asks();
      connection.answerWith('$id $payload\n');
      connection.emit('\x07');
      await _settle();
      await _settle();
      expect(session.pin?.id, id);
      expect(asks(), quiet + 1);

      await Future<void>.delayed(const Duration(milliseconds: 35));
      expect(asks(), greaterThan(1));
      expect(session.pin?.id, id);

      connection.answerWith('');
      await Future<void>.delayed(const Duration(milliseconds: 35));
      expect(session.pin, isNull);
      final settled = asks();
      await Future<void>.delayed(const Duration(milliseconds: 35));
      expect(asks(), settled);

      await sessions.close(_rose.id, session);
    });

    test('an answer settles the request on every tab of the host', () async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      final first = sessions.open(_rose)!;
      final second = sessions.open(_rose)!;
      await _settle();
      final connections = transport.opened;
      connections[0].emit(osc({'mode': 'pin'}));
      connections[1].emit(osc({'mode': 'pin'}));
      await _settle();
      expect(first.pin?.id, id);
      expect(second.pin?.id, id);

      await sessions.answerPin(first, 'hunter2');
      expect(first.pin, isNull);
      expect(second.pin, isNull);
      expect(
        connections[1].execs.map((exec) => exec.command),
        isNot(contains(pinentryAnswerCommand(id))),
      );

      await sessions.close(_rose.id, first);
      await sessions.close(_rose.id, second);
    });

    test('an answer goes down the fifo on stdin, never on the line', () async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      final session = sessions.open(_rose)!;
      await _settle();
      final connection = transport.opened.single;

      connection.emit(osc({'mode': 'pin'}));
      await _settle();
      await sessions.answerPin(session, 'hunter2');

      expect(session.pin, isNull);
      final answer = connection.execs.last;
      expect(answer.command, pinentryAnswerCommand(id));
      expect(answer.command, isNot(contains('hunter2')));
      expect(utf8.decode(answer.stdin!), 'hunter2\n');

      await sessions.close(_rose.id, session);
    });

    test('a cancel is the bare newline', () async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      final session = sessions.open(_rose)!;
      await _settle();
      final connection = transport.opened.single;

      connection.emit(osc({'mode': 'pin'}));
      await _settle();
      await sessions.answerPin(session, null);

      expect(session.pin, isNull);
      expect(connection.execs.last.command, pinentryAnswerCommand(id));
      expect(connection.execs.last.stdin, [0x0a]);

      await sessions.close(_rose.id, session);
    });

    test(
      'an id that is not hex is no request, and nothing runs for it',
      () async {
        final transport = FakeShellTransport();
        final sessions = fakeShellSessions(transport);
        final session = sessions.open(_rose)!;
        await _settle();
        final connection = transport.opened.single;

        final payload = base64Encode(utf8.encode(jsonEncode({'mode': 'pin'})));
        connection.emit('\x1b]7771;pin;../x;$payload\x07');
        connection.emit('\x1b]7771;pin;$id;not base64!\x07');
        connection.emit('\x1b]7771;pin;$id\x07');
        await _settle();
        expect(session.pin, isNull);

        await sessions.answerPin(session, 'hunter2');
        expect(connection.execs.map((exec) => exec.command), [
          pinentryMarkCommand(session.tab),
          pinentryOpenCommand(),
        ]);

        await sessions.close(_rose.id, session);
      },
    );

    testWidgets('a shell that comes back marks again and forgets the request', (
      tester,
    ) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      final session = sessions.open(_rose)!;
      await _pumpDial(tester);
      transport.opened.single.emit(osc({'mode': 'pin'}));
      await _pumpDial(tester);
      expect(session.pin, isNotNull);

      transport.opened.single.drop();
      await tester.pump();
      expect(session.pin, isNull);

      await tester.pump(shellReconnectDelays.first);
      await _pumpDial(tester);
      expect(session.state, isA<ShellLive>());
      expect(transport.opened, hasLength(2));
      expect(transport.opened.last.execs.map((exec) => exec.command), [
        pinentryMarkCommand(session.tab),
        pinentryOpenCommand(),
      ]);

      await sessions.close(_rose.id, session);
    });

    test('a shell that exits takes its request with it', () async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      final session = sessions.open(_rose)!;
      await _settle();
      final connection = transport.opened.single;

      connection.emit(osc({'mode': 'pin'}));
      await _settle();
      expect(session.pin, isNotNull);
      connection.exit(0);
      await _settle();
      expect(session.pin, isNull);

      await sessions.close(_rose.id, session);
    });

    test('an ask that keeps standing past its window may be over', () async {
      final shade = _Shade();
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(
        transport,
        notifier: shade,
        pinRecheck: const Duration(milliseconds: 10),
        pinStale: const Duration(milliseconds: 40),
      );
      final session = sessions.open(_rose)!;
      await _settle();
      final connection = transport.opened.single;
      final payload = base64Encode(
        utf8.encode(jsonEncode({'mode': 'pin', 'desc': 'the key'})),
      );

      connection.answerWith('$id $payload\n');
      connection.emit('\x07');
      await _settle();
      await _settle();
      expect(session.pin?.id, id);
      expect(session.pin?.stale, isFalse);

      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(session.pin?.id, id);
      expect(session.pin?.stale, isTrue);
      expect(shade.events, ['up h1 ROSE · the key']);

      await sessions.close(_rose.id, session);
    });

    test('an answer the host had already taken down is expired', () async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      final session = sessions.open(_rose)!;
      await _settle();
      final connection = transport.opened.single;

      connection.emit(osc({'mode': 'pin'}));
      await _settle();
      connection.answer = (command, _) => ExecResult(
        exitCode: command == pinentryAnswerCommand(id) ? 1 : 0,
        stdout: Uint8List(0),
        stderr: Uint8List(0),
      );

      expect(await sessions.answerPin(session, 'hunter2'), PinAnswer.expired);
      expect(session.pin, isNull);

      await sessions.close(_rose.id, session);
    });

    test('an answer the fifo took is sent', () async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      final session = sessions.open(_rose)!;
      await _settle();
      final connection = transport.opened.single;

      connection.emit(osc({'mode': 'pin'}));
      await _settle();

      expect(await sessions.answerPin(session, 'hunter2'), PinAnswer.sent);

      await sessions.close(_rose.id, session);
    });

    test('an answer that reaches a fifo nobody reads is expired', () async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(
        transport,
        pinAnswerWait: const Duration(milliseconds: 20),
      );
      final session = sessions.open(_rose)!;
      await _settle();
      final connection = transport.opened.single;

      connection.emit(osc({'mode': 'pin'}));
      await _settle();
      // The pinentry died without taking its fifo down, so the guard passes and the write
      // waits for a reader that is never coming.
      connection.wedged = true;

      expect(await sessions.answerPin(session, 'hunter2'), PinAnswer.expired);
      expect(session.pin, isNull);

      await sessions.close(_rose.id, session);
    });

    test('an answer the link swallowed is lost', () async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      final session = sessions.open(_rose)!;
      await _settle();
      final connection = transport.opened.single;

      connection.emit(osc({'mode': 'pin'}));
      await _settle();
      connection.answer = (command, _) {
        if (command == pinentryAnswerCommand(id)) throw 'link lost';
        return ExecResult(
          exitCode: 0,
          stdout: Uint8List(0),
          stderr: Uint8List(0),
        );
      };

      expect(await sessions.answerPin(session, 'hunter2'), PinAnswer.lost);

      await sessions.close(_rose.id, session);
    });
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
    sessions.arm(session, {StickyModifier.ctrl}, locked: true);
    sessions.stopReconnect(session);
    await tester.pump(const Duration(minutes: 1));

    expect(session.state, isA<ShellFailed>());
    expect(session.sticky, isEmpty);
    expect(session.stickyLocked, isFalse);
    expect(transport.opened, hasLength(1));

    await sessions.close(_rose.id, session);
  });

  testWidgets('a dead shell drops a latched modifier', (tester) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    final session = sessions.open(_rose)!;
    await _pumpDial(tester);
    sessions.arm(session, {StickyModifier.alt}, locked: true);

    transport.opened.single.exit(130);
    await _pumpDial(tester);

    expect(session.state, isA<ShellExited>());
    expect(session.sticky, isEmpty);
    expect(session.stickyLocked, isFalse);

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

      final transport = FakeShellTransport();
      final after = fakeShellSessions(transport, tabs: tabs);
      expect(await after.restore(hosts), 3);

      expect(after.forHost(_rose.id).map((session) => session.number), [1, 2]);
      expect(after.forHost(_nyx.id).map((session) => session.number), [1]);
      await _settle();
      expect(transport.opened, hasLength(3));
      expect(transport.persistentSessions, [null, null, null]);
      expect(
        _text(after.forHost(_rose.id).first.terminal),
        contains('-- reconnected --'),
      );
      expect(after.activeFor(_rose.id)!.number, 1);
    });

    test('moved tabs and groups come back where they were put', () async {
      final tabs = InMemoryShellTabRepository();
      final before = fakeShellSessions(FakeShellTransport(), tabs: tabs);
      before.open(_rose);
      before.open(_nyx);
      before.open(_nyx);
      before.open(_nyx);
      before.moveTab(_nyx.id, 0, 2);
      before.moveGroup(1, 0);
      await _settle();
      before.open(_nyx);
      before.open(_rose);
      await _settle();

      final after = fakeShellSessions(FakeShellTransport(), tabs: tabs);
      await after.restore(hosts);

      expect(
        [for (final (host, _) in after.openHosts) host.id],
        [_nyx.id, _rose.id],
      );
      expect(after.forHost(_nyx.id).map((session) => session.number), [
        2,
        3,
        1,
        4,
      ]);
      expect(after.forHost(_rose.id).map((session) => session.number), [1, 2]);
      await _settle();
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

    test('leaving saves each screen and a killed app draws it again', () async {
      final tabs = InMemoryShellTabRepository();
      final snapshots = InMemoryShellSnapshotStore();
      final transport = FakeShellTransport();
      final before = fakeShellSessions(
        transport,
        tabs: tabs,
        snapshots: snapshots,
      );
      before.open(_rose);
      await _settle();
      transport.opened.single.emit('build finished\r\n');
      await _settle();
      before.leave();
      await _settle();
      expect(snapshots.snapshots.keys, [(_rose.id, 1)]);

      final after = fakeShellSessions(
        FakeShellTransport(),
        tabs: tabs,
        snapshots: snapshots,
      );
      await after.restore(hosts);
      await after.forHost(_rose.id).single.terminal.restored;
      await _settle();

      final text = _text(after.forHost(_rose.id).single.terminal);
      expect(text, contains('build finished'));
      expect(
        text.indexOf('build finished'),
        lessThan(text.indexOf('-- reconnected --')),
      );
    });

    test('output while away is saved once it rests', () async {
      final snapshots = InMemoryShellSnapshotStore();
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(
        transport,
        snapshots: snapshots,
        snapshotQuiet: const Duration(milliseconds: 10),
      );
      sessions.open(_rose);
      await _settle();
      sessions.leave();
      await _settle();
      final left = snapshots.snapshots[(_rose.id, 1)];

      transport.opened.single.emit('tests passed\r\n');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final rested = snapshots.snapshots[(_rose.id, 1)];
      expect(rested, isNot(same(left)));

      sessions.returned();
      transport.opened.single.emit('back on screen\r\n');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(snapshots.snapshots[(_rose.id, 1)], same(rested));
    });

    test('closing a tab drops its screen', () async {
      final snapshots = InMemoryShellSnapshotStore();
      final sessions = fakeShellSessions(
        FakeShellTransport(),
        snapshots: snapshots,
      );
      final session = sessions.open(_rose)!;
      await _settle();
      sessions.leave();
      await _settle();
      expect(snapshots.snapshots, isNotEmpty);

      await sessions.close(_rose.id, session);
      await _settle();
      expect(snapshots.snapshots, isEmpty);
    });

    test(
      'a screen that does not read back opens blank and is dropped',
      () async {
        final tabs = InMemoryShellTabRepository();
        await tabs.open(_rose.id, 1);
        final snapshots = InMemoryShellSnapshotStore()
          ..snapshots[(_rose.id, 1)] = Uint8List.fromList([1, 2, 3])
          ..snapshots[(_rose.id, 7)] = Uint8List.fromList([4, 5, 6]);

        final sessions = fakeShellSessions(
          FakeShellTransport(),
          tabs: tabs,
          snapshots: snapshots,
        );
        expect(await sessions.restore(hosts), 1);
        await _settle();

        expect(sessions.forHost(_rose.id).single.terminal, isNotNull);
        expect(snapshots.snapshots, isEmpty);
      },
    );

    test('a restored tab dials unattended', () async {
      final tabs = InMemoryShellTabRepository();
      await tabs.open(_rose.id, 1);

      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport, tabs: tabs);
      await sessions.restore(hosts);
      await _settle();

      expect(transport.verifiers.single!.prompt, isNull);
    });

    test('agent panes do not claim a second remote multiplexer', () async {
      const pane = (session: 'work', pane: '%3');
      final tabs = InMemoryShellTabRepository();
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport, tabs: tabs);

      final session = sessions.open(
        _rose,
        command: 'herdr agent attach work %3',
        pane: pane,
      )!;
      await _settle();

      expect(session.remoteSession, isNotNull);
      expect(transport.tabSessions.single, session.remoteSession);
      expect(transport.persistentSessions.single, isNull);
      final row = (await tabs.all()).single;
      expect(row.remoteSession, session.remoteSession);
      expect(row.herdrSession, pane.session);
      expect(row.herdrPane, pane.pane);
    });

    test('a remote identity is stored before its first dial', () async {
      final tabs = _DelayedShellTabs();
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport, tabs: tabs);

      final session = sessions.open(_rose)!;
      await _settle();

      expect(tabs.started, isTrue);
      expect(transport.opened, isEmpty);

      tabs.release.complete();
      await _settle();
      await _settle();

      expect(transport.opened, hasLength(1));
      expect((await tabs.all()).single.remoteSession, session.remoteSession);
    });

    test('a killed app reattaches the exact Herdr pane', () async {
      const pane = (session: 'work', pane: 'w2a:p3');
      final tabs = InMemoryShellTabRepository();
      final before = fakeShellSessions(FakeShellTransport(), tabs: tabs);
      before.open(_rose, command: HerdrCommands.attach(pane), pane: pane);
      await _settle();

      final transport = FakeShellTransport();
      final after = fakeShellSessions(transport, tabs: tabs);
      expect(await after.restore(hosts), 1);
      await _settle();

      final restored = after.forHost(_rose.id).single;
      expect(restored.pane, pane);
      expect(restored.command, HerdrCommands.attach(pane));
      expect(after.holding(_rose.id, pane), same(restored));
      expect(
        transport.commands.single,
        shellMarked(restored.mark, command: HerdrCommands.attach(pane)),
      );
      expect(transport.persistentSessions.single, isNull);
      expect(_text(restored.terminal), contains('-- session restored --'));
    });

    test('a killed app reruns the tmux or herdr start it had', () async {
      final tabs = InMemoryShellTabRepository();
      await tabs.open(_rose.id, 1, launch: 'tmux:tests-restore');
      await tabs.open(_rose.id, 2, launch: 'herdr:work');
      await tabs.open(_rose.id, 3, launch: 'herdr:default');

      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport, tabs: tabs);
      expect(await sessions.restore(hosts), 3);
      await _settle();

      final restored = sessions.forHost(_rose.id);
      expect(restored.map((session) => session.command), [
        "exec tmux new-session -A -s 'tests-restore'",
        "exec herdr --session 'work'",
        'exec herdr',
      ]);
      expect(transport.commands, [
        for (final session in restored)
          shellMarked(session.mark, command: session.command),
      ]);
      expect((await tabs.all()).map((tab) => tab.launch), [
        'tmux:tests-restore',
        'herdr:work',
        'herdr:default',
      ]);
    });

    testWidgets('a restored tmux tab redials into the same session', (
      tester,
    ) async {
      final tabs = InMemoryShellTabRepository();
      await tabs.open(_rose.id, 1, launch: 'tmux:tests-restore');

      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport, tabs: tabs);
      await sessions.restore(hosts);
      await _pumpDial(tester);
      final session = sessions.forHost(_rose.id).single;

      transport.opened.single.drop();
      await tester.pump();
      await tester.pump(shellReconnectDelays.first);
      await _pumpDial(tester);

      expect(session.state, isA<ShellLive>());
      expect(transport.commands, hasLength(2));
      expect(
        transport.commands.last,
        shellMarked(
          session.mark,
          command: "exec tmux new-session -A -s 'tests-restore'",
        ),
      );

      await sessions.close(_rose.id, session);
    });

    test('a tab cannot partially name a Herdr pane', () async {
      final tabs = InMemoryShellTabRepository();

      await expectLater(
        tabs.open(_rose.id, 1, herdrSession: 'work'),
        throwsArgumentError,
      );
    });

    test('a close kills its remote shell before forgetting the row', () async {
      final tabs = InMemoryShellTabRepository();
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport, tabs: tabs);
      final session = sessions.open(_rose)!;
      await _settle();

      await sessions.close(_rose.id, session);

      expect(transport.opened.single.terminated, [
        (session: session.remoteSession!, durableShell: false),
      ]);
      expect(await tabs.all(), isEmpty);
      expect(await tabs.retired(_rose.id), isEmpty);
    });

    test('a failed close is reaped through the next host connection', () async {
      final tabs = InMemoryShellTabRepository();
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport, tabs: tabs);
      final first = sessions.open(_rose)!;
      await _settle();
      transport.opened.single.terminateRemoteResult = false;

      await sessions.close(_rose.id, first);

      expect(await tabs.all(), isEmpty);
      expect(
        (await tabs.retired(_rose.id)).single.remoteSession,
        first.remoteSession,
      );

      final second = sessions.open(_rose)!;
      await _settle();
      await _settle();

      expect(
        transport.opened.last.terminated,
        contains((session: first.remoteSession!, durableShell: false)),
      );
      expect(await tabs.retired(_rose.id), isEmpty);

      await sessions.close(_rose.id, second);
    });
  });

  group('a session lets go of what it owns', () {
    /// A listenable that has been disposed refuses a new listener, which is the only thing
    /// one says about itself from the outside.
    void expectDisposed(Listenable notifier, String what) {
      expect(
        () => notifier.addListener(() {}),
        throwsFlutterError,
        reason: '$what should be disposed',
      );
    }

    void expectAlive(Listenable notifier, String what) {
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
      expectAlive(session.terminal, 'the terminal');

      await tester.pump();
      expectDisposed(session.terminal, 'the terminal');
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

      expectDisposed(first.terminal, "the closed tab's controller");
      expectAlive(second.terminal, "the open tab's controller");
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
      expectDisposed(session.terminal, "the exited tab's controller");
      expectDisposed(session.scrollController, "the exited tab's scroll");
    });

    testWidgets('the view drawing the closed tab detaches without raising', (
      tester,
    ) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            shellSessionsProvider.overrideWithValue(sessions),
            noWorkspaces,
          ],
          child: MaterialApp(
            theme: testTheme,
            home: HostShellRoute(host: _rose),
          ),
        ),
      );
      await tester.pump();
      final first = sessions.forHost(_rose.id).single;
      final second = sessions.open(_rose)!;
      await _pumpDial(tester);
      await tester.pump();

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
          theme: testTheme,
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

      expect(find.text('htop'), findsOneWidget);
      expect(storeSaid, 0);

      await tester.pumpWidget(const SizedBox.shrink());
      await sessions.close(_rose.id, first);
      await sessions.close(_rose.id, second);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    });
  });
  group('the shade is told', () {
    const id = '0123456789abcdef';
    String request({
      String requestId = id,
      String desc = 'the key',
      String prompt = '',
    }) {
      final payload = base64Encode(
        utf8.encode(
          jsonEncode({'mode': 'pin', 'desc': desc, 'prompt': prompt}),
        ),
      );
      return '\x1b]7771;pin;$requestId;$payload\x07';
    }

    test('once per host, naming the host and the key', () async {
      final shade = _Shade();
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport, notifier: shade);
      final first = sessions.open(_rose)!;
      final second = sessions.open(_rose)!;
      await _settle();
      transport.opened[0].emit(request());
      transport.opened[1].emit(request());
      await _settle();

      expect(shade.events, ['up h1 ROSE · the key']);

      await sessions.close(_rose.id, first);
      await sessions.close(_rose.id, second);
    });

    test('down once the last tab of the host lets go', () async {
      final shade = _Shade();
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport, notifier: shade);
      final first = sessions.open(_rose)!;
      final second = sessions.open(_rose)!;
      await _settle();
      transport.opened[0].emit(request());
      transport.opened[1].emit(request());
      await _settle();

      transport.opened[0].emit('\x1b]7771;done;$id\x07');
      await _settle();
      expect(shade.events, hasLength(1));

      transport.opened[1].emit('\x1b]7771;done;$id\x07');
      await _settle();
      expect(shade.events, ['up h1 ROSE · the key', 'down h1']);

      await sessions.close(_rose.id, first);
      await sessions.close(_rose.id, second);
    });

    test('down on the answer, whichever tab gives it', () async {
      final shade = _Shade();
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport, notifier: shade);
      final first = sessions.open(_rose)!;
      final second = sessions.open(_rose)!;
      await _settle();
      transport.opened[0].emit(request());
      transport.opened[1].emit(request());
      await _settle();

      await sessions.answerPin(second, 'hunter2');
      expect(shade.events, ['up h1 ROSE · the key', 'down h1']);

      await sessions.close(_rose.id, first);
      await sessions.close(_rose.id, second);
    });

    test('down when the tab holding it closes', () async {
      final shade = _Shade();
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport, notifier: shade);
      final session = sessions.open(_rose)!;
      await _settle();
      transport.opened.single.emit(request());
      await _settle();

      await sessions.close(_rose.id, session);
      expect(shade.events, ['up h1 ROSE · the key', 'down h1']);
    });

    test('another request replaces it in place', () async {
      final shade = _Shade();
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport, notifier: shade);
      final session = sessions.open(_rose)!;
      await _settle();
      transport.opened.single.emit(request());
      transport.opened.single.emit(
        request(requestId: 'fedcba9876543210', desc: 'the other key'),
      );
      await _settle();

      expect(shade.events, [
        'up h1 ROSE · the key',
        'up h1 ROSE · the other key',
      ]);

      await sessions.close(_rose.id, session);
    });

    test('the prompt stands in when the agent described nothing', () async {
      final shade = _Shade();
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport, notifier: shade);
      final session = sessions.open(_rose)!;
      await _settle();
      transport.opened.single.emit(request(desc: '', prompt: 'Passphrase:'));
      await _settle();

      expect(shade.events, ['up h1 ROSE · Passphrase:']);

      await sessions.close(_rose.id, session);
    });
  });
}

class _Shade implements PinNotifier {
  final events = <String>[];

  @override
  Future<void> raise({
    required String hostId,
    required String askId,
    required String text,
  }) async {
    events.add('up $hostId $text');
  }

  @override
  Future<void> withdraw(String hostId) async {
    events.add('down $hostId');
  }
}
