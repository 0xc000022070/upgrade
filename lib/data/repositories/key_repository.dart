import 'package:drift/drift.dart';

import 'package:striked/data/database.dart';

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

class KeyInUseException implements Exception {
  const KeyInUseException(this.hostNames);

  final List<String> hostNames;

  @override
  String toString() => 'key is used by ${hostNames.join(', ')}';
}

/// The private half is never written here: it lives in the platform keystore, and
/// [Ed25519Keys.delete] is the caller's second step.
class DriftKeyRepository implements KeyRepository {
  DriftKeyRepository(this._db);

  final AppDatabase _db;

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

  /// sqlite is not the guard — `PRAGMA foreign_keys` is never on — so the check and the
  /// delete share a transaction, or a host saved between the two would slip past.
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
