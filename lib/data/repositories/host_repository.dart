import 'package:drift/drift.dart';

import '../../platform/host_keys.dart';
import '../database.dart';
import '../enums.dart';
import 'path_repository.dart';

class Host {
  const Host({
    required this.id,
    required this.name,
    required this.address,
    required this.port,
    required this.user,
    required this.keyId,
    this.hostKey,
    this.vncPassword,
  });

  final String id;
  final String name;
  final String address;

  /// Required rather than defaulted to 22, so a mapping that forgets the field cannot
  /// compile and quietly dial 22.
  final int port;
  final String user;
  final String keyId;

  final PinnedHostKey? hostKey;

  final String? vncPassword;
}

abstract interface class HostRepository {
  Stream<List<Host>> watchAll();

  Stream<List<Host>> watchWithIntegration(IntegrationKind kind);

  Stream<Set<IntegrationKind>> watchIntegrations(String hostId);

  Future<List<Host>> all();
  Future<void> save(Host host);
  Future<void> delete(String id);
  Future<void> setIntegration(String hostId, IntegrationKind kind, bool on);

  /// Called by the verifier the moment the user taps `TRUST`, not by the form: the
  /// fingerprint only exists inside a handshake.
  Future<void> pinHostKey(String hostId, PinnedHostKey key);

  Future<void> forgetHostKey(String hostId);
}

class InMemoryHostRepository implements HostRepository {
  final List<Host> _hosts = [];
  final Map<String, Set<IntegrationKind>> _integrations = {};
  final _listeners = <void Function()>[];

  @override
  Stream<List<Host>> watchAll() => _watch(() => List.unmodifiable(_hosts));

  @override
  Stream<List<Host>> watchWithIntegration(IntegrationKind kind) {
    return _watch(
      () => List<Host>.unmodifiable(
        _hosts.where((host) => _kinds(host.id).contains(kind)),
      ),
    );
  }

  @override
  Stream<Set<IntegrationKind>> watchIntegrations(String hostId) =>
      _watch(() => Set.unmodifiable(_kinds(hostId)));

  @override
  Future<List<Host>> all() async => List.unmodifiable(_hosts);

  @override
  Future<void> save(Host host) async {
    _hosts.removeWhere((item) => item.id == host.id);
    _hosts.add(host);
    _emit();
  }

  @override
  Future<void> delete(String id) async {
    _hosts.removeWhere((host) => host.id == id);
    _integrations.remove(id);
    _emit();
  }

  @override
  Future<void> setIntegration(
    String hostId,
    IntegrationKind kind,
    bool on,
  ) async {
    final kinds = _integrations.putIfAbsent(hostId, () => <IntegrationKind>{});
    on ? kinds.add(kind) : kinds.remove(kind);
    _emit();
  }

  @override
  Future<void> pinHostKey(String hostId, PinnedHostKey key) async =>
      _rewriteKey(hostId, key);

  @override
  Future<void> forgetHostKey(String hostId) async => _rewriteKey(hostId, null);

  void _rewriteKey(String hostId, PinnedHostKey? key) {
    final index = _hosts.indexWhere((host) => host.id == hostId);
    if (index < 0) return;
    final host = _hosts[index];
    _hosts[index] = Host(
      id: host.id,
      name: host.name,
      address: host.address,
      port: host.port,
      user: host.user,
      keyId: host.keyId,
      hostKey: key,
    );
    _emit();
  }

  Set<IntegrationKind> _kinds(String hostId) =>
      _integrations[hostId] ?? const {};

  Stream<T> _watch<T>(T Function() read) {
    return Stream<T>.multi((controller) {
      void emit() => controller.add(read());
      _listeners.add(emit);
      controller
        ..add(read())
        ..onCancel = () => _listeners.remove(emit);
    });
  }

  void _emit() {
    for (final listener in List.of(_listeners)) {
      listener();
    }
  }
}

class DriftHostRepository implements HostRepository {
  DriftHostRepository(this._db);

  final AppDatabase _db;

  @override
  Stream<List<Host>> watchAll() {
    return (_db.select(_db.hosts)..orderBy([(h) => OrderingTerm.asc(h.name)]))
        .watch()
        .map((rows) => rows.map(hostFromRow).toList());
  }

