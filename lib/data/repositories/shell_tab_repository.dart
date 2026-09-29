import 'package:drift/drift.dart';

import '../database.dart';

class ShellTab {
  const ShellTab({
    required this.hostId,
    required this.number,
    required this.active,
    required this.openedAt,
    this.remoteSession,
    this.herdrSession,
    this.herdrPane,
    this.launch,
    this.retiredAt,
  });

  final String hostId;
  final int number;
  final bool active;
  final DateTime openedAt;
  final String? remoteSession;
  final String? herdrSession;
  final String? herdrPane;
  final String? launch;
  final DateTime? retiredAt;
}

abstract class ShellTabRepository {
  Future<List<ShellTab>> all();

  Future<void> open(
    String hostId,
    int number, {
    String? remoteSession,
    String? herdrSession,
    String? herdrPane,
    String? launch,
    DateTime? openedAt,
  });

  Future<void> close(String hostId, int number);

  Future<void> retire(String hostId, int number);

  Future<List<ShellTab>> retired(String hostId);

  Future<void> activate(String hostId, int number);
}

class DriftShellTabRepository implements ShellTabRepository {
  DriftShellTabRepository(this._db);

  final AppDatabase _db;

  @override
  Future<List<ShellTab>> all() async {
    final rows =
        await (_db.select(_db.shellTabs)
              ..where((t) => t.retiredAt.isNull())
              ..orderBy([(t) => OrderingTerm(expression: t.openedAt)]))
            .get();
    return [for (final row in rows) _tab(row)];
  }

  @override
  Future<void> open(
    String hostId,
    int number, {
    String? remoteSession,
    String? herdrSession,
    String? herdrPane,
    String? launch,
    DateTime? openedAt,
  }) async {
    _validateIdentity(remoteSession, herdrSession, herdrPane);
    await _clear(hostId);
    await _db
        .into(_db.shellTabs)
        .insertOnConflictUpdate(
          ShellTabsCompanion.insert(
            hostId: hostId,
            number: number,
            active: true,
            openedAt: openedAt ?? DateTime.now(),
            remoteSession: Value(remoteSession),
            herdrSession: Value(herdrSession),
            herdrPane: Value(herdrPane),
            launch: Value(launch),
            retiredAt: const Value(null),
          ),
        );
  }

  @override
  Future<void> close(String hostId, int number) {
    return (_db.delete(
      _db.shellTabs,
    )..where((t) => t.hostId.equals(hostId) & t.number.equals(number))).go();
  }

  @override
  Future<void> retire(String hostId, int number) {
    return (_db.update(
      _db.shellTabs,
    )..where((t) => t.hostId.equals(hostId) & t.number.equals(number))).write(
      ShellTabsCompanion(
        active: const Value(false),
        retiredAt: Value(DateTime.now()),
      ),
    );
  }

  @override
  Future<List<ShellTab>> retired(String hostId) async {
    final rows =
        await (_db.select(_db.shellTabs)
              ..where((t) => t.hostId.equals(hostId) & t.retiredAt.isNotNull())
              ..orderBy([(t) => OrderingTerm(expression: t.openedAt)]))
            .get();
    return rows.map(_tab).toList();
  }

  @override
  Future<void> activate(String hostId, int number) async {
    await _clear(hostId);
    await (_db.update(_db.shellTabs)
          ..where((t) => t.hostId.equals(hostId) & t.number.equals(number)))
        .write(const ShellTabsCompanion(active: Value(true)));
  }

  Future<void> _clear(String hostId) {
    return (_db.update(_db.shellTabs)..where((t) => t.hostId.equals(hostId)))
        .write(const ShellTabsCompanion(active: Value(false)));
  }

  ShellTab _tab(ShellTabRow row) => ShellTab(
    hostId: row.hostId,
    number: row.number,
    active: row.active,
    openedAt: row.openedAt,
    remoteSession: row.remoteSession,
    herdrSession: row.herdrSession,
    herdrPane: row.herdrPane,
    launch: row.launch,
    retiredAt: row.retiredAt,
  );
}

class InMemoryShellTabRepository implements ShellTabRepository {
  final _tabs = <ShellTab>[];

  @override
  Future<List<ShellTab>> all() async =>
      List.unmodifiable(_tabs.where((tab) => tab.retiredAt == null));

  @override
  Future<void> open(
    String hostId,
    int number, {
    String? remoteSession,
    String? herdrSession,
    String? herdrPane,
    String? launch,
    DateTime? openedAt,
  }) async {
    _validateIdentity(remoteSession, herdrSession, herdrPane);
    _tabs.removeWhere((tab) => tab.hostId == hostId && tab.number == number);
    _tabs.add(
      ShellTab(
        hostId: hostId,
        number: number,
        active: true,
        openedAt: openedAt ?? DateTime.now(),
        remoteSession: remoteSession,
        herdrSession: herdrSession,
        herdrPane: herdrPane,
        launch: launch,
      ),
    );
    await activate(hostId, number);
  }

  @override
  Future<void> close(String hostId, int number) async {
    _tabs.removeWhere((tab) => tab.hostId == hostId && tab.number == number);
  }

  @override
  Future<void> retire(String hostId, int number) async {
    for (var i = 0; i < _tabs.length; i++) {
      final tab = _tabs[i];
      if (tab.hostId != hostId || tab.number != number) continue;
      _tabs[i] = ShellTab(
        hostId: tab.hostId,
        number: tab.number,
        active: false,
        openedAt: tab.openedAt,
        remoteSession: tab.remoteSession,
        herdrSession: tab.herdrSession,
        herdrPane: tab.herdrPane,
        launch: tab.launch,
        retiredAt: DateTime.now(),
      );
    }
  }

  @override
  Future<List<ShellTab>> retired(String hostId) async => [
    for (final tab in _tabs)
      if (tab.hostId == hostId && tab.retiredAt != null) tab,
  ];

  @override
  Future<void> activate(String hostId, int number) async {
    for (var i = 0; i < _tabs.length; i++) {
      final tab = _tabs[i];
      if (tab.hostId != hostId) continue;
      _tabs[i] = ShellTab(
        hostId: hostId,
        number: tab.number,
        active: tab.number == number,
        openedAt: tab.openedAt,
        remoteSession: tab.remoteSession,
        herdrSession: tab.herdrSession,
        herdrPane: tab.herdrPane,
        launch: tab.launch,
        retiredAt: tab.retiredAt,
      );
    }
  }
}

void _validateIdentity(
  String? remoteSession,
  String? herdrSession,
  String? herdrPane,
) {
  final partialHerdr = (herdrSession == null) != (herdrPane == null);
  if (partialHerdr) {
    throw ArgumentError('a shell tab must name a complete Herdr pane');
  }
}
