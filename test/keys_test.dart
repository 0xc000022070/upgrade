import 'dart:async';

// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/platform/keys.dart';
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
        .generate(id: 'key-2', name: 'dazzle');
    final blob = base64Decode(generated.publicKey.split(' ')[1]);
    final expected = base64Encode(SHA256Digest().process(blob))
        .replaceAll('=', '');

    expect(generated.fingerprint, 'SHA256:$expected');
  });

  group('CachingPrivateKeyStore', () {
    late _CountingStore inner;
    late CachingPrivateKeyStore store;

    setUp(() {
      inner = _CountingStore();
      store = CachingPrivateKeyStore(inner);
    });

    test('serves a key from memory after the first read', () async {
      await inner.write('key-1', 'pem-1');

      for (var n = 0; n < 5; n++) {
        expect(await store.read('key-1'), 'pem-1');
      }

      expect(inner.reads, 1);
    });

    test('a missing key is not remembered as missing', () async {
      expect(await store.read('key-1'), isNull);
      await inner.write('key-1', 'pem-1');

      expect(await store.read('key-1'), 'pem-1');
    });

    test(
      'a generate, a write and a delete are seen on the next read',
      () async {
        final keys = Ed25519Keys(store);
        await keys.generate(id: 'key-1', name: 'first');
        final first = await keys.privateKey('key-1');

        await keys.generate(id: 'key-1', name: 'second');
        final second = await keys.privateKey('key-1');
        expect(second, isNot(first));
        expect(second, await inner.read('key-1'));

        await store.write('key-1', 'restored');
        expect(await keys.privateKey('key-1'), 'restored');

        await keys.delete('key-1');
        expect(await keys.privateKey('key-1'), isNull);
        expect(await inner.read('key-1'), isNull);
      },
    );

    test(
      'a read that lands after a delete does not bring the key back',
      () async {
        await inner.write('key-1', 'pem-1');
        inner.gate = Completer();
        final reading = store.read('key-1');
        await store.delete('key-1');
        inner.gate!.complete();

        expect(await reading, 'pem-1');
        inner.gate = null;
        expect(await store.read('key-1'), isNull);
      },
    );
  });
}

class _CountingStore extends MemoryPrivateKeyStore {
  int reads = 0;
  Completer<void>? gate;

  @override
  Future<String?> read(String id) async {
    reads++;
    final value = await super.read(id);
    await gate?.future;
    return value;
  }
}
