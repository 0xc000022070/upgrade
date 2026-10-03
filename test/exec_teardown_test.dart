import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:dazzle/platform/herdr_client.dart';
import 'package:dazzle/platform/shell/shell_tunnel.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/ssh_exec.dart';

void main() {
  test('a command given up on is ended on the host', () {
    final session = FakeExecSession();

    sshExecOver(session).close();

    expect(session.signals, [SSHSignal.TERM]);
    expect(session.destroyed, 1);
  });

  test(
    'an engine call past its deadline ends the command it started',
    () async {
      final session = FakeExecSession();
      final herdr = HerdrSession.over(
        FakeExecSocket(),
        FakeExecClient(session),
      );

      await expectLater(
        herdr.engine(const {}, within: const Duration(milliseconds: 20)),
        throwsA(isA<TimeoutException>()),
      );

      expect(session.signals, [SSHSignal.TERM]);
      expect(session.destroyed, 1);
    },
  );
}
