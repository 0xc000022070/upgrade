import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotline/data/repositories/host_repository.dart';
import 'package:hotline/features/shell/host_shell_screen.dart';
import 'package:hotline/features/shell/shell_sessions.dart';
import 'package:hotline/platform/shell/shell_connection.dart';

import 'support/fake_shell.dart';

const _rose = Host(
  id: 'h1',
  name: 'rose',
  address: '100.64.0.1',
  port: 22,
  user: 'luis',
  keyId: 'key-1',
);

/// The store dials on a microtask, so every assertion about a connection has
/// to let those run first.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

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

  test('retry reopens in the slot the session already holds', () async {
    final transport = FakeShellTransport()
      ..refuse = const ShellFailure(ShellFailureKind.shellRefused);
    final sessions = fakeShellSessions(transport);

    final session = sessions.open(_rose)!;
    await _settle();
    expect(session.state, isA<ShellFailed>());

    transport.refuse = null;
    // What the failed attempt printed is still on screen behind the reason
    // line, so the terminal is the same object after the retry as before it.
    final terminal = session.terminal;
    await sessions.retry(_rose, session);

    expect(sessions.forHost(_rose.id), [session]);
    expect(session.number, 1);
    expect(session.terminal, same(terminal));
    expect(session.state, isA<ShellLive>());
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
}
