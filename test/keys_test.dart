// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spectacle/platform/keys.dart';
import 'package:pointycastle/digests/sha256.dart';

void main() {
  test(
    'generates an ed25519 key and stores only its private material',
    () async {
      final store = MemoryPrivateKeyStore();
      final keys = Ed25519Keys(store);

      final generated = await keys.generate(id: 'key-1', name: 'faraday');
      final privateKey = await keys.privateKey('key-1');

      expect(privateKey, isNotNull);
      expect(
        SSHKeyPair.fromPem(privateKey!).single,
        isA<OpenSSHEd25519KeyPair>(),
      );
      expect(generated.publicKey, startsWith('ssh-ed25519 '));
      expect(generated.publicKey, endsWith(' faraday'));
      expect(generated.publicKey, isNot(contains('PRIVATE')));
    },
  );

  test('fingerprint is SHA256 of the OpenSSH public blob', () async {
    final generated = await Ed25519Keys(MemoryPrivateKeyStore())
        .generate(id: 'key-2', name: 'spectacle');
    final blob = base64Decode(generated.publicKey.split(' ')[1]);
    final expected = base64Encode(SHA256Digest().process(blob))
        .replaceAll('=', '');

    expect(generated.fingerprint, 'SHA256:$expected');
  });
}
