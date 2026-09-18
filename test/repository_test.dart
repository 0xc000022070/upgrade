import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/data/database.dart';
import 'package:dazzle/data/enums.dart';
import 'package:dazzle/data/repositories/activity_repository.dart';
import 'package:dazzle/data/repositories/goal_repository.dart';
import 'package:dazzle/data/repositories/attachment_repository.dart';
import 'package:dazzle/data/repositories/note_repository.dart';
import 'package:dazzle/data/repositories/project_repository.dart';
import 'package:dazzle/data/repositories/task_repository.dart';
import 'package:dazzle/data/views.dart';

void main() {
  late AppDatabase db;
  late ProjectRepository projects;
  late GoalRepository goals;
  late TaskRepository tasks;
  late AttachmentRepository attachments;
  late NoteRepository notes;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    final activity = ActivityRepository(db);
    projects = ProjectRepository(db, activity);
    goals = GoalRepository(db, activity);
    tasks = TaskRepository(db, activity);
    attachments = AttachmentRepository(db);
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

      final summary = (await db.watchRootSummaries().first).single;

      expect(summary.totalCount, 0);
      expect(summary.ratio, 0);
      expect(summary.percent, 0);
    });

    test('counts every task of the project, goal or not', () async {
      final project = await projects.create(name: 'Infra personal');
      final other = await projects.create(name: 'Dotfiles');
      final goal = await goals.create(projectId: project, title: 'Reduce SaaS');
      final ids = [
        for (final title in ['Postgres', 'Redis', 'Storage', 'Backups', 'Mon'])
          await tasks.create(projectId: project, title: title, goalId: goal),
      ];
      final loose = await tasks.create(
        projectId: project,
        title: 'Sin meta todavia',
      );
      await tasks.create(projectId: other, title: 'Migrar a flakes');
      await tasks.capture('revisar pgbouncer');

      await tasks.setDone(ids[0], true);
      await tasks.setDone(ids[1], true);
      await tasks.setDone(loose, true);
      await tasks.block(ids[2], 'Esperando proveedor S3');

      final summary = (await db.watchRootSummaries().first).firstWhere(
        (row) => row.projectId == project,
      );

      expect(summary.totalCount, 6, reason: 'the goal-less row is a task');
      expect(summary.doneCount, 3, reason: 'and its done counts');
      expect(summary.percent, 50);
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

    test('the flagged item is the only candidate', () async {
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
      expect(next.title, 'Flakes');
      expect(next.projectName, 'Dotfiles');
      expect(next.blockedReason, isNull);
    });

    test('blocking the flagged item keeps it as the next action', () async {
      final project = await projects.create(name: 'Infra personal');
      final task = await tasks.create(projectId: project, title: 'Postgres');
      await tasks.setNext(task);

      await tasks.block(task, 'Waiting for credentials');

      final next = (await db.watchNextAction().first)!;
      expect(next.taskId, task);
      expect(next.blockedReason, 'Waiting for credentials');
    });

    test('with nothing flagged there is no next action', () async {
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

      expect(await db.watchNextAction().first, isNull);
    });

    test('blocking preserves the next flag while done retires it', () async {
      final project = await projects.create(name: 'Infra personal');
      final blocked = await tasks.create(projectId: project, title: 'Storage');
      await tasks.setNext(blocked);
      await tasks.block(blocked, 'Esperando proveedor S3');

      expect((await db.watchNextAction().first)!.taskId, blocked);

      final finished = await tasks.create(projectId: project, title: 'Redis');
      await tasks.setNext(finished);
      await tasks.setDone(finished, true);

      expect(await db.watchNextAction().first, isNull);
    });

    test('archiving the project takes its flagged item out of next', () async {
      final project = await projects.create(name: 'Drone FPV');
      final task = await tasks.create(projectId: project, title: 'Antena');
      await tasks.setNext(task);
      expect((await db.watchNextAction().first)!.taskId, task);

      await projects.archive(project);
      expect(await db.watchNextAction().first, isNull);

      await projects.unarchive(project);
      expect((await db.watchNextAction().first)!.taskId, task);
    });
  });

  group('archiving', () {
    test('an archived project leaves the live list for its own', () async {
      final live = await projects.create(name: 'Infra personal');
      final shelved = await projects.create(name: 'Drone FPV');
      await projects.archive(shelved);

      final active = await projects.watchSummaries().first;
      expect(active.map((p) => p.projectId), [live]);

      final archived = await projects.watchArchivedSummaries().first;
      expect(archived.map((p) => p.projectId), [shelved]);
      expect(archived.single.status, ProjectStatus.archived);

      await projects.unarchive(shelved);
      expect(await projects.watchArchivedSummaries().first, isEmpty);
      expect((await projects.watchSummaries().first).length, 2);
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

  group('drops', () {
    test('capture files a drop and logs it as a capture', () async {
      await tasks.capture('revisar pgbouncer');

      final loose = (await tasks.watchDrops().first).single;
      expect(loose.title, 'revisar pgbouncer');
      expect(loose.projectId, isNull);

      final events = await db.select(db.activityEvents).get();
      expect(events.single.action, ActivityAction.captured);
      expect(events.single.entityType, EntityType.task);
    });

    test('moving a capture to a project takes it out of DROPS', () async {
      final project = await projects.create(name: 'Infra personal');
      final task = await tasks.capture('revisar pgbouncer');

      await tasks.moveToTarget(task, ItemTarget.project(project));

      expect(await tasks.watchDrops().first, isEmpty);
      expect(await tasks.watchByProject(project).first, hasLength(1));
      expect(await tasks.watchProjectDrops(project).first, hasLength(1));
    });

    test('a drop moved into a project is a task, goal or not', () async {
      final project = await projects.create(name: 'Infra personal');
      final task = await tasks.capture('revisar pgbouncer');
      await tasks.moveToTarget(task, ItemTarget.project(project));

      await tasks.setNext(task);
      expect((await db.watchNextAction().first)!.taskId, task);

      await tasks.block(task, 'Esperando la cuota');
      expect((await db.watchBlockedTasks().first).single.taskId, task);

      final summary = (await db.watchRootSummaries().first).single;
      expect(summary.totalCount, 1);
      expect(
        await tasks.watchProjectDrops(project).first,
        hasLength(1),
        reason: 'it still sits in the project DROPS panel',
      );
    });

    test('filing it under a goal only moves it between panels', () async {
      final project = await projects.create(name: 'Infra personal');
      final goal = await goals.create(projectId: project, title: 'Reduce SaaS');
      final task = await tasks.capture('revisar pgbouncer');

      await tasks.moveToTarget(task, ItemTarget.goal(project, goal));
      await tasks.setNext(task);

      expect((await db.watchNextAction().first)!.taskId, task);
      final summary = (await db.watchRootSummaries().first).single;
      expect(summary.totalCount, 1);
      expect(await tasks.watchProjectDrops(project).first, isEmpty);
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

  group('goals', () {
    test('progress counts only the items under the goal', () async {
      final project = await projects.create(name: 'Infra personal');
      final goal = await goals.create(projectId: project, title: 'Reduce SaaS');
      final other = await goals.create(projectId: project, title: 'Backups');
      final ids = [
        for (final title in ['Postgres', 'Redis', 'Storage'])
          await tasks.create(projectId: project, title: title, goalId: goal),
      ];
      await tasks.create(projectId: project, title: 'Snapshots', goalId: other);
      await tasks.create(projectId: project, title: 'Monitoring');
      await tasks.setDone(ids[0], true);

      final summaries = await goals.watchSummaries(project).first;
      final reduce = summaries.firstWhere((g) => g.goalId == goal);

      expect(reduce.totalCount, 3);
      expect(reduce.doneCount, 1);
      expect(reduce.percent, 33);
      expect(summaries.firstWhere((g) => g.goalId == other).totalCount, 1);
    });

    test('an empty goal is 0 of 0, not undefined', () async {
      final project = await projects.create(name: 'Infra personal');
      await goals.create(projectId: project, title: 'Reduce SaaS');

      final summary = (await goals.watchSummaries(project).first).single;

      expect(summary.totalCount, 0);
      expect(summary.ratio, 0);
      expect(summary.percent, 0);
    });

    test('goals keep the order they were created in', () async {
      final project = await projects.create(name: 'Infra personal');
      for (final title in ['Reduce SaaS', 'Backups', 'Monitoring']) {
        await goals.create(projectId: project, title: title);
      }

      expect((await goals.watchByProject(project).first).map((g) => g.title), [
        'Reduce SaaS',
        'Backups',
        'Monitoring',
      ]);
    });

    test(
      'deleting a goal drops its items into the project, not the bin',
      () async {
        final project = await projects.create(name: 'Infra personal');
        final goal = await goals.create(
          projectId: project,
          title: 'Reduce SaaS',
        );
        await tasks.create(projectId: project, title: 'Postgres', goalId: goal);

        await goals.delete(goal);

        final task = (await tasks.watchByProject(project).first).single;
        expect(task.title, 'Postgres');
        expect(task.projectId, project);
        expect(task.goalId, isNull);
        expect(await tasks.watchProjectDrops(project).first, hasLength(1));
        expect(await goals.watchByProject(project).first, isEmpty);
      },
    );
  });

  group('move', () {
    test(
      'a target files an item under a goal, a project, or nowhere',
      () async {
        final project = await projects.create(name: 'Infra personal');
        final goal = await goals.create(
          projectId: project,
          title: 'Reduce SaaS',
        );
        final task = await tasks.capture('revisar pgbouncer');

        await tasks.moveToTarget(task, ItemTarget.goal(project, goal));
        var row = (await tasks.watchByGoal(goal).first).single;
        expect(row.projectId, project);
        expect(row.goalId, goal);

        await tasks.moveToTarget(task, ItemTarget.project(project));
        expect(await tasks.watchByGoal(goal).first, isEmpty);
        expect(await tasks.watchProjectDrops(project).first, hasLength(1));

        await tasks.moveToTarget(task, const ItemTarget.drops());
        row = (await tasks.watchDrops().first).single;
        expect(row.projectId, isNull);
        expect(row.goalId, isNull);
      },
    );

    test('moving one item moves the whole bundle', () async {
      final project = await projects.create(name: 'Infra personal');
      final a = await tasks.capture('comprar cable');
      final b = await tasks.capture('comprar adaptador');
      final c = await tasks.capture('revisar pgbouncer');
      await tasks.pair(a, b);

      await tasks.moveToTarget(b, ItemTarget.project(project));

      final filed = await tasks.watchByProject(project).first;
      expect(filed.map((t) => t.id).toSet(), {a, b});
      expect((await tasks.watchDrops().first).single.id, c);
    });

    test('the move event names the project it landed in', () async {
      final project = await projects.create(name: 'Infra personal');
      final task = await tasks.capture('revisar pgbouncer');

      await tasks.moveToTarget(task, ItemTarget.project(project));

      final entry = (await db.select(db.activityEvents).get())
          .map(AppDatabase.activityEntryOf)
          .firstWhere((e) => e.action == ActivityAction.moved);
      expect(entry.title, 'revisar pgbouncer');
      expect(entry.context, 'Infra personal');
    });
  });

  group('bundles', () {
    test('pairing is a union, so a third item joins the pair', () async {
      final a = await tasks.capture('comprar cable');
      final b = await tasks.capture('comprar adaptador');
      final c = await tasks.capture('comprar hub');

      await tasks.pair(a, b);
      await tasks.pair(c, b);

      final rows = await db.select(db.tasks).get();
      expect(rows.map((t) => t.bundleId).toSet(), hasLength(1));
      expect(rows.every((t) => t.bundleId != null), isTrue);
    });

    test('joining two existing bundles merges them into one', () async {
      final a = await tasks.capture('a');
      final b = await tasks.capture('b');
      final c = await tasks.capture('c');
      final d = await tasks.capture('d');
      await tasks.pair(a, b);
      await tasks.pair(c, d);

      await tasks.pair(a, c);

      final rows = await db.select(db.tasks).get();
      expect(rows.map((t) => t.bundleId).toSet(), hasLength(1));
      expect(await tasks.watchMates(a).first, hasLength(3));
    });

    test('unpairing releases only the item asked for', () async {
      final a = await tasks.capture('a');
      final b = await tasks.capture('b');
      final c = await tasks.capture('c');
      await tasks.pair(a, b);
      await tasks.pair(c, b);

      await tasks.unpair(a);

      expect(await tasks.watchMates(a).first, isEmpty);
      expect((await tasks.watchMates(b).first).single.id, c);
    });

    test('a bundle renders adjacent even when the sort separates it', () async {
      final first = await tasks.capture('first');
      final middle = await tasks.capture('middle');
      final last = await tasks.capture('last');
      await tasks.pair(last, first);

      expect((await tasks.watchDrops().first).map((t) => t.title), [
        'last',
        'first',
        'middle',
      ]);
      expect((await tasks.watchMates(middle).first), isEmpty);
    });

    test(
      'the pair picker hides the item and everything it travels with',
      () async {
        final a = await tasks.capture('a');
        final b = await tasks.capture('b');
        final c = await tasks.capture('c');
        final settled = await tasks.capture('done already');
        await tasks.setDone(settled, true);
        await tasks.pair(a, b);

        expect((await tasks.watchPairCandidates(a).first).map((t) => t.id), [
          c,
        ]);
      },
    );
  });

  group('attachments', () {
    test('a capture writes its item and its attachments in one go', () async {
      final id = await tasks.capture(
        'leer esto',
        attachments: const [
          NewAttachment.url('https://www.example.com/a'),
          NewAttachment.image('attachments/019-abc.jpg'),
          NewAttachment.url('https://drift.simonbinder.eu'),
        ],
      );

      final rows = await attachments.watchForItem(id).first;
      expect(rows.map((a) => a.value), [
        'https://www.example.com/a',
        'attachments/019-abc.jpg',
        'https://drift.simonbinder.eu',
      ]);
      expect(rows.map((a) => a.kind), [
        AttachmentKind.url,
        AttachmentKind.image,
        AttachmentKind.url,
      ]);
      expect(
        rows.where((a) => a.kind == AttachmentKind.url).map(attachmentLabel),
        ['example.com', 'drift.simonbinder.eu'],
      );
    });

    test('deleting an item takes its attachments with it', () async {
      final id = await tasks.capture('leer esto');
      await attachments.create(
        itemId: id,
        kind: AttachmentKind.url,
        value: 'https://example.com/a',
      );

      await tasks.delete(id);

      expect(await db.select(db.attachments).get(), isEmpty);
    });
  });

  group('project delete', () {
    test('un-files its items instead of deleting them', () async {
      final project = await projects.create(name: 'Infra personal');
      final goal = await goals.create(projectId: project, title: 'Reduce SaaS');
      await tasks.create(projectId: project, title: 'Postgres', goalId: goal);
      await tasks.create(projectId: project, title: 'Monitoring');

      await projects.delete(project);

      final drops = await tasks.watchDrops().first;
      expect(drops.map((t) => t.title).toSet(), {'Postgres', 'Monitoring'});
      expect(
        drops.every((t) => t.projectId == null && t.goalId == null),
        isTrue,
      );
      expect(await db.select(db.goals).get(), isEmpty);
      expect(await db.select(db.projects).get(), isEmpty);
    });

    test('a note on a surviving item follows the item', () async {
      final project = await projects.create(name: 'Infra personal');
      final task = await tasks.create(projectId: project, title: 'Storage');
      await notes.create(
        content: 'Probar Garage y MinIO',
        projectId: project,
        taskId: task,
      );
      await notes.create(content: 'Sin dueño', projectId: project);

      await projects.delete(project);

      final rows = await db.select(db.notes).get();
      expect(rows.single.content, 'Probar Garage y MinIO');
      expect(rows.single.projectId, isNull);
      expect(rows.single.taskId, task);
    });
  });

  group('item location', () {
    test('reads DROPS, project, or project and goal', () async {
      final project = await projects.create(name: 'Infra personal');
      final goal = await goals.create(projectId: project, title: 'Reduce SaaS');
      final task = await tasks.capture('revisar pgbouncer');

      expect((await db.watchItemLocation(task).first).label, 'DROPS');

      await tasks.moveToTarget(task, ItemTarget.project(project));
      expect(
        (await db.watchItemLocation(task).first).label,
        'INFRA PERSONAL / DROPS',
      );

      await tasks.moveToTarget(task, ItemTarget.goal(project, goal));
      expect(
        (await db.watchItemLocation(task).first).label,
        'INFRA PERSONAL / REDUCE SAAS',
      );
    });
  });
}
