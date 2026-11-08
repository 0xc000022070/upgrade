import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/data/database.dart';
import 'package:upgrade/data/enums.dart';
import 'package:upgrade/data/raw_tables.dart';

Future<void> _seed(AppDatabase db) async {
  await db
      .into(db.projects)
      .insert(
        ProjectsCompanion.insert(
          id: 'proj-1',
          name: 'upgrade',
          description: 'the phone, on the phone',
          objective: 'survive a rename',
          status: ProjectStatus.active,
          priority: Priority.high,
          createdAt: DateTime.utc(2026, 9, 1),
          updatedAt: DateTime.utc(2026, 9, 1),
        ),
      );
  await db
      .into(db.tasks)
      .insert(
        TasksCompanion.insert(
          id: 't1',
          title: 'carry the phone',
          projectId: const Value('proj-1'),
          bundleId: const Value('b7'),
          blockedReason: const Value('waiting on the rename'),
          isNext: const Value(true),
          effort: const Value(3),
          createdAt: DateTime.utc(2026, 9, 2),
          updatedAt: DateTime.utc(2026, 9, 3),
        ),
      );
  await db
      .into(db.attachments)
      .insert(
        AttachmentsCompanion.insert(
          id: 'a1',
          itemId: 't1',
          kind: AttachmentKind.image,
          value: 'attachments/a1.jpg',
          createdAt: DateTime.utc(2026, 9, 3),
        ),
      );
  await db
      .into(db.settings)
      .insert(SettingsCompanion.insert(key: 'theme', value: 'dusk'));
}

void main() {
  late AppDatabase a;
  late AppDatabase b;

  setUp(() {
    a = AppDatabase(NativeDatabase.memory());
    b = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await a.close();
    await b.close();
  });

  test('every table is either dumped or curated by hand', () async {
    final dumped = await RawTables(a).dump();
    expect(
      {...dumped.keys, ...curatedTables},
      {for (final table in a.allTables) table.actualTableName},
    );
    expect(dumped.keys.toSet().intersection(curatedTables), isEmpty);
  });

  test('a row comes back column for column', () async {
    await _seed(a);
    final dumped = await RawTables(a).dump();
    expect(await RawTables(b).restore(dumped), 5);

    final task = await (b.select(b.tasks)).getSingle();
    expect(task.title, 'carry the phone');
    expect(task.projectId, 'proj-1');
    expect(task.bundleId, 'b7');
    expect(task.blockedReason, 'waiting on the rename');
    expect(task.isNext, isTrue);
    expect(task.effort, 3);
    expect(task.createdAt, DateTime.utc(2026, 9, 2));
    expect(task.updatedAt, DateTime.utc(2026, 9, 3));

    final attachment = await (b.select(b.attachments)).getSingle();
    expect(attachment.kind, AttachmentKind.image);
    expect(attachment.value, 'attachments/a1.jpg');
    expect(
      (await (b.select(
        b.settings,
      )..where((s) => s.key.equals('theme'))).getSingle()).value,
      'dusk',
    );
  });

  test('a second restore is the same phone as the first', () async {
    await _seed(a);
    final dumped = await RawTables(a).dump();
    await RawTables(b).restore(dumped);
    await RawTables(b).restore(dumped);
    expect((await b.select(b.tasks).get()).length, 1);
    expect((await b.select(b.projects).get()).length, 1);
    expect(await RawTables(b).dump(), dumped);
  });

  test('a table or column this build does not know is stepped over', () async {
    await _seed(a);
    final dumped = await RawTables(a).dump();
    dumped['frames'] = [
      {'id': 'f1'},
    ];
    dumped['tasks']!.first['favouriteColour'] = 'green';
    expect(await RawTables(b).restore(dumped), 5);
    expect((await b.select(b.tasks).getSingle()).title, 'carry the phone');
  });

  test('a blob travels as base64 and lands as bytes', () async {
    // No column in this schema is declared a blob, but sqlite stores what it is given.
    final bytes = Uint8List.fromList([0, 1, 250, 255]);
    await a.customStatement('INSERT INTO settings (key, value) VALUES (?, ?)', [
      'k',
      bytes,
    ]);
    final dumped = await RawTables(a).dump();
    expect(
      dumped['settings']!.singleWhere((row) => row['key'] == 'k')['value'],
      {'b64': base64Encode(bytes)},
    );
    expect(() => jsonEncode(dumped), returnsNormally);

    await RawTables(b).restore(dumped);
    final landed = await b
        .customSelect("SELECT value FROM settings WHERE key = 'k'")
        .getSingle();
    expect(landed.data['value'], bytes);
  });
}
