import 'package:drift/drift.dart';

import '../../platform/host_keys.dart';
import '../database.dart';
import '../enums.dart';
import 'path_repository.dart';

/// A machine the user has registered.
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
    required this.port,
    required this.user,
    required this.keyId,
    this.hostKey,
    this.vncPassword,
  });

  final String id;
  final String name;
  final String address;

  /// Required rather than defaulted to 22: the column carries the default, and
  /// a second one here would let a mapping that forgot the field compile and
  /// quietly dial 22.
  final int port;
  final String user;
  final String keyId;

  /// The machine's own key, trusted the first time it was seen. Null for a host
  /// that has never been connected to, which is the only state in which the app
  /// will ask about one.
  final PinnedHostKey? hostKey;

  /// The VNC Authentication password, offered only to a server whose list has
  /// no `None`. Null for a host whose server needs none, which is every one
  /// but a Mac's Screen Sharing.
  final String? vncPassword;
}

abstract interface class HostRepository {
  Stream<List<Host>> watchAll();

  /// Every host with [kind] switched on. The agents feed polls all of them, so
  /// this is a list and never a single row: there is no "selected" host.
  Stream<List<Host>> watchWithIntegration(IntegrationKind kind);

  /// The kinds [hostId] has on. The host form has to render a switch per known
  /// kind in its current position, which no by-kind query can answer.
  Stream<Set<IntegrationKind>> watchIntegrations(String hostId);

  Future<List<Host>> all();
  Future<void> save(Host host);
  Future<void> delete(String id);
  Future<void> setIntegration(String hostId, IntegrationKind kind, bool on);

  /// Trusts [key] for [hostId] from now on. Called by the verifier the moment
  /// the user taps `TRUST`, not by the form: the fingerprint only exists inside
  /// a handshake.
  Future<void> pinHostKey(String hostId, PinnedHostKey key);

  /// Drops the pin, which is the only way past a key that changed. The next
  /// connection asks again.
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

  /// Rebuilt rather than copied: [Host] has no `copyWith`, and one written for
  /// a single nullable field could not tell "leave it" from "clear it".
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

/// The registered machines and the integrations they have on.
class DriftHostRepository implements HostRepository {
  DriftHostRepository(this._db);

  final AppDatabase _db;

  @override
  Stream<List<Host>> watchAll() {
    return (_db.select(_db.hosts)..orderBy([(h) => OrderingTerm.asc(h.name)]))
        .watch()
        .map((rows) => rows.map(hostFromRow).toList());
  }

  /// One joined stream, so switching the integration on and renaming the host
  /// both repaint the panel. Two streams — the hosts, then their integrations —
  /// would let the feed poll a host whose row has already changed under it.
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

  /// Everything hanging off the host goes with it, in Dart and in the same
  /// transaction. The declared references do not enforce anything — this
  /// database never enables `PRAGMA foreign_keys` — so left alone they would
  /// outlive the host: the integration rows would switch a future host with the
  /// same id on by itself, and the paths would keep offering directories on a
  /// machine the app can no longer reach.
  ///
  /// The dispatch rows go too, through the paths. The drops they name do not:
  /// unregistering a machine loses the record of where work was sent, never the
  /// work.
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

/// The row as the domain type. Top-level rather than private to the repository
/// because the send picker joins paths to hosts and has to build the same
/// [Host] from the same columns.
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

/// The three columns as one value, or null unless all three are there. A row
/// with a fingerprint and no type is not a pin the app would compare against,
/// so it reads as no pin at all.
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
