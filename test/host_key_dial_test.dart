import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/platform/host_key_dial.dart';
import 'package:dazzle/platform/host_keys.dart';
import 'package:dazzle/platform/keys.dart';

void main() {
  test(
    'a socket that opens and stays silent is told from a machine that answered',
    () async {
      final keys = Ed25519Keys(MemoryPrivateKeyStore());
      await keys.generate(id: 'k1', name: 'test');
      final privateKey = (await keys.privateKey('k1'))!;
      // A tarpit: the connection is accepted and nothing is ever said on it.
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final held = <Socket>[];
      server.listen(held.add);
      addTearDown(() async {
        for (final socket in held) {
          socket.destroy();
        }
        await server.close();
      });

      await expectLater(
        dialHostKey(
          address: server.address.address,
          port: server.port,
          user: 'luis',
          privateKey: privateKey,
          verifier: HostKeyVerifier.pinnedOnly(null),
          timeout: const Duration(milliseconds: 300),
        ),
        throwsA(isA<HostKeySilent>()),
      );
    },
  );
}
