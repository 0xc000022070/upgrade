import 'package:upgrade/platform/herdr/herdr_client.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/ssh_exec.dart';

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

  test('a fresh session reads the roster before its first send', () async {
    final client = _exiting(127, 'zsh:1: command not found: herdr');
    final session = HerdrSession.over(FakeExecSocket(), client);
    await expectLater(
      session.sendKeys((session: 'development', pane: 'w4:p1'), const ['n']),
      throwsA(isA<HerdrMissing>()),
    );
    expect(client.commands.single, contains('herdr session list --json'));
  });

  test('a send to a session the roster lacks is still refused', () async {
    final client = FakeRunClient(
      (_) => (
        exitCode: 0,
        stdout:
            '{"sessions":[{"name":"default","running":true,"default":true,'
            '"socket_path":"/run/herdr.sock"}]}',
        stderr: '',
      ),
    );
    final session = HerdrSession.over(FakeExecSocket(), client);
    await expectLater(
      session.sendKeys((session: 'development', pane: 'w4:p1'), const ['n']),
      throwsA(isA<HerdrProtocolMismatch>()),
    );
    expect(client.commands, hasLength(1));
  });
}
