import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotline/data/database.dart';
import 'package:hotline/data/enums.dart';
import 'package:hotline/data/repositories/activity_repository.dart';
import 'package:hotline/data/repositories/note_repository.dart';
import 'package:hotline/data/repositories/project_repository.dart';
import 'package:hotline/data/repositories/task_repository.dart';

void main() {
  late AppDatabase db;
  late ProjectRepository projects;
  late TaskRepository tasks;
  late NoteRepository notes;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    final activity = ActivityRepository(db);
    projects = ProjectRepository(db, activity);
    tasks = TaskRepository(db, activity);
    notes = NoteRepository(db, activity);
  });

  tearDown(() => db.close());

  Future<int> flagged() async {
    final rows = await db.select(db.tasks).get();
    return rows.where((task) => task.isNext).length;
  }

  group('project progress', () {
    test('a project with no tasks is 0%, not undefined', () async {
      await projects.create(name: 'Infra personal');

      final summary = (await db.watchProjectSummaries().first).single;

      expect(summary.totalCount, 0);
      expect(summary.ratio, 0);
      expect(summary.percent, 0);
    });

    test('counts done tasks, ignoring other projects and loose ones', () async {
      final project = await projects.create(name: 'Infra personal');
      final other = await projects.create(name: 'Dotfiles');
      final ids = [
        for (final title in ['Postgres', 'Redis', 'Storage', 'Backups', 'Mon'])
          await tasks.create(projectId: project, title: title),
      ];
      await tasks.create(projectId: other, title: 'Migrar a flakes');
      await tasks.capture('revisar pgbouncer');

      await tasks.setDone(ids[0], true);
      await tasks.setDone(ids[1], true);
      await tasks.block(ids[2], 'Esperando proveedor S3');

      final summary = (await db.watchProjectSummaries().first).firstWhere(
        (row) => row.projectId == project,
      );

      expect(summary.totalCount, 5);
      expect(summary.doneCount, 2);
      expect(summary.percent, 40);
    });
  });

  group('next action', () {
    test('at most one task carries the flag', () async {
      final project = await projects.create(name: 'Infra personal');
      final first = await tasks.create(projectId: project, title: 'Postgres');
      final second = await tasks.create(projectId: project, title: 'Redis');

      await tasks.setNext(first);
      await tasks.setNext(second);

      expect(await flagged(), 1);
      expect((await db.watchNextAction().first)!.taskId, second);
    });

    test('creating a flagged task clears the previous flag', () async {
      final project = await projects.create(name: 'Infra personal');
      final first = await tasks.create(projectId: project, title: 'Postgres');
      await tasks.setNext(first);

      await tasks.create(projectId: project, title: 'Redis', isNext: true);

      expect(await flagged(), 1);
    });

    test('completing the flagged task retires the flag', () async {
      final project = await projects.create(name: 'Infra personal');
      final task = await tasks.create(projectId: project, title: 'Postgres');
      await tasks.setNext(task);

      await tasks.setDone(task, true);

      expect(await flagged(), 0);
    });

    test('the flagged task wins over any suggestion', () async {
      final high = await projects.create(
        name: 'Infra personal',
        priority: Priority.high,
      );
      final low = await projects.create(
        name: 'Dotfiles',
        priority: Priority.low,
      );
      await tasks.create(projectId: high, title: 'Postgres');
      final flagged = await tasks.create(projectId: low, title: 'Flakes');

      await tasks.setNext(flagged);

      final next = (await db.watchNextAction().first)!;
      expect(next.taskId, flagged);
      expect(next.suggested, isFalse);
    });

    test(
      'with nothing flagged it suggests the highest-priority open task',
      () async {
        final low = await projects.create(
          name: 'Dotfiles',
          priority: Priority.low,
        );
        final high = await projects.create(
          name: 'Infra personal',
          priority: Priority.high,
        );
        await tasks.create(projectId: low, title: 'Flakes');
        await tasks.create(projectId: high, title: 'Postgres');

        final next = (await db.watchNextAction().first)!;

        expect(next.title, 'Postgres');
        expect(next.projectName, 'Infra personal');
        expect(next.suggested, isTrue);
      },
    );

    test('a blocked or done task is never suggested', () async {
      final project = await projects.create(name: 'Infra personal');
      final blocked = await tasks.create(projectId: project, title: 'Storage');
      final finished = await tasks.create(projectId: project, title: 'Redis');
      await tasks.block(blocked, 'Esperando proveedor S3');
      await tasks.setDone(finished, true);

      expect(await db.watchNextAction().first, isNull);
    });
  });

  group('blocking', () {
    test('the reason is the blocked state, and unblock clears both', () async {
      final project = await projects.create(name: 'Infra personal');
      final task = await tasks.create(projectId: project, title: 'Storage');

      await tasks.block(task, 'Esperando proveedor S3 compatible');
      final blocked = (await db.watchBlockedTasks().first).single;

      expect(blocked.taskId, task);
      expect(blocked.reason, 'Esperando proveedor S3 compatible');
      expect(blocked.projectName, 'Infra personal');

      await tasks.unblock(task);

      expect(await db.watchBlockedTasks().first, isEmpty);
    });
  });

  group('loose tasks', () {
    test('capture files a loose task and logs it as a capture', () async {
      await tasks.capture('revisar pgbouncer');

      final loose = (await tasks.watchLoose().first).single;
      expect(loose.title, 'revisar pgbouncer');
      expect(loose.projectId, isNull);

      final events = await db.select(db.activityEvents).get();
      expect(events.single.action, ActivityAction.captured);
      expect(events.single.entityType, EntityType.task);
    });

    test('moving a capture to a project takes it out of LOOSE', () async {
      final project = await projects.create(name: 'Infra personal');
      final task = await tasks.capture('revisar pgbouncer');

      await tasks.moveToProject(task, project);

      expect(await tasks.watchLoose().first, isEmpty);
      expect(await tasks.watchByProject(project).first, hasLength(1));
    });
  });

  group('activity log', () {
    test('every mutation appends an event', () async {
      final project = await projects.create(name: 'Infra personal');
      final task = await tasks.create(projectId: project, title: 'Backups');
      await tasks.setDone(task, true);

      final events = await db.select(db.activityEvents).get();

      expect(
        events.map((e) => (e.entityType, e.action)),
        containsAllInOrder([
          (EntityType.project, ActivityAction.created),
          (EntityType.task, ActivityAction.created),
          (EntityType.task, ActivityAction.completed),
        ]),
      );
    });

    test(
      'flagging the next task is its own event, not a generic update',
      () async {
        final project = await projects.create(name: 'Infra personal');
        final task = await tasks.create(projectId: project, title: 'Backups');

        await tasks.setNext(task);

        final entry = (await db.select(db.activityEvents).get())
            .map(AppDatabase.activityEntryOf)
            .firstWhere((e) => e.action == ActivityAction.flaggedNext);
        expect(entry.label, 'TASK FLAGGED NEXT');
        expect(entry.title, 'Backups');
      },
    );

    test('a no-op toggle writes nothing', () async {
      final project = await projects.create(name: 'Infra personal');
      final task = await tasks.create(projectId: project, title: 'Backups');
      final before = (await db.select(db.activityEvents).get()).length;

      await tasks.setDone(task, false);

      expect(await db.select(db.activityEvents).get(), hasLength(before));
    });

    test('the event carries the project it happened in', () async {
      final project = await projects.create(name: 'Infra personal');
      final task = await tasks.create(projectId: project, title: 'Storage');

      await tasks.block(task, 'Esperando proveedor S3');

      final entry = (await db.select(db.activityEvents).get())
          .map(AppDatabase.activityEntryOf)
          .firstWhere((e) => e.action == ActivityAction.blocked);
      expect(entry.title, 'Storage');
      expect(entry.context, 'Infra personal');
      expect(entry.detail, 'Esperando proveedor S3');
    });
  });

  test('deleting a task takes its notes with it', () async {
    final project = await projects.create(name: 'Infra personal');
    final task = await tasks.create(projectId: project, title: 'Storage');
    await notes.create(
      content: 'Probar Garage y MinIO',
      projectId: project,
      taskId: task,
    );

    await tasks.delete(task);

    expect(await db.select(db.tasks).get(), isEmpty);
    expect(await db.select(db.notes).get(), isEmpty);
  });
}
