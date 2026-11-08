import 'dart:async';
import 'dart:io';

import 'package:upgrade/platform/ssh/host_failure.dart';
import 'package:upgrade/platform/shell/shell_tunnel.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/host_failure_matchers.dart';

void main() {
  test('a refused socket keeps the system words and drops its own report', () {
    final failure = shellFailureFor(
      SocketException(
        'Connection refused',
        osError: const OSError('Connection refused', 111),
        address: InternetAddress('198.51.100.77'),
        port: 44354,
      ),
    )!;

    expect(failure.kind, HostFailureKind.unreachable);
    expect(failure.detail, 'connection refused');
  });

  test('a socket with no system error keeps its own message', () {
    final failure = shellFailureFor(const SocketException('Connection reset'))!;

    expect(failure.kind, HostFailureKind.unreachable);
    expect(failure.detail, 'connection reset');
  });

  test('a dial that ran out of time says how long it waited', () {
    final failure = shellFailureFor(
      TimeoutException('Future not completed', const Duration(seconds: 10)),
    )!;

    expect(failure.kind, HostFailureKind.unreachable);
    expect(failure.detail, 'no answer in 10s');
    expect(shellFailureFor(TimeoutException(null))!.detail, 'no answer');
  });

  test('a kind a dial cannot end in is left to the retry', () {
    expect(shellFailureFor(const HostFailure.busy()), isNull);
    expect(shellFailureFor(const HostFailure.noEngine()), isNull);
    expect(shellFailureFor(StateError('mine')), isNull);
    expect(
      shellFailureFor(const HostFailure.unreachable()),
      isFailureOf(HostFailureKind.unreachable),
    );
  });
}
