import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/platform/keys.dart';
import 'package:dazzle/platform/vnc/vnc_failure.dart';
import 'package:dazzle/platform/vnc/vnc_tunnel.dart';

import 'support/tarpit.dart';

void main() {
  test('a dial that ran out of time does not hang up mid-handshake', () async {
    final keys = Ed25519Keys(MemoryPrivateKeyStore());
    await keys.generate(id: 'k1', name: 'test');
    final privateKey = (await keys.privateKey('k1'))!;
    final tarpit = await openTarpit();

    await expectLater(
      const VncTunnel(timeout: Duration(milliseconds: 300)).open(
        address: tarpit.address,
        port: tarpit.port,
        user: 'luis',
        privateKey: privateKey,
      ),
      throwsA(isA<VncUnreachable>()),
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(tarpit.closedByPeer.isCompleted, isFalse);
  });
}
