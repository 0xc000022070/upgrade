import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spectacle/data/database.dart';
import 'package:spectacle/data/enums.dart';
import 'package:spectacle/data/repositories/host_repository.dart';
import 'package:spectacle/data/repositories/key_repository.dart';
import 'package:spectacle/data/repositories/path_repository.dart';
import 'package:spectacle/data/repositories/shell_tab_repository.dart';
import 'package:spectacle/data/repositories/settings_repository.dart';

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

/// The v3 schema exactly as it shipped, for the attachments upgrade. Same
/// reason as
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

/// The v5 schema exactly as it shipped, for the project tree. This is the
/// version every device that has taken every migration is on, so it is the
/// jump the next release actually performs on a phone; the v2 fixture below
/// only covers the one device that skipped everything.
const _v5Schema = [
  ..._v3Schema,
  '''
CREATE TABLE attachments (
  id TEXT NOT NULL,
  item_id TEXT NOT NULL REFERENCES tasks (id),
  kind TEXT NOT NULL,
  value TEXT NOT NULL,
  created_at TEXT NOT NULL,
  PRIMARY KEY (id)
)''',
  '''
CREATE TABLE settings (
  key TEXT NOT NULL,
  value TEXT NOT NULL,
  PRIMARY KEY (key)
)''',
];

/// The v6 schema exactly as it shipped, for the keys and hosts upgrade. v6 is
/// what
/// phase 8 put on the emulator, so this is the jump a device that took the last
/// release actually performs.
const _v6Schema = [
  ..._v5Schema,
  'ALTER TABLE projects ADD COLUMN parent_id TEXT REFERENCES projects (id)',
];

/// The v7 schema exactly as it shipped, for the port upgrade. `hosts` has no
/// `port` here, which is the whole point: v7 is what every device that took the
/// keys and hosts release is on, and the column has to arrive on a table this
/// file wrote rather than on one the current definitions created with it
/// already there.
const _v7Schema = [
  ..._v6Schema,
  '''
CREATE TABLE keys (
  id TEXT NOT NULL,
  name TEXT NOT NULL,
  public_key TEXT NOT NULL,
  fingerprint TEXT NOT NULL,
  created_at TEXT NOT NULL,
  PRIMARY KEY (id)
)''',
  '''
CREATE TABLE hosts (
  id TEXT NOT NULL,
  name TEXT NOT NULL,
  address TEXT NOT NULL,
  user TEXT NOT NULL,
  key_id TEXT NOT NULL REFERENCES keys (id),
  PRIMARY KEY (id)
)''',
  '''
CREATE TABLE host_integrations (
  host_id TEXT NOT NULL REFERENCES hosts (id),
  kind TEXT NOT NULL,
  PRIMARY KEY (host_id, kind)
)''',
];

/// The v8 schema: v7 plus the column the port upgrade added. What every device
/// that has taken every release so far is on, and so the jump the paths tables
/// actually perform.
const _v8Schema = [
  ..._v7Schema,
  'ALTER TABLE hosts ADD COLUMN port INTEGER NOT NULL DEFAULT 22',
];

/// The v11 schema: everything v8 had plus the host key columns, the two paths
/// tables and the shell tabs, with `agent` still on `paths`. The jump off it is
/// the one that moves the kind onto the dispatch, so the column has to be here
/// on a table this file wrote.
const _v11Schema = [
  ..._v8Schema,
  'ALTER TABLE hosts ADD COLUMN host_key_type TEXT',
  'ALTER TABLE hosts ADD COLUMN host_key_fingerprint TEXT',
  'ALTER TABLE hosts ADD COLUMN host_key_pinned_at TEXT',
  '''
CREATE TABLE paths (
  id TEXT NOT NULL,
  host_id TEXT NOT NULL REFERENCES hosts (id),
  directory TEXT NOT NULL,
  label TEXT NOT NULL,
  agent TEXT NOT NULL DEFAULT 'claude',
  created_at TEXT NOT NULL,
  PRIMARY KEY (id)
)''',
  '''
CREATE TABLE dispatches (
  id TEXT NOT NULL,
  item_id TEXT NOT NULL REFERENCES tasks (id),
  path_id TEXT NOT NULL REFERENCES paths (id),
  pane_id TEXT NOT NULL,
  sent_at TEXT NOT NULL,
  PRIMARY KEY (id)
)''',
  '''
CREATE TABLE shell_tabs (
  host_id TEXT NOT NULL REFERENCES hosts (id),
  number INTEGER NOT NULL,
  active INTEGER NOT NULL,
  opened_at TEXT NOT NULL,
  PRIMARY KEY (host_id, number)
)''',
];

