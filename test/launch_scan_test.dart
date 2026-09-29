import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:dazzle/application/launch_scan.dart';
import 'package:dazzle/application/reason_lines.dart';
import 'package:dazzle/data/repositories/host_repository.dart';
import 'package:dazzle/platform/herdr_client.dart';
import 'package:dazzle/platform/keys.dart';
import 'package:flutter_test/flutter_test.dart';

final class _StalledClient implements SSHClient {
  var closed = false;

  @override
  Future<SSHRunResult> runWithResult(
    String command, {
    bool runInPty = false,
    bool stdout = true,
    bool stderr = true,
    Map<String, String>? environment,
  }) => Completer<SSHRunResult>().future;

  @override
  Future<void> close() async => closed = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _HeldSocket implements SSHSocket {
  var closed = false;

  @override
  Future<void> close() async => closed = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'a host whose herdr never answers fails the scan and is hung up on',
    () async {
      final keys = Ed25519Keys(MemoryPrivateKeyStore());
      await keys.generate(id: 'k1', name: 'test');
      final client = _StalledClient();
      final socket = _HeldSocket();
      const deadline = Duration(milliseconds: 50);
      final scanner = LaunchScanner(
        keys: keys,
        fetch:
            ({
              required address,
              required port,
              required user,
              required privateKey,
              verifier,
            }) async {
              final session = HerdrSession.over(socket, client);
              try {
                return await session.launchTargets(within: deadline);
              } finally {
                session.close();
              }
            },
      );

      final scan = await scanner(
        const Host(
          id: 'h1',
          name: 'stalled',
          address: '127.0.0.1',
          port: 22,
          user: 'dev',
          keyId: 'k1',
        ),
      ).timeout(deadline * 20);
      await Future<void>.delayed(Duration.zero);

      expect(
        scan,
        isA<LaunchScanFailed>().having(
          (failed) => failed.reason,
          'reason',
          ReasonLine.unreachable.on('stalled'),
        ),
      );
      expect(client.closed, isTrue);
      expect(socket.closed, isTrue);
    },
  );
}
