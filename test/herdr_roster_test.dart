import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:dazzle/platform/herdr_client.dart';
import 'package:flutter_test/flutter_test.dart';

final class _ExitingClient implements SSHClient {
  _ExitingClient(this.exitCode, this.said);

  final int exitCode;
  final String said;

  @override
  Future<SSHRunResult> runWithResult(
    String command, {
    bool runInPty = false,
    bool stdout = true,
    bool stderr = true,
    Map<String, String>? environment,
  }) async {
    final err = Uint8List.fromList(utf8.encode(said));
    return SSHRunResult(
      output: err,
      exitCode: exitCode,
      exitSignal: null,
      stdout: Uint8List(0),
      stderr: err,
    );
  }

  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Socket implements SSHSocket {
  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('a shell that cannot find herdr reads as no herdr', () async {
    final session = HerdrSession.over(
      _Socket(),
      _ExitingClient(127, 'zsh:1: command not found: herdr'),
    );
    await expectLater(session.list(), throwsA(isA<HerdrMissing>()));
  });

  test('a herdr that fails in its own words is still a protocol', () async {
    final session = HerdrSession.over(
      _Socket(),
      _ExitingClient(2, 'herdr: unknown flag'),
    );
    await expectLater(session.list(), throwsA(isA<HerdrProtocolMismatch>()));
  });
}
