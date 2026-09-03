import '../database.dart';

/// SPEC.md §39.16. The preferences table, read as a stream so a screen that
/// changes a setting and a screen that obeys it never have to agree on when to
/// rebuild.
///
/// A missing row is the default rather than an error: §39.16's table is added
/// empty by the migration, so every install starts with nothing written and the
/// defaults here are what the app has always done.
class SettingsRepository {
  SettingsRepository(this._db);

  final AppDatabase _db;

  /// §16b.1's grain. Default on — turning it off is the user opting out of the
  /// skin, not the app deciding for them.
  static const staticEnabled = 'static_enabled';

  /// SPEC.md §39.31's `[ ALERTS ]` row. Default off: with it on the app holds an
  /// ssh connection open in the background, which is not a thing to start doing
  /// on an install that never asked.
  static const alertsBlockedAgents = 'alerts_blocked_agents';

  Stream<bool> watchFlag(String key, {required bool orElse}) {
    return (_db.select(_db.settings)..where((s) => s.key.equals(key)))
        .watchSingleOrNull()
        .map((row) => row == null ? orElse : row.value == '1');
  }

  Future<bool> flag(String key, {required bool orElse}) async {
    final row = await (_db.select(
      _db.settings,
    )..where((s) => s.key.equals(key))).getSingleOrNull();
    return row == null ? orElse : row.value == '1';
  }

  /// Upsert on the key, so a preference is written the same way whether or not
  /// it has ever been set.
  Future<void> setFlag(String key, bool value) {
    return _db
        .into(_db.settings)
        .insertOnConflictUpdate(
          SettingsCompanion.insert(key: key, value: value ? '1' : '0'),
        );
  }
}
