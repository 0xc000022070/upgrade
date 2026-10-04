import 'package:dazzle/platform/herdr_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/ssh_exec.dart';

FakeRunClient _exiting(int exitCode, String said) =>
    FakeRunClient((_) => (exitCode: exitCode, stdout: '', stderr: said));

void main() {
  test('a shell that cannot find herdr reads as no herdr', () async {
    final session = HerdrSession.over(
      FakeExecSocket(),
      _exiting(127, 'zsh:1: command not found: herdr'),
    );
    await expectLater(session.list(), throwsA(isA<HerdrMissing>()));
  });

  test('a herdr that fails in its own words is still a protocol', () async {
    final session = HerdrSession.over(
      FakeExecSocket(),
      _exiting(2, 'herdr: unknown flag'),
    );
    await expectLater(session.list(), throwsA(isA<HerdrProtocolMismatch>()));
  });
}
