import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotline/application/project_tree.dart';
import 'package:hotline/data/database.dart';
import 'package:hotline/data/enums.dart';
import 'package:hotline/data/repositories/activity_repository.dart';
import 'package:hotline/data/repositories/note_repository.dart';
import 'package:hotline/data/repositories/project_repository.dart';
import 'package:hotline/data/repositories/task_repository.dart';

/// A subproject is a project with a parent, so nothing here
/// tests a new entity: it tests that the same rows read differently once one of
/// them points at another.
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

  /// root > child > grandchild, the shape the whole section is about.
  Future<List<String>> tree() async {
    final root = await projects.create(name: 'Infra');
    final child = await projects.create(name: 'Homelab', parentId: root);
    final grandchild = await projects.create(
      name: 'Networking',
      parentId: child,
    );
    return [root, child, grandchild];
  }

  group('roots and children', () {
    test(
      'only roots are listed; a child is reached through its parent',
      () async {
        final ids = await tree();

        expect(
          (await projects.watchSummaries().first).map((p) => p.projectId),
          [ids[0]],
        );
        expect(
          (await projects.watchChildren(ids[0]).first).map((p) => p.name),
          ['Homelab'],
        );
        expect(
          (await projects.watchChildren(ids[1]).first).map((p) => p.name),
          ['Networking'],
        );
        expect(await projects.watchChildren(ids[2]).first, isEmpty);
      },
    );

    test(
      'ancestors come back root first, without the project itself',
      () async {
        final ids = await tree();

        expect(await projects.watchAncestors(ids[0]).first, isEmpty);
        expect(
          (await projects.watchAncestors(ids[2]).first).map((c) => c.name),
          ['Infra', 'Homelab'],
        );
      },
    );
  });

  group('subtree progress', () {
    test('a parent with no tasks of its own reports its descendants', () async {
      final ids = await tree();
      await tasks.create(projectId: ids[1], title: 'Rack');
      final done = await tasks.create(projectId: ids[2], title: 'VLANs');
      await tasks.setDone(done, true);

      final root = (await projects.watchSummaries().first).single;
      expect(root.totalCount, 2);
      expect(root.doneCount, 1);
      expect(root.percent, 50);

      // The child's own row aggregates its own subtree, not the whole tree.
      final child = (await projects.watchChildren(ids[0]).first).single;
      expect(child.totalCount, 2);
      final leaf = (await projects.watchSummary(ids[2]).first)!;
      expect(leaf.totalCount, 1);
      expect(leaf.doneCount, 1);
    });

    test('an empty subtree is 0%, not undefined', () async {
      final ids = await tree();

      final root = (await projects.watchSummary(ids[0]).first)!;
      expect(root.totalCount, 0);
      expect(root.ratio, 0);
      expect(root.percent, 0);
    });

    // Only the progress number aggregates: NEXT ACTION and
    // the lead line keep pointing at the task's own project.
    test('the lead task stays the project own, not a descendant one', () async {
      final ids = await tree();
      await tasks.create(projectId: ids[2], title: 'VLANs', isNext: true);

      expect(
        (await projects.watchSummary(ids[0]).first)!.nextActionTitle,
        isNull,
      );
      expect(
        (await projects.watchSummary(ids[2]).first)!.nextActionTitle,
        'VLANs',
      );
    });
  });

  group('moving', () {
    test('changing the parent moves the subtree with it', () async {
      final ids = await tree();
      final other = await projects.create(name: 'Dotfiles');

      // The mid-level project moves; its own child is not rewritten.
      await projects.edit(ids[1], parentId: other);

      expect((await projects.watchChildren(other).first).map((p) => p.name), [
        'Homelab',
      ]);
      expect(await projects.watchChildren(ids[0]).first, isEmpty);
      expect((await projects.watchChildren(ids[1]).first).map((p) => p.name), [
        'Networking',
      ]);
      expect((await projects.watchAncestors(ids[2]).first).map((c) => c.name), [
        'Dotfiles',
        'Homelab',
      ]);
    });

    test('a project can be promoted back to a root', () async {
      final ids = await tree();

      await projects.edit(ids[1], parentId: null);

      // Both roots now, most recently touched first: the move is a write.
      expect((await projects.watchSummaries().first).map((p) => p.name), [
        'Homelab',
        'Infra',
      ]);
    });

    test('an edit that does not mention the parent leaves it alone', () async {
      final ids = await tree();

      await projects.edit(ids[1], name: 'Homelab v2');

      expect((await projects.watchChildren(ids[0]).first).map((p) => p.name), [
        'Homelab v2',
      ]);
    });

    test('a project refuses to become its own descendant', () async {
      final ids = await tree();

      await expectLater(
        projects.edit(ids[0], parentId: ids[2]),
        throwsStateError,
      );
      await expectLater(
        projects.edit(ids[0], parentId: ids[0]),
        throwsStateError,
      );
      // The refused write left nothing behind.
      expect((await projects.watchSummaries().first).map((p) => p.projectId), [
        ids[0],
      ]);
    });
  });

  group('archive', () {
    test('archiving a root hides the whole subtree', () async {
      final ids = await tree();
      await tasks.create(projectId: ids[2], title: 'VLANs');

      await projects.archive(ids[0]);

      expect(await projects.watchSummaries().first, isEmpty);
      // The descendants keep their own status column.
      final rows = await db.select(db.projects).get();
      expect(
        rows.where((p) => p.status == ProjectStatus.archived).map((p) => p.id),
        [ids[0]],
      );
      // A hidden project's tasks leave Home the way an archived
      // project's tasks already do.
      expect(await db.watchNextAction().first, isNull);
      // The ARCHIVED panel lists the root only: the children's own status is
      // still active, and their parent is hidden.
      expect(
        (await projects.watchArchivedSummaries().first).map((p) => p.projectId),
        [ids[0]],
      );
      // Nothing reachable is left: watchAll feeds the pickers.
      expect(await projects.watchAll().first, isEmpty);
    });

    test('unarchiving the root restores the children as they were', () async {
      final ids = await tree();
      await projects.archive(ids[1]);
      await projects.archive(ids[0]);

      await projects.unarchive(ids[0]);

      expect((await projects.watchSummaries().first).map((p) => p.projectId), [
        ids[0],
      ]);
      // The child was archived in its own right before the parent was, and it
      // comes back archived rather than active.
      expect(await projects.watchChildren(ids[0]).first, isEmpty);
      expect(
        (await projects.watchArchivedSummaries().first).map((p) => p.projectId),
        [ids[1]],
      );
    });

    test('an archived child under a visible parent is its own record', () async {
      final ids = await tree();

      await projects.archive(ids[1]);

      // Not in the parent's PROJECTS panel, but in the tab's ARCHIVED panel:
      // its own status is archived and its parent is not hidden.
      expect(await projects.watchChildren(ids[0]).first, isEmpty);
      expect(
        (await projects.watchArchivedSummaries().first).map((p) => p.projectId),
        [ids[1]],
      );
      // The grandchild is hidden by the ancestor, and it is not a record of its
      // own — its own status never changed.
      expect(
        (await projects.watchArchivedSummaries().first).map((p) => p.projectId),
        isNot(contains(ids[2])),
      );
    });
  });

  group('cascade delete', () {
    test(
      'deleting a parent takes the subtree and un-files its items',
      () async {
        final ids = await tree();
        final task = await tasks.create(projectId: ids[2], title: 'VLANs');
        await notes.create(projectId: ids[1], content: 'el armario');

        expect(await projects.descendantCount(ids[0]), 2);
        await projects.delete(ids[0]);

        expect(await db.select(db.projects).get(), isEmpty);
        // The rule holds all the way down: items survive as drops.
        final rows = await db.select(db.tasks).get();
        expect(rows.single.id, task);
        expect(rows.single.projectId, isNull);
        expect(await db.select(db.notes).get(), isEmpty);
      },
    );

    test('a leaf reports no descendants, so the modal never appears', () async {
      final ids = await tree();

      expect(await projects.descendantCount(ids[2]), 0);
    });
  });

  group('picker helpers', () {
    test('parentPaths spells out the path to each row', () async {
      await tree();
      final rows = await db.select(db.projects).get();

      final paths = parentPaths(rows);
      final byName = {for (final p in rows) p.name: paths[p.id]};
      expect(byName['Infra'], '');
      expect(byName['Homelab'], 'INFRA');
      expect(byName['Networking'], 'INFRA / HOMELAB');
    });

    test('subtreeOf is the set the PARENT picker must not offer', () async {
      final ids = await tree();
      final rows = await db.select(db.projects).get();

      expect(subtreeOf(ids[0], rows), {ids[0], ids[1], ids[2]});
      expect(subtreeOf(ids[1], rows), {ids[1], ids[2]});
      expect(subtreeOf(ids[2], rows), {ids[2]});
    });
  });
}
