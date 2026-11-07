import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/platform/shell/host_queries.dart';

import '../../support/fake_shell.dart';

void main() {
  HostQueries queries(FakeShellConnection connection) =>
      HostQueries(connection.channels, host: 'oak');

  test('a host that fails under a question answers nothing', () async {
    final connection = FakeShellConnection()
      ..answer = (_, _) => throw SSHSocketError(const SocketException('gone'));

    expect(await queries(connection).place('abcdef'), isNull);
    expect(await queries(connection).openPins(), isNull);
    expect(
      await queries(connection).answerPin('a' * 16, null, wait: Duration.zero),
      PinAnswer.lost,
    );
  });

  test('a herdr reply that does not parse names no agent', () async {
    final connection = FakeShellConnection()..answerWith('not json');

    expect(
      await queries(connection).paneAgent((session: 'hub', pane: 'w1:p1')),
      isNull,
    );
  });

  test('a bug under a question is still thrown', () async {
    final connection = FakeShellConnection()
      ..answer = (_, _) => throw StateError('mine');

    await expectLater(queries(connection).place('abcdef'), throwsStateError);
  });

  test('a host that fails under the repository question is thrown', () async {
    final connection = FakeShellConnection()
      ..answer = (_, _) => throw SSHSocketError(const SocketException('gone'));

    await expectLater(
      queries(connection).repository('/home/dev'),
      throwsA(isA<SSHSocketError>()),
    );
  });
}
