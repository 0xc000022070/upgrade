import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:striked/data/database.dart';
import 'package:striked/data/enums.dart';
import 'package:striked/data/repositories/activity_repository.dart';
import 'package:striked/data/repositories/mutation.dart';
import 'package:striked/data/repositories/project_repository.dart';
import 'package:striked/data/repositories/task_repository.dart';

void main() {
  late AppDatabase db;
  late ActivityRepository activity;
  late ProjectRepository projects;
  late TaskRepository tasks;
  late Mutations<Task> onTask;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    activity = ActivityRepository(db);
    projects = ProjectRepository(db, activity);
    tasks = TaskRepository(db, activity);
    onTask = Mutations<Task>(
      db: db,
      activity: activity,
      entityType: EntityType.task,
      read: (id) =>
          (db.select(db.tasks)..where((t) => t.id.equals(id))).getSingle(),
      title: (task) => task.title,
      context: (task) async {
        final projectId = task.projectId;
        if (projectId == null) return null;
        final row = await (db.select(
          db.projects,
        )..where((p) => p.id.equals(projectId))).getSingle();
        return row.name;
      },
    );
  });

  tearDown(() => db.close());

  Future<List<ActivityEvent>> events() => db.select(db.activityEvents).get();

  Future<String> aTask({String title = 'Backups'}) async {
    final project = await projects.create(name: 'Infra personal');
    return tasks.create(projectId: project, title: title);
  }

  Future<void> rename(String id, String title, {DateTime? at}) => onTask
      .on(id)
      .at(at)
      .titled(title)
      .writes(ActivityAction.updated, (task, now) async {
        await (db.update(db.tasks)..where((t) => t.id.equals(id))).write(
          TasksCompanion(title: Value(title), updatedAt: Value(now)),
        );
        return null;
      });

  group('the mutation builder', () {
    test('writes the row and appends exactly one event', () async {
      final id = await aTask();
      final before = (await events()).length;

      await rename(id, 'Backups off site');

      final row = await (db.select(
        db.tasks,
      )..where((t) => t.id.equals(id))).getSingle();
      expect(row.title, 'Backups off site');
      expect(await events(), hasLength(before + 1));
    });

    test('a guarded no-op writes nothing and logs nothing', () async {
      final id = await aTask();
      final before = (await events()).length;

      await onTask
          .on(id)
          .unchangedWhen((task) => task.title == 'Backups')
          .writes(ActivityAction.updated, (task, now) async {
            fail('the write ran for a mutation that changed nothing');
          });

      expect(await events(), hasLength(before));
    });

    test('the row and its event share one instant', () async {
      final id = await aTask();
      final when = DateTime.utc(2026, 3, 14, 9, 26, 53);

      await rename(id, 'Backups off site', at: when);

      final row = await (db.select(
        db.tasks,
      )..where((t) => t.id.equals(id))).getSingle();
      final event = (await events()).last;
      expect(row.updatedAt, when);
      expect(event.createdAt, when);
    });

    test('a write that throws takes its event down with it', () async {
      final id = await aTask();
      final before = (await events()).length;

      await expectLater(
        onTask.on(id).writes(ActivityAction.updated, (task, now) async {
          await (db.update(db.tasks)..where((t) => t.id.equals(id))).write(
            TasksCompanion(title: const Value('half written')),
          );
          throw StateError('the host went away mid-write');
        }),
        throwsStateError,
      );

      final row = await (db.select(
        db.tasks,
      )..where((t) => t.id.equals(id))).getSingle();
      expect(row.title, 'Backups', reason: 'the write rolled back');
      expect(await events(), hasLength(before));
    });

    test('what the write says it did becomes the event detail', () async {
      final id = await aTask();

      await onTask
          .on(id)
          .writes(ActivityAction.moved, (task, now) async => 'bundle of 3');

      final entry = AppDatabase.activityEntryOf((await events()).last);
      expect(entry.detail, 'bundle of 3');
    });

    test('the event carries the row title and the project it sat in', () async {
      final id = await aTask(title: 'Storage');

      await onTask
          .on(id)
          .writes(ActivityAction.blocked, (task, now) async => null);

      final entry = AppDatabase.activityEntryOf((await events()).last);
      expect(entry.title, 'Storage');
      expect(entry.context, 'Infra personal');
    });

    test('a title override names what the row is about to become', () async {
      final id = await aTask();

      await rename(id, 'Backups off site');

      final entry = AppDatabase.activityEntryOf((await events()).last);
      expect(entry.title, 'Backups off site');
    });

    test('a context override names where the row landed', () async {
      final id = await aTask();
      final elsewhere = await projects.create(name: 'Dotfiles');

      await onTask
          .on(id)
          .context(() async {
            final row = await (db.select(
              db.projects,
            )..where((p) => p.id.equals(elsewhere))).getSingle();
            return row.name;
          })
          .writes(ActivityAction.moved, (task, now) async => null);

      final entry = AppDatabase.activityEntryOf((await events()).last);
      expect(entry.context, 'Dotfiles');
    });
  });
}
