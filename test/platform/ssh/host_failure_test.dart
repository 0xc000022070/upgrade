import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/platform/herdr/herdr_socket.dart';
import 'package:upgrade/platform/shell/shell_connection.dart';
import 'package:upgrade/platform/shell/shell_tunnel.dart';
import 'package:upgrade/platform/ssh/host_failure.dart';
import 'package:upgrade/platform/ssh/host_keys.dart';
import 'package:upgrade/platform/vnc/vnc_failure.dart';

void main() {
  const lookup = SocketException(
    "Failed host lookup: 'nope.invalid'",
    osError: OSError('No address associated with hostname', -5),
  );
  const refused = SocketException(
    'Connection refused',
    osError: OSError('Connection refused', 111),
  );

  final table = <(String, Object, HostKeyRefusal?, HostFailureKind?)>[
    ('lookup', lookup, null, HostFailureKind.unresolved),
    ('refused socket', refused, null, HostFailureKind.unreachable),
    (
      'socket timeout',
      const SocketException('Connection timed out'),
      null,
      HostFailureKind.unreachable,
    ),
    ('timeout', TimeoutException(null), null, HostFailureKind.unreachable),
    (
      'lookup under ssh',
      SSHSocketError(lookup),
      null,
      HostFailureKind.unresolved,
    ),
    (
      'unknown under ssh',
      SSHSocketError(StateError('x')),
      null,
      HostFailureKind.unreachable,
    ),
    (
      'auth failed',
      SSHAuthFailError('no more auth methods'),
      null,
      HostFailureKind.keyRejected,
    ),
    ('bad key', SSHKeyDecodeError('x'), null, HostFailureKind.keyRejected),
    ('host key', SSHHostkeyError('x'), null, HostFailureKind.hostKeyChanged),
    (
      'host key under auth',
      SSHAuthAbortError('x', SSHHostkeyError('x')),
      null,
      HostFailureKind.hostKeyChanged,
    ),
    (
      'auth cut short',
      SSHAuthAbortError('x'),
      null,
      HostFailureKind.streamClosed,
    ),
    (
      'state',
      SSHStateError('connection closed'),
      null,
      HostFailureKind.streamClosed,
    ),
    (
      'channel open',
      SSHChannelOpenError(1, 'administratively prohibited'),
      null,
      HostFailureKind.refused,
    ),
    (
      'refusal wins',
      SSHStateError('connection closed'),
      HostKeyRefusal.unverified,
      HostFailureKind.hostKeyUnverified,
    ),
    (
      'changed refusal',
      refused,
      HostKeyRefusal.changed,
      HostFailureKind.hostKeyChanged,
    ),
    ('herdr reply', const HerdrMalformed('x'), null, null),
    ('a bug', StateError('mine'), null, null),
  ];

  for (final (name, error, refusal, kind) in table) {
    test('$name reads as ${kind?.name}', () {
      expect(classifyHostFailure(error, refusal), kind);
    });
  }

  test('herdr unwraps what the shell unwraps', () {
    expect(asHerdrFailure(SSHSocketError(lookup)), isA<HerdrUnresolved>());
    expect(
      asHerdrFailure(SSHAuthAbortError('x', SSHHostkeyError('x'))),
      isA<HerdrHostKeyChanged>(),
    );
    expect(
      shellFailureFor(SSHSocketError(lookup))?.kind,
      ShellFailureKind.unresolved,
    );
    expect(asVncFailure(SSHSocketError(lookup)), isA<VncUnresolved>());
  });

  test('a refused channel is worded by the surface that asked for it', () {
    final error = SSHChannelOpenError(1, 'administratively prohibited');

    expect(shellFailureFor(error)?.kind, ShellFailureKind.shellRefused);
    expect(asVncFailure(error)!.reason('oak'), 'tunnel refused');
    expect(asHerdrFailure(error), isA<HerdrUnreachable>());
  });
}
