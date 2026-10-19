import 'package:striked/data/database.dart';

class SettingsRepository {
  SettingsRepository(this._db);

  final AppDatabase _db;

  static const staticEnabled = 'static_enabled';

  static const alertsBlockedAgents = 'alerts_blocked_agents';
  static const alertsDoneAgents = 'alerts_done_agents';

  static const shellFontSize = 'shell_font_size';

  static const codeSidebarShare = 'code_sidebar_share';
  static const codeDrawerShare = 'code_drawer_share';

  static const diffTree = 'diff_tree';
  static const diffWrap = 'diff_wrap';

  static const themeSystem = 'theme_system';

  static const whisperLanguage = 'whisper_language';

  static const shellBarLayout = 'shell_bar_layout';

  static const phoneLinuxHosts = 'phone_linux_host';

  static const promptTarget = 'prompt_target';

  static const screensHost = 'screens_host';
  static const screensRest = 'screens_rest';

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

  Future<void> setFlag(String key, bool value) =>
      _write(key, value ? '1' : '0');

  /// A row that does not parse reads as the default rather than throwing.
  Stream<double> watchNumber(String key, {required double orElse}) {
    return (_db.select(_db.settings)..where((s) => s.key.equals(key)))
        .watchSingleOrNull()
        .map((row) => double.tryParse(row?.value ?? '') ?? orElse);
  }

  Future<void> setNumber(String key, double value) =>
      _write(key, value.toString());

  Stream<String> watchText(String key, {required String orElse}) {
    return (_db.select(_db.settings)..where((s) => s.key.equals(key)))
        .watchSingleOrNull()
        .map((row) => row?.value ?? orElse);
  }

  Future<String> text(String key, {required String orElse}) async {
    final row = await (_db.select(
      _db.settings,
    )..where((s) => s.key.equals(key))).getSingleOrNull();
    return row?.value ?? orElse;
  }

  Future<void> setText(String key, String value) => _write(key, value);

  Stream<String?> watchRaw(String key) {
    return (_db.select(_db.settings)..where((s) => s.key.equals(key)))
        .watchSingleOrNull()
        .map((row) => row?.value);
  }

  Future<void> clear(String key) =>
      (_db.delete(_db.settings)..where((s) => s.key.equals(key))).go();

  Future<void> _write(String key, String value) {
    return _db
        .into(_db.settings)
        .insertOnConflictUpdate(
          SettingsCompanion.insert(key: key, value: value),
        );
  }
}
