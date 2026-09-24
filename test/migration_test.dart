import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/data/database.dart';

Future<int> _userVersion(AppDatabase db) => db
    .customSelect('PRAGMA user_version')
    .getSingle()
    .then((row) => row.read<int>('user_version'));

void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('dazzle-migration');
    file = File('${dir.path}/dazzle.sqlite');
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
}
