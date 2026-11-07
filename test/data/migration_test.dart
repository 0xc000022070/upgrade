import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/data/database.dart';
import 'package:upgrade/data/enums.dart';

Future<int> _userVersion(AppDatabase db) => db
    .customSelect('PRAGMA user_version')
    .getSingle()
    .then((row) => row.read<int>('user_version'));

void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('upgrade-migration');
    file = File('${dir.path}/upgrade.sqlite');
  });

  tearDown(() => dir.delete(recursive: true));

  test('a fresh install creates the current schema', () async {
    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);

    expect(await db.select(db.settings).get(), [
      const Setting(key: 'builtin_auto_enable', value: '0'),
    ]);
    for (final table in db.allTables) {
      expect(await db.select(table).get(), isA<List<Object?>>());
    }
    expect(await _userVersion(db), db.schemaVersion);
  });

  test('a current database opens with every row still there', () async {
    final first = AppDatabase(NativeDatabase(file));
    await first
        .into(first.settings)
        .insert(SettingsCompanion.insert(key: 'theme', value: 'system'));
    await first.close();

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);

    expect(
      await db.select(db.settings).get(),
      contains(const Setting(key: 'theme', value: 'system')),
    );
  });

  test('an older database is rebuilt empty on the current schema', () async {
    final first = AppDatabase(NativeDatabase(file));
    await first
        .into(first.settings)
        .insert(SettingsCompanion.insert(key: 'theme', value: 'system'));
    await first.customStatement('PRAGMA user_version = 18');
    await first.close();

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);

    expect(await db.select(db.settings).get(), [
      const Setting(key: 'builtin_auto_enable', value: '0'),
    ]);
    expect(await _userVersion(db), db.schemaVersion);
  });
  test('a v19 shell tab keeps its row and gains a null launch', () async {
    final first = AppDatabase(NativeDatabase(file));
    await first.customStatement('ALTER TABLE shell_tabs DROP COLUMN launch');
    await first.customStatement(
      "INSERT INTO shell_tabs (host_id, number, active, opened_at, "
      "remote_session) VALUES ('h1', 3, 1, '2026-09-29T00:00:00.000Z', "
      "'m0123456789abcdef')",
    );
    await first.customStatement('PRAGMA user_version = 19');
    await first.close();

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);

    final rows = await db.select(db.shellTabs).get();
    expect(rows.single.number, 3);
    expect(rows.single.remoteSession, 'm0123456789abcdef');
    expect(rows.single.launch, isNull);
    await (db.update(db.shellTabs)..where((t) => t.number.equals(3))).write(
      const ShellTabsCompanion(launch: Value('tmux:0')),
    );
    expect((await db.select(db.shellTabs).getSingle()).launch, 'tmux:0');
    expect(await _userVersion(db), db.schemaVersion);
  });

  test(
    'a v19 stamp over an existing launch column opens at the current schema',
    () async {
      final first = AppDatabase(NativeDatabase(file));
      await first.customStatement(
        "INSERT INTO shell_tabs (host_id, number, active, opened_at, "
        "remote_session, launch) VALUES ('h1', 3, 1, "
        "'2026-09-29T00:00:00.000Z', 'm0123456789abcdef', 'tmux:0')",
      );
      await first.customStatement('PRAGMA user_version = 19');
      await first.close();

      final db = AppDatabase(NativeDatabase(file));
      addTearDown(db.close);

      final row = await db.select(db.shellTabs).getSingle();
      expect(row.number, 3);
      expect(row.remoteSession, 'm0123456789abcdef');
      expect(row.launch, 'tmux:0');
      expect(await _userVersion(db), db.schemaVersion);
    },
  );

  test('a v20 shell tab keeps its row and gains a null position', () async {
    final first = AppDatabase(NativeDatabase(file));
    await first.customStatement('ALTER TABLE shell_tabs DROP COLUMN position');
    await first.customStatement(
      "INSERT INTO shell_tabs (host_id, number, active, opened_at, "
      "remote_session, launch) VALUES ('h1', 3, 1, "
      "'2026-09-29T00:00:00.000Z', 'm0123456789abcdef', 'tmux:0')",
    );
    await first.customStatement('PRAGMA user_version = 20');
    await first.close();

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);

    final row = await db.select(db.shellTabs).getSingle();
    expect(row.number, 3);
    expect(row.launch, 'tmux:0');
    expect(row.position, isNull);
    await (db.update(db.shellTabs)..where((t) => t.number.equals(3))).write(
      const ShellTabsCompanion(position: Value(0)),
    );
    expect((await db.select(db.shellTabs).getSingle()).position, 0);
    expect(await _userVersion(db), db.schemaVersion);
  });

  test('a v21 host keeps its row and gains a null system', () async {
    final first = AppDatabase(NativeDatabase(file));
    await first.customStatement('ALTER TABLE hosts DROP COLUMN system');
    await first.customStatement(
      "INSERT INTO hosts (id, name, address, port, user, key_id) "
      "VALUES ('h1', 'oak', '198.51.100.77', 357, 'luisnquin', 'k1')",
    );
    await first.customStatement('PRAGMA user_version = 21');
    await first.close();

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);

    final row = await db.select(db.hosts).getSingle();
    expect(row.name, 'oak');
    expect(row.port, 357);
    expect(row.system, isNull);
    await (db.update(db.hosts)..where((h) => h.id.equals('h1'))).write(
      const HostsCompanion(system: Value('nixos')),
    );
    expect((await db.select(db.hosts).getSingle()).system, 'nixos');
    expect(await _userVersion(db), db.schemaVersion);
  });

  test('a v22 shell tab keeps its row and rides the shared link', () async {
    final first = AppDatabase(NativeDatabase(file));
    await first.customStatement(
      'ALTER TABLE shell_tabs DROP COLUMN own_connection',
    );
    await first.customStatement(
      "INSERT INTO shell_tabs (host_id, number, active, opened_at, "
      "remote_session, launch, position) VALUES ('h1', 3, 1, "
      "'2026-09-29T00:00:00.000Z', 'm0123456789abcdef', 'tmux:0', 0)",
    );
    await first.customStatement('PRAGMA user_version = 22');
    await first.close();

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);

    final row = await db.select(db.shellTabs).getSingle();
    expect(row.number, 3);
    expect(row.launch, 'tmux:0');
    expect(row.position, 0);
    expect(row.ownConnection, isNull);
    await (db.update(db.shellTabs)..where((t) => t.number.equals(3))).write(
      const ShellTabsCompanion(ownConnection: Value(true)),
    );
    expect((await db.select(db.shellTabs).getSingle()).ownConnection, isTrue);
    expect(await _userVersion(db), db.schemaVersion);
  });

  test('a v23 dispatch keeps its row as a send that reached its pane, titled by its item', () async {
    final first = AppDatabase(NativeDatabase(file));
    await first.customStatement('DROP TABLE dispatches');
    await first.customStatement(
      'CREATE TABLE dispatches (id TEXT NOT NULL, '
      'item_id TEXT NOT NULL REFERENCES tasks (id), '
      'path_id TEXT NOT NULL REFERENCES paths (id), '
      "agent TEXT NOT NULL DEFAULT 'claude', model TEXT NULL, "
      'pane_id TEXT NOT NULL, sent_at TEXT NOT NULL, PRIMARY KEY (id))',
    );
    await first.customStatement(
      "INSERT INTO dispatches (id, item_id, path_id, agent, pane_id, sent_at) "
      "VALUES ('d1', 't1', 'p1', 'codex', 'wQ:p7', '2026-09-21T00:00:00.000Z')",
    );
    await first.customStatement(
      "INSERT INTO tasks (id, title, created_at, updated_at) VALUES ('t1', "
      "'fix the parser', '2026-09-21T00:00:00.000Z', '2026-09-21T00:00:00.000Z')",
    );
    await first.customStatement('PRAGMA user_version = 23');
    await first.close();

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);

    final row = await db.select(db.dispatches).getSingle();
    expect((row.itemId, row.agent, row.paneId), ('t1', 'codex', 'wQ:p7'));
    expect(
      (row.status, row.body, row.states),
      (DispatchStatus.sent, 'fix the parser', null),
    );
    await db
        .into(db.dispatches)
        .insert(
          DispatchesCompanion.insert(
            id: 'd2',
            pathId: 'p1',
            sentAt: DateTime.utc(2026, 10),
          ),
        );
    final unlisted = await (db.select(
      db.dispatches,
    )..where((d) => d.id.equals('d2'))).getSingle();
    expect((unlisted.itemId, unlisted.paneId), (null, null));
    expect(await _userVersion(db), db.schemaVersion);
  });

  test(
    'a send still open when the file opens is failed as interrupted',
    () async {
      final first = AppDatabase(NativeDatabase(file));
      await first
          .into(first.dispatches)
          .insert(
            DispatchesCompanion.insert(
              id: 'd1',
              pathId: 'p1',
              sentAt: DateTime.utc(2026, 10),
              status: const Value(DispatchStatus.sending),
            ),
          );
      await first.close();

      final db = AppDatabase(NativeDatabase(file));
      addTearDown(db.close);

      final row = await db.select(db.dispatches).getSingle();
      expect((row.status, row.failure), (DispatchStatus.failed, 'interrupted'));
    },
  );
}
