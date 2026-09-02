import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotline/data/database.dart';
import 'package:hotline/data/enums.dart';

/// The v2 schema exactly as it shipped, written out by hand: the point of the
/// test is that the v3 migration meets a database it did not create, so the
/// fixture must not come from the current table definitions.
const _v2Schema = [
  '''
CREATE TABLE projects (
  id TEXT NOT NULL,
  name TEXT NOT NULL,
  description TEXT NOT NULL,
  objective TEXT NOT NULL,
  status TEXT NOT NULL,
  priority TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (id)
)''',
  '''
CREATE TABLE tasks (
  id TEXT NOT NULL,
  project_id TEXT REFERENCES projects (id),
  title TEXT NOT NULL,
  done INTEGER NOT NULL DEFAULT 0 CHECK (done IN (0, 1)),
  blocked_reason TEXT,
  is_next INTEGER NOT NULL DEFAULT 0 CHECK (is_next IN (0, 1)),
  effort INTEGER,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (id)
)''',
  '''
CREATE TABLE notes (
  id TEXT NOT NULL,
  project_id TEXT REFERENCES projects (id),
  task_id TEXT REFERENCES tasks (id),
  content TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (id)
)''',
  '''
CREATE TABLE activity_events (
  id TEXT NOT NULL,
  entity_type TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  action TEXT NOT NULL,
  payload TEXT,
  created_at TEXT NOT NULL,
  PRIMARY KEY (id)
)''',
];

/// The v3 schema exactly as it shipped, for the §39.10 upgrade. Same reason as
/// [_v2Schema]: `links` no longer has a table class to generate DDL from that
/// would prove anything, and `attachments` must meet a database it did not
/// create.
const _v3Schema = [
  ..._v2Schema,
  '''
CREATE TABLE goals (
  id TEXT NOT NULL,
  project_id TEXT NOT NULL REFERENCES projects (id),
  title TEXT NOT NULL,
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  PRIMARY KEY (id)
)''',
  '''
CREATE TABLE links (
  id TEXT NOT NULL,
  task_id TEXT NOT NULL REFERENCES tasks (id),
  url TEXT NOT NULL,
  label TEXT,
  created_at TEXT NOT NULL,
  PRIMARY KEY (id)
)''',
  'ALTER TABLE tasks ADD COLUMN goal_id TEXT REFERENCES goals (id)',
  'ALTER TABLE tasks ADD COLUMN bundle_id TEXT',
];

/// Drives [QueryExecutor.ensureOpen] to stamp `user_version = 2` and lay down
/// the old schema, which is what makes the file drift later opens a real v2
/// database rather than a v3 one with rows in it.
class _V2Database implements QueryExecutorUser {
  _V2Database([this.schemaVersion = 2, this.statements = _v2Schema]);

  @override
  final int schemaVersion;

  final List<String> statements;

  @override
  Future<void> beforeOpen(
    QueryExecutor executor,
    OpeningDetails details,
  ) async {
    // The executor handed to beforeOpen refuses statements until it has been
    // told it is open; drift's own Migrator does the same before it runs DDL.
    await executor.ensureOpen(this);
    if (!details.wasCreated) return;
    for (final statement in statements) {
      await executor.runCustom(statement);
    }
  }
}