/// The v13 schema: v8 plus the host key columns, the vnc password, the two
/// paths tables with the agent already moved onto the dispatch, and the shell
/// tabs. `paths` has no `project_id` here, which is the whole point — the
/// upgrade off it is the one that links a directory to a project.
const _v13Schema = [
  ..._v8Schema,
  'ALTER TABLE hosts ADD COLUMN host_key_type TEXT',
  'ALTER TABLE hosts ADD COLUMN host_key_fingerprint TEXT',
  'ALTER TABLE hosts ADD COLUMN host_key_pinned_at TEXT',
  'ALTER TABLE hosts ADD COLUMN vnc_password TEXT',
  '''
CREATE TABLE paths (
  id TEXT NOT NULL,
  host_id TEXT NOT NULL REFERENCES hosts (id),
  directory TEXT NOT NULL,
  label TEXT NOT NULL,
  created_at TEXT NOT NULL,
  PRIMARY KEY (id)
)''',
  '''
CREATE TABLE dispatches (
  id TEXT NOT NULL,
  item_id TEXT NOT NULL REFERENCES tasks (id),
  path_id TEXT NOT NULL REFERENCES paths (id),
  pane_id TEXT NOT NULL,
  agent TEXT NOT NULL DEFAULT 'claude',
  model TEXT,
  sent_at TEXT NOT NULL,
  PRIMARY KEY (id)
)''',
  '''
CREATE TABLE shell_tabs (
  host_id TEXT NOT NULL REFERENCES hosts (id),
  number INTEGER NOT NULL,
  active INTEGER NOT NULL,
  opened_at TEXT NOT NULL,
  PRIMARY KEY (host_id, number)
)''',
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
    dir = await Directory.systemTemp.createTemp('spectacle-migration');
    file = File('${dir.path}/spectacle.sqlite');
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

  test('a v2 database upgrades to the current schema with every row still there', () async {
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
      db.schemaVersion,
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
    // A null parent is a root, so the flat list the user had is the
    // tree the migration produces. Nothing is orphaned and nothing moves.
    expect(projects.every((p) => p.parentId == null), isTrue);

    expect(
      (await db.select(db.notes).get()).single.content,
      'Probar Garage y MinIO',
    );
    expect(
      (await db.select(db.activityEvents).get()).single.action,
      ActivityAction.completed,
    );

    // Every table a later version added exists and is empty rather than absent.
    expect(await db.select(db.goals).get(), isEmpty);
    expect(await db.select(db.attachments).get(), isEmpty);
    expect(await db.select(db.settings).get(), isEmpty);
    // No host is assumed, so the upgrade lands on the same empty tables a
    // fresh install has and the AGENTS panel comes up blocked.
    expect(await db.select(db.keys).get(), isEmpty);
    expect(await db.select(db.hosts).get(), isEmpty);
    expect(await db.select(db.paths).get(), isEmpty);
    expect(await db.select(db.dispatches).get(), isEmpty);
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
      db.schemaVersion,
    );
    expect(attachments.map((a) => a.id), ['l1', 'l2']);
    expect(attachments.every((a) => a.itemId == 't1'), isTrue);
    expect(attachments.every((a) => a.kind == AttachmentKind.url), isTrue);
    expect(attachments.map((a) => a.value), [
      'https://www.example.com/a',
      'https://drift.simonbinder.eu',
    ]);
    expect(attachments.first.createdAt, DateTime.parse(stamp(22)));

    // The fold copies rather than moves: a rollback to v3 has to find its rows
    // where it left them.
    expect(await db.select(db.links).get(), hasLength(2));
  });

  test('settings survive the jump the installed build will make', () async {
    // faraday runs a v2 build, so the v2 -> v7 jump is the one that matters:
    // the added table has to appear on a database full of rows, and a
    // preference written into it has to read back.
    await writeV2Fixture();

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final settings = SettingsRepository(db);

    expect(
      await settings.flag(SettingsRepository.staticEnabled, orElse: true),
      isTrue,
      reason: 'a preference nobody has written is the default, not an error',
    );

    await settings.setFlag(SettingsRepository.staticEnabled, false);
    expect(
      await settings.flag(SettingsRepository.staticEnabled, orElse: true),
      isFalse,
    );
    // Upsert, not insert: setting the same key twice must not fail.
    await settings.setFlag(SettingsRepository.staticEnabled, true);
    expect((await db.select(db.settings).get()), hasLength(1));

    // The rows the migration carried are still there under the new table.
    expect(await db.select(db.tasks).get(), hasLength(4));
  });

  test(
    'a v5 database gains parent_id with every project still a root',
    () async {
      // The jump a device that has taken every migration actually makes.
      final executor = NativeDatabase(file);
      await executor.ensureOpen(_V2Database(5, _v5Schema));
      for (final row in [
        ['p1', 'Infra', 'high'],
        ['p2', 'Homelab', 'normal'],
      ]) {
        await executor.runInsert(
          'INSERT INTO projects (id, name, description, objective, status, '
          'priority, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
          [row[0], row[1], '', '', 'active', row[2], stamp(20), stamp(20)],
        );
      }
      await executor.runInsert(
        'INSERT INTO tasks (id, project_id, title, done, blocked_reason, '
        'is_next, effort, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, NULL, 0, NULL, ?, ?)',
        ['t1', 'p2', 'rack the switch', 1, stamp(21), stamp(21)],
      );
      await executor.runInsert(
        'INSERT INTO settings (key, value) VALUES (?, ?)',
        [SettingsRepository.staticEnabled, 'false'],
      );
      await executor.close();

      final db = AppDatabase(NativeDatabase(file));
      addTearDown(db.close);

      final projects = await db.select(db.projects).get();
      expect(
        await db
            .customSelect('PRAGMA user_version')
            .getSingle()
            .then((row) => row.read<int>('user_version')),
        db.schemaVersion,
      );
      expect(projects.map((p) => p.id), ['p1', 'p2']);
      expect(projects.every((p) => p.parentId == null), isTrue);
      // Both are roots, so both are on the list the tab reads, and neither has
      // borrowed the other's task.
      expect((await db.watchRootSummaries().first).map((p) => p.projectId), [
        'p1',
        'p2',
      ]);
      expect(
        await SettingsRepository(db)
            .flag(SettingsRepository.staticEnabled, orElse: true),
        isFalse,
        reason: 'a preference written before the upgrade survives it',
      );

      // The column is writable on a row the migration carried, and the subtree
      // progress follows immediately: p1 owns no task of its own.
      await (db.update(db.projects)..where((p) => p.id.equals('p2'))).write(
        const ProjectsCompanion(parentId: Value('p1')),
      );
      final roots = await db.watchRootSummaries().first;
      expect(roots.map((p) => p.projectId), ['p1']);
      expect(roots.single.totalCount, 1);
      expect(roots.single.doneCount, 1);
      expect((await db.watchChildSummaries('p1').first).single.projectId, 'p2');
    },
  );

  test('a v6 database gains keys and hosts, both empty', () async {
    // The jump the installed v14 build makes. Two tables appear on a database
    // full of rows and nothing else moves.
    final executor = NativeDatabase(file);
    await executor.ensureOpen(_V2Database(6, _v6Schema));
    for (final row in [
      ['p1', 'Infra', null],
      ['p2', 'Homelab', 'p1'],
    ]) {
      await executor.runInsert(
        'INSERT INTO projects (id, name, description, objective, status, '
        'priority, created_at, updated_at, parent_id) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          row[0],
          row[1],
          '',
          '',
          'active',
          'high',
          stamp(20),
          stamp(20),
          row[2],
        ],
      );
    }
    await executor.runInsert(
      'INSERT INTO settings (key, value) VALUES (?, ?)',
      [SettingsRepository.staticEnabled, '0'],
    );
    await executor.close();

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);

    final projects = await db.select(db.projects).get();
    expect(
      await db
          .customSelect('PRAGMA user_version')
          .getSingle()
          .then((row) => row.read<int>('user_version')),
      db.schemaVersion,
    );
    // The project tree survives untouched: the upgrade adds tables, it does not
    // rewrite a row.
    expect(projects.map((p) => p.id), ['p1', 'p2']);
    expect(projects.firstWhere((p) => p.id == 'p2').parentId, 'p1');
    expect(
      await SettingsRepository(db)
          .flag(SettingsRepository.staticEnabled, orElse: true),
      isFalse,
    );

    // Nothing is assumed. No key, no host, and no integration switched on,
    // which is the state the AGENTS panel renders as NO HOST · SET IN SYS.
    expect(await db.select(db.keys).get(), isEmpty);
    expect(await db.select(db.hosts).get(), isEmpty);
    expect(await db.select(db.hostIntegrations).get(), isEmpty);
    expect(
      await DriftHostRepository(db)
          .watchWithIntegration(IntegrationKind.herdr)
          .first,
      isEmpty,
    );

    // And the new tables take writes on a database the migration upgraded.
    final keys = DriftKeyRepository(db);
    await keys.save(
      ManagedKey(
        id: 'k1',
        name: 'spectacle',
        publicKey: 'ssh-ed25519 AAAA spectacle',
        fingerprint: 'SHA256:abc',
        createdAt: DateTime.parse(stamp(22)),
      ),
    );
    final hosts = DriftHostRepository(db);
    await hosts.save(
      const Host(
        id: 'h1',
        name: 'nyx',
        address: '100.118.60.77',
        port: 22,
        user: 'luisnquin',
        keyId: 'k1',
      ),
    );
    await hosts.setIntegration('h1', IntegrationKind.herdr, true);
    expect((await keys.all()).single.fingerprint, 'SHA256:abc');
    expect((await db.select(db.hosts).get()).single.address, '100.118.60.77');
    expect(
      (await hosts.watchWithIntegration(IntegrationKind.herdr).first).single.id,
      'h1',
    );
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
    'a fresh install creates the current schema directly, without the upgrade '
    'path',
    () async {
      final db = AppDatabase(NativeDatabase(file));
      addTearDown(db.close);

      expect(await db.select(db.goals).get(), isEmpty);
      expect(await db.select(db.attachments).get(), isEmpty);
      expect(await db.select(db.settings).get(), isEmpty);
      expect(await db.select(db.keys).get(), isEmpty);
      expect(await db.select(db.hosts).get(), isEmpty);
      expect(await db.select(db.paths).get(), isEmpty);
      expect(await db.select(db.dispatches).get(), isEmpty);
      expect(
        await db
            .customSelect('PRAGMA user_version')
            .getSingle()
            .then((row) => row.read<int>('user_version')),
        db.schemaVersion,
      );
    },
  );

  test('a v7 host row upgrades onto port 22', () async {
    final executor = NativeDatabase(file);
    await executor.ensureOpen(_V2Database(7, _v7Schema));
    await executor.runInsert(
      'INSERT INTO keys (id, name, public_key, fingerprint, created_at) '
      'VALUES (?, ?, ?, ?, ?)',
      ['k1', 'nyx', 'ssh-ed25519 AAAA nyx', 'SHA256:k1', stamp(20)],
    );
    await executor.runInsert(
      'INSERT INTO hosts (id, name, address, user, key_id) '
      'VALUES (?, ?, ?, ?, ?)',
      ['h1', 'nyx', '100.118.60.77', 'luisnquin', 'k1'],
    );
    await executor.runInsert(
      'INSERT INTO host_integrations (host_id, kind) VALUES (?, ?)',
      ['h1', 'herdr'],
    );
    await executor.close();

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);

    expect(
      await db
          .customSelect('PRAGMA user_version')
          .getSingle()
          .then((row) => row.read<int>('user_version')),
      db.schemaVersion,
    );
    // The row the user already had keeps working, on the port the transport
    // was in fact dialling it on before the column existed.
    final host = (await DriftHostRepository(db).all()).single;
    expect(host.id, 'h1');
    expect(host.address, '100.118.60.77');
    expect(host.port, 22);
    expect(host.vncPassword, isNull);
    expect(
      (await DriftHostRepository(
        db,
      ).watchWithIntegration(IntegrationKind.herdr).first).single.id,
      'h1',
    );

    // And the upgraded table takes a port that is not the default, and the
    // password the row never had.
    await DriftHostRepository(db).save(
      Host(
        id: 'h1',
        name: host.name,
        address: host.address,
        port: 357,
        user: host.user,
        keyId: host.keyId,
        vncPassword: 'secret',
      ),
    );
    final saved = (await DriftHostRepository(db).all()).single;
    expect(saved.port, 357);
    expect(saved.vncPassword, 'secret');
  });

  test('a v8 database gains paths and dispatches, both empty', () async {
    final executor = NativeDatabase(file);
    await executor.ensureOpen(_V2Database(8, _v8Schema));
    await executor.runInsert(
      'INSERT INTO keys (id, name, public_key, fingerprint, created_at) '
      'VALUES (?, ?, ?, ?, ?)',
      ['k1', 'nyx', 'ssh-ed25519 AAAA nyx', 'SHA256:k1', stamp(20)],
    );
    await executor.runInsert(
      'INSERT INTO hosts (id, name, address, port, user, key_id) '
      'VALUES (?, ?, ?, ?, ?, ?)',
      ['h1', 'nyx', '100.118.60.77', 357, 'luisnquin', 'k1'],
    );
    await executor.close();

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);

    expect(
      await db
          .customSelect('PRAGMA user_version')
          .getSingle()
          .then((row) => row.read<int>('user_version')),
      db.schemaVersion,
    );
    // The host the user registered is untouched, on the port it was saved on.
    expect((await DriftHostRepository(db).all()).single.port, 357);
    // Nothing is invented for it: a directory is something the user registers,
    // so the upgrade lands on the two empty tables a fresh install has.
    expect(await db.select(db.paths).get(), isEmpty);
    expect(await db.select(db.dispatches).get(), isEmpty);

    // And both take writes on a database the migration upgraded.
    final paths = DriftPathRepository(db);
    final path = await paths.add(hostId: 'h1', directory: '~/src/spectacle');
    await db
        .into(db.tasks)
        .insert(
          TasksCompanion.insert(
            id: 'drop-1',
            title: 'send this',
            createdAt: DateTime.parse(stamp(22)),
            updatedAt: DateTime.parse(stamp(22)),
          ),
        );
    await db
        .into(db.dispatches)
        .insert(
          DispatchesCompanion.insert(
            id: 'dispatch-1',
            itemId: 'drop-1',
            pathId: path.id,
            paneId: 'wQ:pH',
            sentAt: DateTime.parse(stamp(22)),
          ),
        );
    expect((await paths.listForHost('h1')).single.label, 'spectacle');
    expect((await db.select(db.dispatches).get()).single.paneId, 'wQ:pH');
  });

  test('a dispatch keeps the agent its path carried', () async {
    final executor = NativeDatabase(file);
    await executor.ensureOpen(_V2Database(11, _v11Schema));
    await executor.runInsert(
      'INSERT INTO keys (id, name, public_key, fingerprint, created_at) '
      'VALUES (?, ?, ?, ?, ?)',
      ['k1', 'nyx', 'ssh-ed25519 AAAA nyx', 'SHA256:k1', stamp(20)],
    );
    await executor.runInsert(
      'INSERT INTO hosts (id, name, address, port, user, key_id) '
      'VALUES (?, ?, ?, ?, ?, ?)',
      ['h1', 'nyx', '100.118.60.77', 357, 'luisnquin', 'k1'],
    );
    await executor.runInsert(
      'INSERT INTO paths (id, host_id, directory, label, agent, created_at) '
      'VALUES (?, ?, ?, ?, ?, ?)',
      ['p1', 'h1', '~/src/spectacle', 'spectacle', 'codex', stamp(20)],
    );
    await executor.runInsert(
      'INSERT INTO tasks (id, title, done, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?)',
      ['drop-1', 'send this', 0, stamp(20), stamp(20)],
    );
    await executor.runInsert(
      'INSERT INTO dispatches (id, item_id, path_id, pane_id, sent_at) '
      'VALUES (?, ?, ?, ?, ?)',
      ['d1', 'drop-1', 'p1', 'wQ:pH', stamp(21)],
    );
    await executor.close();

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);

    // The send that was made by codex still says codex, and says nothing about
    // a model: the column arrives after the send, so there is none to claim.
    final dispatch = (await db.select(db.dispatches).get()).single;
    expect(dispatch.agent, 'codex');
    expect(dispatch.model, isNull);

    // And the path no longer answers for an agent at all.
    final columns = await db
        .customSelect('PRAGMA table_info(paths)')
        .get()
        .then((rows) => rows.map((row) => row.read<String>('name')).toList());
    expect(columns, isNot(contains('agent')));
    // And gains the link on the way through, since the rebuild that drops
    // `agent` builds the table from the current definition.
    expect(columns, contains('project_id'));
    expect((await db.select(db.paths).get()).single.projectId, isNull);
    expect(
      (await DriftPathRepository(db).listForHost('h1')).single.label,
      'spectacle',
    );
  });

  test('a v13 database reads back with every path unlinked', () async {
    final executor = NativeDatabase(file);
    await executor.ensureOpen(_V2Database(13, _v13Schema));
    await executor.runInsert(
      'INSERT INTO keys (id, name, public_key, fingerprint, created_at) '
      'VALUES (?, ?, ?, ?, ?)',
      ['k1', 'nyx', 'ssh-ed25519 AAAA nyx', 'SHA256:k1', stamp(20)],
    );
    await executor.runInsert(
      'INSERT INTO hosts (id, name, address, port, user, key_id) '
      'VALUES (?, ?, ?, ?, ?, ?)',
      ['h1', 'nyx', '100.118.60.77', 357, 'luisnquin', 'k1'],
    );
    await executor.runInsert(
      'INSERT INTO paths (id, host_id, directory, label, created_at) '
      'VALUES (?, ?, ?, ?, ?)',
      ['p1', 'h1', '~/src/spectacle', 'spectacle', stamp(20)],
    );
    await executor.close();

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);

    // The directory is still registered and belongs to nobody: a path that
    // predates the link is exactly what an unlinked one is, so there is
    // nothing to backfill and nothing was.
    final path = (await DriftPathRepository(db).listForHost('h1')).single;
    expect(path.directory, '~/src/spectacle');
    expect(path.projectId, isNull);
    expect(await DriftPathRepository(db).watchUnlinked().first, hasLength(1));
  });

  test('an upgraded database gains shell tabs, empty and writable', () async {
    final executor = NativeDatabase(file);
    await executor.ensureOpen(_V2Database(8, _v8Schema));
    await executor.runInsert(
      'INSERT INTO keys (id, name, public_key, fingerprint, created_at) '
      'VALUES (?, ?, ?, ?, ?)',
      ['k1', 'nyx', 'ssh-ed25519 AAAA nyx', 'SHA256:k1', stamp(20)],
    );
    await executor.runInsert(
      'INSERT INTO hosts (id, name, address, port, user, key_id) '
      'VALUES (?, ?, ?, ?, ?, ?)',
      ['h1', 'nyx', '100.118.60.77', 357, 'luisnquin', 'k1'],
    );
    await executor.close();

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);

    // A tab is written when a shell opens, so an install that upgrades into
    // the table comes up on no sessions, which is what it came up on before.
    final tabs = DriftShellTabRepository(db);
    expect(await tabs.all(), isEmpty);

    await tabs.open('h1', 1);
    await tabs.open('h1', 2);
    expect((await tabs.all()).map((tab) => [tab.number, tab.active]), [
      [1, false],
      [2, true],
    ]);
  });
}
