import 'package:drift/drift.dart';

import '../database.dart';

/// One tab as it was left: the host it is on, its number, and whether it was
/// the one on screen.
class ShellTab {
  const ShellTab({
    required this.hostId,
    required this.number,
    required this.active,
  });

  final String hostId;
  final int number;
  final bool active;
}

/// The tabs that were open when the app last ran.
///
/// Nothing here keeps a connection alive — an ssh socket dies with the process
/// that held it. What it keeps is the list to dial again, which is what makes a
/// killed app come back up on the shells the user left rather than on nothing.
abstract class ShellTabRepository {
  /// In open order, so the numbers come back the way they were handed out.
  Future<List<ShellTab>> all();

  /// Records the tab and makes it the active one on its host, which is what
  /// opening a shell does to the tab row.
  Future<void> open(String hostId, int number);

  Future<void> close(String hostId, int number);

  /// The one tab on screen for this host. Every other row on it is cleared, so
  /// a host has one active tab in the table as it has one on the route.
  Future<void> activate(String hostId, int number);
}

class DriftShellTabRepository implements ShellTabRepository {
  DriftShellTabRepository(this._db);

  final AppDatabase _db;

  @override
  Future<List<ShellTab>> all() async {
    final rows = await (_db.select(
      _db.shellTabs,
    )..orderBy([(t) => OrderingTerm(expression: t.openedAt)])).get();
    return [
      for (final row in rows)
        ShellTab(hostId: row.hostId, number: row.number, active: row.active),
    ];
  }

  @override
  Future<void> open(String hostId, int number) async {
    await _clear(hostId);
    await _db
        .into(_db.shellTabs)
        .insertOnConflictUpdate(
          ShellTabsCompanion.insert(
            hostId: hostId,
            number: number,
            active: true,
            openedAt: DateTime.now(),
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
}

class InMemoryShellTabRepository implements ShellTabRepository {
  final _tabs = <ShellTab>[];

  @override
  Future<List<ShellTab>> all() async => List.unmodifiable(_tabs);

  @override
  Future<void> open(String hostId, int number) async {
    _tabs.removeWhere((tab) => tab.hostId == hostId && tab.number == number);
    _tabs.add(ShellTab(hostId: hostId, number: number, active: true));
    await activate(hostId, number);
  }

  @override
  Future<void> close(String hostId, int number) async {
    _tabs.removeWhere((tab) => tab.hostId == hostId && tab.number == number);
  }

  @override
  Future<void> activate(String hostId, int number) async {
    for (var i = 0; i < _tabs.length; i++) {
      final tab = _tabs[i];
      if (tab.hostId != hostId) continue;
      _tabs[i] = ShellTab(
        hostId: hostId,
        number: tab.number,
        active: tab.number == number,
      );
    }
  }
}