  /// One joined stream: two — hosts, then integrations — would let the feed poll a host
  /// whose row has already changed under it.
  @override
  Stream<List<Host>> watchWithIntegration(IntegrationKind kind) {
    final query = _db.select(_db.hosts).join([
      innerJoin(
        _db.hostIntegrations,
        _db.hostIntegrations.hostId.equalsExp(_db.hosts.id) &
            _db.hostIntegrations.kind.equalsValue(kind),
      ),
    ])..orderBy([OrderingTerm.asc(_db.hosts.name)]);
    return query.watch().map(
      (rows) =>
          rows.map((row) => hostFromRow(row.readTable(_db.hosts))).toList(),
    );
  }

  @override
  Stream<Set<IntegrationKind>> watchIntegrations(String hostId) {
    return (_db.select(_db.hostIntegrations)
          ..where((i) => i.hostId.equals(hostId)))
        .watch()
        .map((rows) => rows.map((row) => row.kind).toSet());
  }

  @override
  Future<List<Host>> all() async {
    final rows = await (_db.select(
      _db.hosts,
    )..orderBy([(h) => OrderingTerm.asc(h.name)])).get();
    return rows.map(hostFromRow).toList();
  }

  @override
  Future<void> save(Host host) {
    return _db
        .into(_db.hosts)
        .insertOnConflictUpdate(
          HostsCompanion.insert(
            id: host.id,
            name: host.name,
            address: host.address,
            port: Value(host.port),
            user: host.user,
            keyId: host.keyId,
            vncPassword: Value(host.vncPassword),
          ),
        );
  }

  /// In Dart, because this database never enables `PRAGMA foreign_keys`: left alone the
  /// integration rows would switch a future host with the same id on by itself.
  @override
  Future<void> delete(String id) {
    return _db.transaction(() async {
      await (_db.delete(
        _db.hostIntegrations,
      )..where((i) => i.hostId.equals(id))).go();
      final paths = await (_db.select(
        _db.paths,
      )..where((p) => p.hostId.equals(id))).get();
      for (final path in paths) {
        await deletePathRows(_db, path.id);
      }
      await (_db.delete(_db.hosts)..where((h) => h.id.equals(id))).go();
    });
  }

  /// On is a row, off is no row. An integration nobody has touched reads as off.
  @override
  Future<void> setIntegration(String hostId, IntegrationKind kind, bool on) {
    if (!on) {
      return (_db.delete(
        _db.hostIntegrations,
      )..where((i) => i.hostId.equals(hostId) & i.kind.equalsValue(kind))).go();
    }
    return _db
        .into(_db.hostIntegrations)
        .insertOnConflictUpdate(
          HostIntegrationsCompanion.insert(hostId: hostId, kind: kind),
        );
  }

  @override
  Future<void> pinHostKey(String hostId, PinnedHostKey key) {
    return (_db.update(_db.hosts)..where((h) => h.id.equals(hostId))).write(
      HostsCompanion(
        hostKeyType: Value(key.type),
        hostKeyFingerprint: Value(key.fingerprint),
        hostKeyPinnedAt: Value(key.pinnedAt),
      ),
    );
  }

  @override
  Future<void> forgetHostKey(String hostId) {
    return (_db.update(_db.hosts)..where((h) => h.id.equals(hostId))).write(
      const HostsCompanion(
        hostKeyType: Value(null),
        hostKeyFingerprint: Value(null),
        hostKeyPinnedAt: Value(null),
      ),
    );
  }
}

Host hostFromRow(HostRow row) => Host(
  id: row.id,
  name: row.name,
  address: row.address,
  port: row.port,
  user: row.user,
  keyId: row.keyId,
  hostKey: pinnedKeyFromRow(row),
  vncPassword: row.vncPassword,
);

PinnedHostKey? pinnedKeyFromRow(HostRow row) {
  final type = row.hostKeyType;
  final fingerprint = row.hostKeyFingerprint;
  final pinnedAt = row.hostKeyPinnedAt;
  if (type == null || fingerprint == null || pinnedAt == null) return null;
  return PinnedHostKey(
    type: type,
    fingerprint: fingerprint,
    pinnedAt: pinnedAt,
  );
}
