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

/// A keystore read is a platform channel and a decrypt each time; a key read once is
/// served from memory until this store writes or deletes it.
class CachingPrivateKeyStore implements PrivateKeyStore {
  CachingPrivateKeyStore(this._inner);

  final PrivateKeyStore _inner;
  final Map<String, String> _cached = {};
  var _changes = 0;

  @override
  Future<void> write(String id, String privateKey) async {
    _changes++;
    await _inner.write(id, privateKey);
    _cached[id] = privateKey;
  }

  @override
  Future<String?> read(String id) async {
    final cached = _cached[id];
    if (cached != null) return cached;
    final before = _changes;
    final value = await _inner.read(id);
    if (value != null && before == _changes) _cached[id] = value;
    return value;
  }

  @override
  Future<void> delete(String id) async {
    _changes++;
    _cached.remove(id);
    await _inner.delete(id);
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
