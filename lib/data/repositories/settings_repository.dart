import '../database.dart';

/// The preferences table, read as a stream so a screen that
/// changes a setting and a screen that obeys it never have to agree on when to
/// rebuild.
///
/// A missing row is the default rather than an error: the table is added
/// empty by the migration, so every install starts with nothing written and the
/// defaults here are what the app has always done.
class SettingsRepository {
  SettingsRepository(this._db);

  final AppDatabase _db;

  /// The background grain. Default on — turning it off is the user opting out
  /// of the
  /// skin, not the app deciding for them.
  static const staticEnabled = 'static_enabled';

  /// The `[ ALERTS ]` row. Default off: with it on the app holds an
  /// ssh connection open in the background, which is not a thing to start doing
  /// on an install that never asked.
  static const alertsBlockedAgents = 'alerts_blocked_agents';

  /// The terminal's type size in logical points. Default 13, the size every
  /// shell drew before it could be pinched; one size for every host and tab,
  /// since it is the user's reading distance and not a property of a shell.
  static const shellFontSize = 'shell_font_size';

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
  Future<void> setFlag(String key, bool value) =>
      _write(key, value ? '1' : '0');

  /// A number is its decimal text. A row that does not parse reads as the
  /// default rather than throwing: a preference is never worth a crash.
  Stream<double> watchNumber(String key, {required double orElse}) {
    return (_db.select(_db.settings)..where((s) => s.key.equals(key)))
        .watchSingleOrNull()
        .map((row) => double.tryParse(row?.value ?? '') ?? orElse);
  }

  Future<void> setNumber(String key, double value) =>
      _write(key, value.toString());

  Future<void> _write(String key, String value) {
    return _db
        .into(_db.settings)
        .insertOnConflictUpdate(
          SettingsCompanion.insert(key: key, value: value),
        );
  }
}
