import 'package:drift/drift.dart';

import '../database.dart';

class ManagedKey {
  const ManagedKey({
    required this.id,
    required this.name,
    required this.publicKey,
    required this.fingerprint,
    required this.createdAt,
  });

  final String id;
  final String name;
  final String publicKey;
  final String fingerprint;
  final DateTime createdAt;
}

abstract interface class KeyRepository {
  Stream<List<ManagedKey>> watchAll();
  Future<List<ManagedKey>> all();
  Future<void> save(ManagedKey key);
  Future<void> delete(String id);
}

class InMemoryKeyRepository implements KeyRepository {
  final List<ManagedKey> _keys = [];
  final _listeners = <void Function(List<ManagedKey>)>[];

  @override
  Stream<List<ManagedKey>> watchAll() {
    return Stream<List<ManagedKey>>.multi((controller) {
      void emit(List<ManagedKey> keys) => controller.add(keys);
      _listeners.add(emit);
      controller
        ..add(List.unmodifiable(_keys))
        ..onCancel = () => _listeners.remove(emit);
    });
  }

  @override
  Future<List<ManagedKey>> all() async => List.unmodifiable(_keys);

  @override
  Future<void> save(ManagedKey key) async {
    _keys.removeWhere((item) => item.id == key.id);
    _keys.add(key);
    _emit();
  }

  @override
  Future<void> delete(String id) async {
    _keys.removeWhere((key) => key.id == id);
    _emit();
  }

  void _emit() {
    final value = List<ManagedKey>.unmodifiable(_keys);
    for (final listener in List.of(_listeners)) {
      listener(value);
    }
  }
}

/// Thrown by [DriftKeyRepository.delete] when a host still names the key.
///
/// The delete is refused rather than cascaded: a host whose key
/// vanished cannot connect and cannot say why, and the row that would explain it
/// is the one that was just removed. [hostNames] is carried so the caller can
/// name the hosts instead of only refusing.
class KeyInUseException implements Exception {
  const KeyInUseException(this.hostNames);

  final List<String> hostNames;

  @override
  String toString() => 'key is used by ${hostNames.join(', ')}';
}

/// The public half of every generated key. The private half is
/// never written here — it lives in the platform keystore behind
/// [PrivateKeyStore], and deleting a key from this table does not delete it
/// there; [Ed25519Keys.delete] is the caller's second step.
class DriftKeyRepository implements KeyRepository {
  DriftKeyRepository(this._db);

  final AppDatabase _db;

  /// Creation order, oldest first, which is the order [InMemoryKeyRepository]
  /// produces by appending. The two implementations back the same screens and a
  /// different order under one of them would only ever show up on device.
  @override
  Stream<List<ManagedKey>> watchAll() {
    return (_db.select(_db.keys)
          ..orderBy([(k) => OrderingTerm.asc(k.createdAt)]))
        .watch()
        .map((rows) => rows.map(_managed).toList());
  }

  @override
  Future<List<ManagedKey>> all() async {
    final rows = await (_db.select(
      _db.keys,
    )..orderBy([(k) => OrderingTerm.asc(k.createdAt)])).get();
    return rows.map(_managed).toList();
  }

  @override
  Future<void> save(ManagedKey key) {
    return _db
        .into(_db.keys)
        .insertOnConflictUpdate(
          KeysCompanion.insert(
            id: key.id,
            name: key.name,
            publicKey: key.publicKey,
            fingerprint: key.fingerprint,
            createdAt: key.createdAt,
          ),
        );
  }

  /// Refused while a host references the key. sqlite is not the guard here:
  /// this database never enables `PRAGMA foreign_keys`, so the declared
  /// reference on `hosts.key_id` would let the row go. The check and the delete
  /// share a transaction so a host saved between the two cannot slip past it.
  @override
  Future<void> delete(String id) {
    return _db.transaction(() async {
      final users = await (_db.select(
        _db.hosts,
      )..where((h) => h.keyId.equals(id))).get();
      if (users.isNotEmpty) {
        throw KeyInUseException(users.map((h) => h.name).toList());
      }
      await (_db.delete(_db.keys)..where((k) => k.id.equals(id))).go();
    });
  }

  ManagedKey _managed(KeyRow row) => ManagedKey(
    id: row.id,
    name: row.name,
    publicKey: row.publicKey,
    fingerprint: row.fingerprint,
    createdAt: row.createdAt,
  );
}
