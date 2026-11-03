import 'package:dartssh2/dartssh2.dart';
import 'package:upgrade/application/shell/launch_scan.dart';
import 'package:upgrade/application/agents/reason_lines.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/platform/herdr/herdr_client.dart';
import 'package:upgrade/platform/ssh/keys.dart';
import 'package:upgrade/platform/ssh/host_keys.dart';
import 'package:upgrade/platform/shell/shell_launch.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/ssh_exec.dart';

final class _HeldSocket implements SSHSocket {
  var closed = false;

  @override
  Future<void> close() async => closed = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('a host that reports every exit as 0 has neither tool', () async {
    final client = FakeRunClient((_) => (exitCode: 0, stdout: '', stderr: ''));
    final session = HerdrSession.over(_HeldSocket(), client);
    final targets = await session.launchTargets();
    session.close();

    expect(targets.hasHerdr, isFalse);
    expect(targets.hasTmux, isFalse);
    expect(client.commands, [LaunchCommands.present()]);
  });

  test(
    'a host whose herdr never answers fails the scan and is hung up on',
    () async {
      final keys = Ed25519Keys(MemoryPrivateKeyStore());
      await keys.generate(id: 'k1', name: 'test');
      final client = FakeRunClient((_) => null);
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
              required verifier,
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

  const host = Host(
    id: 'h',
    name: 'VM',
    address: '127.0.0.1',
    port: 22,
    user: 'dev',
    keyId: 'k',
  );

  test('a fetch that throws something unmapped fails the scan', () async {
    final store = MemoryPrivateKeyStore();
    await store.write('k', 'private');
    Future<LaunchTargets> fetch({
      required String address,
      required int port,
      required String user,
      required String privateKey,
      HostKeyVerifier? verifier,
    }) => throw const FormatException('Unexpected extension byte');
    final scan = await LaunchScanner(fetch: fetch, keys: Ed25519Keys(store))(
      host,
    );
    expect(scan, isA<LaunchScanFailed>());
    expect((scan as LaunchScanFailed).reason, 'protocol mismatch');
  });

  test('a keystore that throws fails the scan as a key problem', () async {
    final scan = await LaunchScanner(
      fetch: _unreached,
      keys: Ed25519Keys(_ThrowingStore()),
    )(host);
    expect(scan, isA<LaunchScanFailed>());
    expect((scan as LaunchScanFailed).reason, 'key rejected');
  });
}

Future<LaunchTargets> _unreached({
  required String address,
  required int port,
  required String user,
  required String privateKey,
  HostKeyVerifier? verifier,
}) => throw StateError('fetched without a key');

class _ThrowingStore extends MemoryPrivateKeyStore {
  @override
  Future<String?> read(String id) async =>
      throw PlatformException(code: 'AEADBadTagException');
}
