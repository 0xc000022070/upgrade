import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pinenacl/ed25519.dart' as ed25519;
import 'package:pointycastle/digests/sha256.dart';

abstract interface class PrivateKeyStore {
  Future<void> write(String id, String privateKey);
  Future<String?> read(String id);
  Future<void> delete(String id);
}

class SecurePrivateKeyStore implements PrivateKeyStore {
  const SecurePrivateKeyStore([this._storage = const FlutterSecureStorage()]);

  final FlutterSecureStorage _storage;

  @override
  Future<void> write(String id, String privateKey) =>
      _storage.write(key: id, value: privateKey);

  @override
  Future<String?> read(String id) => _storage.read(key: id);

  @override
  Future<void> delete(String id) => _storage.delete(key: id);
}

class MemoryPrivateKeyStore implements PrivateKeyStore {
  final Map<String, String> _values = {};

  @override
  Future<void> write(String id, String privateKey) async {
    _values[id] = privateKey;
  }

  @override
  Future<String?> read(String id) async => _values[id];

  @override
  Future<void> delete(String id) async {
    _values.remove(id);
  }
}

class GeneratedSshKey {
  const GeneratedSshKey({required this.publicKey, required this.fingerprint});

  final String publicKey;
  final String fingerprint;
}

class Ed25519Keys {
  const Ed25519Keys(this._store);

  final PrivateKeyStore _store;

  Future<GeneratedSshKey> generate({
    required String id,
    required String name,
  }) async {
    final signingKey = ed25519.SigningKey.generate();
    final pair = OpenSSHEd25519KeyPair(
      signingKey.verifyKey.asTypedList,
      signingKey.asTypedList,
      name,
    );
    final blob = pair.toPublicKey().encode();
    final publicKey = 'ssh-ed25519 ${base64Encode(blob)} $name';
    final digest = SHA256Digest().process(blob);
    final fingerprint = 'SHA256:${base64Encode(digest).replaceAll('=', '')}';
    await _store.write(id, pair.toPem());
    return GeneratedSshKey(publicKey: publicKey, fingerprint: fingerprint);
  }

  Future<String?> privateKey(String id) => _store.read(id);

  Future<void> delete(String id) => _store.delete(id);
}