void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('hotline-migration');
    file = File('${dir.path}/hotline.sqlite');
  });

  tearDown(() => dir.delete(recursive: true));

  /// ISO-8601 UTC, the shape AppDatabase.options stores timestamps in.
  String stamp(int day) =>
      '2026-08-${day.toString().padLeft(2, '0')}'
      'T10:00:00.000Z';

  Future<void> writeV2Fixture() async {
    final executor = NativeDatabase(file);
    await executor.ensureOpen(_V2Database());
    await executor.runInsert(
      'INSERT INTO projects (id, name, description, objective, status, '
      'priority, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      [
        'p1',
        'Infra personal',
        'Servicios propios',
        'Reduce SaaS dependency',
        'active',
        'high',
        stamp(20),
        stamp(20),
      ],
    );
    for (final row in [
      ['t1', 'p1', 'Postgres propio', 1, null, 0],
      ['t2', 'p1', 'Object storage', 0, 'Esperando proveedor S3', 0],
      ['t3', null, 'revisar pgbouncer', 0, null, 0],
      ['t4', null, 'comprar cable USB-C', 0, null, 1],
    ]) {
      await executor.runInsert(
        'INSERT INTO tasks (id, project_id, title, done, blocked_reason, '
        'is_next, effort, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?, NULL, ?, ?)',
        [...row, stamp(21), stamp(21)],
      );
    }
    await executor.runInsert(
      'INSERT INTO notes (id, project_id, task_id, content, created_at, '
      'updated_at) VALUES (?, ?, ?, ?, ?, ?)',
      ['n1', 'p1', 't2', 'Probar Garage y MinIO', stamp(21), stamp(21)],
    );
    await executor.runInsert(
      'INSERT INTO activity_events (id, entity_type, entity_id, action, '
      'payload, created_at) VALUES (?, ?, ?, ?, ?, ?)',
      [
        'e1',
        'task',
        't1',
        'completed',
        '{"title":"Postgres propio","context":"Infra personal"}',
        stamp(21),
      ],
    );
    await executor.close();
  }

  test('a v2 database upgrades to v4 with every row still there', () async {
    await writeV2Fixture();

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);

    // Forces ensureOpen, and with it the migration.
    final tasks = await db.select(db.tasks).get();

    expect(
      await db
          .customSelect('PRAGMA user_version')
          .getSingle()
          .then((row) => row.read<int>('user_version')),
      4,
    );

    final projects = await db.select(db.projects).get();
    expect(projects.single.name, 'Infra personal');
    expect(projects.single.status, ProjectStatus.active);
    expect(projects.single.priority, Priority.high);
    expect(projects.single.createdAt, DateTime.parse(stamp(20)));

    expect(tasks.map((t) => t.id), ['t1', 't2', 't3', 't4']);
    expect(tasks.firstWhere((t) => t.id == 't1').done, isTrue);
    expect(
      tasks.firstWhere((t) => t.id == 't2').blockedReason,
      'Esperando proveedor S3',
    );
    expect(tasks.firstWhere((t) => t.id == 't3').projectId, isNull);
    expect(tasks.firstWhere((t) => t.id == 't4').isNext, isTrue);

    // The added columns exist and read as null on rows written before them.
    expect(tasks.every((t) => t.goalId == null), isTrue);
    expect(tasks.every((t) => t.bundleId == null), isTrue);

    expect(
      (await db.select(db.notes).get()).single.content,
      'Probar Garage y MinIO',
    );
    expect(
      (await db.select(db.activityEvents).get()).single.action,
      ActivityAction.completed,
    );

    // The v3 and v4 tables exist and are empty rather than absent.
    expect(await db.select(db.goals).get(), isEmpty);
    expect(await db.select(db.attachments).get(), isEmpty);
  });

  test('a v3 database folds its links into attachments', () async {
    // A v2 file first, then the v3 shape on top of it: the fixture is the
    // schema as it shipped, not as the current table classes would draw it.
    final executor = NativeDatabase(file);
    await executor.ensureOpen(_V2Database(3, _v3Schema));
    await executor.runInsert(
      'INSERT INTO projects (id, name, description, objective, status, '
      'priority, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      ['p1', 'Infra', '', '', 'active', 'high', stamp(20), stamp(20)],
    );
    await executor.runInsert(
      'INSERT INTO tasks (id, project_id, title, done, blocked_reason, '
      'is_next, effort, created_at, updated_at) '
      'VALUES (?, ?, ?, 0, NULL, 0, NULL, ?, ?)',
      ['t1', 'p1', 'leer esto', stamp(21), stamp(21)],
    );
    for (final row in [
      ['l1', 'https://www.example.com/a', 22],
      ['l2', 'https://drift.simonbinder.eu', 23],
    ]) {
      await executor.runInsert(
        'INSERT INTO links (id, task_id, url, label, created_at) '
        'VALUES (?, ?, ?, NULL, ?)',
        [row[0], 't1', row[1], stamp(row[2] as int)],
      );
    }
    await executor.close();

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);

    final attachments = await db.select(db.attachments).get();

    expect(
      await db
          .customSelect('PRAGMA user_version')
          .getSingle()
          .then((row) => row.read<int>('user_version')),
      4,
    );
    expect(attachments.map((a) => a.id), ['l1', 'l2']);
    expect(attachments.every((a) => a.itemId == 't1'), isTrue);
    expect(attachments.every((a) => a.kind == AttachmentKind.url), isTrue);
    expect(attachments.map((a) => a.value), [
      'https://www.example.com/a',
      'https://drift.simonbinder.eu',
    ]);
    expect(attachments.first.createdAt, DateTime.parse(stamp(22)));

    // §39.10 copies rather than moves: a rollback to v3 has to find its rows
    // where it left them.
    expect(await db.select(db.links).get(), hasLength(2));
  });

  test('the upgraded database accepts writes to the new columns', () async {
    await writeV2Fixture();

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);

    await db
        .into(db.goals)
        .insert(
          GoalsCompanion.insert(
            id: 'g1',
            projectId: 'p1',
            title: 'Reduce SaaS',
            createdAt: DateTime.parse(stamp(22)),
          ),
        );
    await (db.update(db.tasks)..where((t) => t.id.equals('t2'))).write(
      const TasksCompanion(goalId: Value('g1'), bundleId: Value('b1')),
    );

    final task = await (db.select(
      db.tasks,
    )..where((t) => t.id.equals('t2'))).getSingle();
    expect(task.goalId, 'g1');
    expect(task.bundleId, 'b1');
    expect((await db.watchGoalSummaries('p1').first).single.totalCount, 1);
  });

  test(
    'a fresh install creates v4 directly, without the upgrade path',
    () async {
      final db = AppDatabase(NativeDatabase(file));
      addTearDown(db.close);

      expect(await db.select(db.goals).get(), isEmpty);
      expect(await db.select(db.attachments).get(), isEmpty);
      expect(
        await db
            .customSelect('PRAGMA user_version')
            .getSingle()
            .then((row) => row.read<int>('user_version')),
        4,
      );
    },
  );
}
