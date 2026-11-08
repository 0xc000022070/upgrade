import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/platform/herdr/herdr_socket.dart';
import 'package:upgrade/platform/shell/shell_tunnel.dart';
import 'package:upgrade/platform/ssh/host_failure.dart';
import 'package:upgrade/platform/ssh/host_keys.dart';
import 'package:upgrade/platform/vnc/vnc_failure.dart';

import '../../support/host_failure_matchers.dart';

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
      HostFailureKind.shellRefused,
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

  test('a refused channel is worded by the surface that asked for it', () {
    final error = SSHChannelOpenError(1, 'administratively prohibited');

    expect(shellFailureFor(error)?.kind, HostFailureKind.shellRefused);
    expect(asVncFailure(error)!.reason('oak'), 'tunnel refused');
    expect(asHostFailure(error), isFailureOf(HostFailureKind.unreachable));
  });

  group('translated for a surface', () {
    for (final (name, error, hostKind, vncKind)
        in <(String, Object, HostFailureKind, HostFailureKind)>[
          (
            'lookup',
            lookup,
            HostFailureKind.unresolved,
            HostFailureKind.unresolved,
          ),
          (
            'auth failed',
            SSHAuthFailError('x'),
            HostFailureKind.keyRejected,
            HostFailureKind.keyRejected,
          ),
          (
            'host key',
            SSHHostkeyError('x'),
            HostFailureKind.hostKeyChanged,
            HostFailureKind.hostKeyChanged,
          ),
          (
            'busy',
            const HostFailure.busy('slots'),
            HostFailureKind.busy,
            HostFailureKind.unreachable,
          ),
          (
            'closed',
            SSHStateError('closed'),
            HostFailureKind.unreachable,
            HostFailureKind.streamClosed,
          ),
          (
            'channel open',
            SSHChannelOpenError(1, 'no'),
            HostFailureKind.unreachable,
            HostFailureKind.tunnelRefused,
          ),
        ]) {
      test(name, () {
        expect(asHostFailure(error), isFailureOf(hostKind));
        expect(asVncFailure(error), isFailureOf(vncKind));
      });
    }

    test('a failure keeps its own detail and a bug stays a bug', () {
      expect(asVncFailure(const HostFailure.busy('slots'))!.detail, 'slots');
      expect(asHostFailure(StateError('mine')), isNull);
      expect(asVncFailure(StateError('mine')), isNull);
    });
  });
}
