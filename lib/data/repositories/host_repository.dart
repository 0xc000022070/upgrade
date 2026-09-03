import 'package:drift/drift.dart';

import '../database.dart';
import '../enums.dart';

/// SPEC.md §39.21. A machine the user has registered.
///
/// Renamed from `HerdrHost` (user ruling, 2026-09-02): a host is a machine, not
/// a herdr endpoint. What the app does with it is [IntegrationKind], carried
/// alongside rather than baked into the type, so the backend that later proxies
/// herdr swaps a transport and leaves this class alone.
class Host {
  const Host({
    required this.id,
    required this.name,
    required this.address,
    required this.user,
    required this.keyId,
  });

  final String id;
  final String name;
  final String address;
  final String user;
  final String keyId;
}

abstract interface class HostRepository {
  Stream<List<Host>> watchAll();

  /// Every host with [kind] switched on. §39.20 polls all of them, so this is a
  /// list and never a single row: there is no "selected" host any more.
  Stream<List<Host>> watchWithIntegration(IntegrationKind kind);

  /// The kinds [hostId] has on. The host form has to render a switch per known
  /// kind in its current position, which no by-kind query can answer.
  Stream<Set<IntegrationKind>> watchIntegrations(String hostId);

  Future<List<Host>> all();
  Future<void> save(Host host);
  Future<void> delete(String id);
  Future<void> setIntegration(String hostId, IntegrationKind kind, bool on);
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

  Set<IntegrationKind> _kinds(String hostId) =>
      _integrations[hostId] ?? const {};

  /// One listener list for both tables' worth of state, because every one of
  /// these streams is derived from both: switching an integration on changes
  /// what [watchWithIntegration] returns without touching [_hosts].
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

/// SPEC.md §39.21. The registered machines and the integrations they have on.
class DriftHostRepository implements HostRepository {
  DriftHostRepository(this._db);

  final AppDatabase _db;

  @override
  Stream<List<Host>> watchAll() {
    return (_db.select(_db.hosts)..orderBy([(h) => OrderingTerm.asc(h.name)]))
        .watch()
        .map((rows) => rows.map(_host).toList());
  }

  /// One joined stream, so switching the integration on and renaming the host
  /// both repaint the panel. Two streams — the hosts, then their integrations —
  /// would let §39.20 poll a host whose row has already changed under it.
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
      (rows) => rows.map((row) => _host(row.readTable(_db.hosts))).toList(),
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
    return rows.map(_host).toList();
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
            user: host.user,
            keyId: host.keyId,
          ),
        );
  }

  /// The integration rows go with the host, in Dart and in the same
  /// transaction. The declared reference does not enforce anything — this
  /// database never enables `PRAGMA foreign_keys` — so left alone they would
  /// outlive the host and switch a future host with the same id on by itself.
  @override
  Future<void> delete(String id) {
    return _db.transaction(() async {
      await (_db.delete(
        _db.hostIntegrations,
      )..where((i) => i.hostId.equals(id))).go();
      await (_db.delete(_db.hosts)..where((h) => h.id.equals(id))).go();
    });
  }

  /// On is a row, off is no row. There is no third state to store and none to
  /// render, and an integration nobody has ever touched reads the same as one
  /// switched off — which is what a freshly registered host needs.
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

  Host _host(HostRow row) => Host(
    id: row.id,
    name: row.name,
    address: row.address,
    user: row.user,
    keyId: row.keyId,
  );
}
