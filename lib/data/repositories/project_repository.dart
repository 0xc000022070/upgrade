import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../database.dart';
import '../enums.dart';
import '../views.dart';
import 'activity_repository.dart';
import 'mutation.dart';

class ProjectRepository {
  ProjectRepository(this._db, this._activity);

  final AppDatabase _db;
  final ActivityRepository _activity;
  static const _uuid = Uuid();

  /// The "leave it alone" value of [edit]'s three-valued `parentId`.
  static const _keepParent = Object();

  /// A project is its own context, so its events carry none.
  late final _mutations = Mutations<Project>(
    db: _db,
    activity: _activity,
    entityType: EntityType.project,
    read: _byId,
    title: (project) => project.name,
  );

  /// The flat list the MOVE picker and the `[ PARENT ]` picker are
  /// drawn from. Ordered by creation, not priority: priority is stored as its
  /// name, so a column sort would order it alphabetically, and ranking belongs
  /// in a projection query.
  Stream<List<Project>> watchAll() => _db.watchVisibleProjects();

  /// Roots only. A child is reached through its parent.
  Stream<List<ProjectSummary>> watchSummaries() => _db.watchRootSummaries();

  /// The Projects tab's folded `ARCHIVED N` panel, and the only
  /// list in the app that shows an archived project.
  Stream<List<ProjectSummary>> watchArchivedSummaries() =>
      _db.watchArchivedSummaries();

  /// The `PROJECTS N` panel on a project's detail.
  Stream<List<ProjectSummary>> watchChildren(String parentId) =>
      _db.watchChildSummaries(parentId);

  /// One project's own row, carrying its subtree progress.
  Stream<ProjectSummary?> watchSummary(String id) =>
      _db.watchProjectSummary(id);

  /// The ancestors of [id], root first, self excluded.
  Stream<List<ProjectCrumb>> watchAncestors(String id) =>
      _db.watchAncestors(id);

  Stream<Project?> watchById(String id) => (_db.select(
    _db.projects,
  )..where((p) => p.id.equals(id))).watchSingleOrNull();

  /// How many projects sit under [id]. The number the cascade
  /// delete asks about — `DELETE PROJECT AND N BELOW?`.
  Future<int> descendantCount(String id) async =>
      (await _db.subtreeIds(id)).length - 1;

  /// The cycle guard, the backstop under the form's picker: a
  /// project can be neither its own parent nor a child of anything under it.
  /// The pickers never offer those rows, so reaching this is a bug or a
  /// hand-edited database, and either way the write must not land — a cycle has
  /// no root, and every hierarchy query walks down from the roots.
  Future<void> _guardParent(String id, String parentId) async {
    if (parentId == id || (await _db.subtreeIds(id)).contains(parentId)) {
      throw StateError('a project cannot be moved under itself');
    }
  }

  Future<String> create({
    required String name,
    String description = '',
    String objective = '',
    ProjectStatus status = ProjectStatus.active,
    Priority priority = Priority.normal,
    String? parentId,
    DateTime? at,
  }) {
    final now = at ?? DateTime.now().toUtc();
    final id = _uuid.v7();
    return _db.transaction(() async {
      await _db
          .into(_db.projects)
          .insert(
            ProjectsCompanion.insert(
              id: id,
              parentId: Value(parentId),
              name: name,
              description: description,
              objective: objective,
              status: status,
              priority: priority,
              createdAt: now,
              updatedAt: now,
            ),
          );
      await _activity.log(
        entityType: EntityType.project,
        entityId: id,
        action: ActivityAction.created,
        title: name,
        at: now,
      );
      return id;
    });
  }

  /// [parentId] is three-valued, which is why it is not a `String?`: absent
  /// leaves the parent alone, `null` makes the project a root, and an id moves
  /// it. Changing the parent *is* the move — descendants keep
  /// their own `parent_id`, so the subtree follows without a write.
  Future<void> edit(
    String id, {
    String? name,
    String? description,
    String? objective,
    ProjectStatus? status,
    Priority? priority,
    Object? parentId = _keepParent,
  }) => _mutations.on(id).titled(name).writes(ActivityAction.updated, (
    project,
    now,
  ) async {
    final moving = !identical(parentId, _keepParent);
    if (moving && parentId != null) {
      await _guardParent(id, parentId as String);
    }
    await _write(
      id,
      ProjectsCompanion(
        parentId: moving ? Value(parentId as String?) : const Value.absent(),
        name: name == null ? const Value.absent() : Value(name),
        description: description == null
            ? const Value.absent()
            : Value(description),
        objective: objective == null ? const Value.absent() : Value(objective),
        status: status == null ? const Value.absent() : Value(status),
        priority: priority == null ? const Value.absent() : Value(priority),
        updatedAt: Value(now),
      ),
    );
    return null;
  });

  Future<void> setStatus(String id, ProjectStatus status) => _mutations
      .on(id)
      .unchangedWhen((project) => project.status == status)
      .writes(ActivityAction.updated, (project, now) async {
        await _write(
          id,
          ProjectsCompanion(status: Value(status), updatedAt: Value(now)),
        );
        return '${project.status.name} → ${status.name}';
      });

  /// Archive and unarchive are one tap, not a trip through the
  /// status field, but they write the same column the form's STATUS block does.
  Future<void> archive(String id) => setStatus(id, ProjectStatus.archived);

  Future<void> unarchive(String id) => setStatus(id, ProjectStatus.active);

  /// Deleting a project un-files its items — they become Home
  /// drops — and never deletes them. Its goals go with it, since a goal only
  /// exists inside a project. Notes attached to a surviving item follow the
  /// item; a note that only ever belonged to the project has no screen left to
  /// appear on, so it goes.
  ///
  /// And the same happens to every project below it, in the one
  /// transaction. Leaving the children behind would orphan them — a project
  /// whose parent is gone is reachable from no list, since every list is either
  /// roots-only or a parent's own panel.
  Future<void> delete(
    String id, {
    DateTime? at,
  }) => _mutations.on(id).at(at).writes(ActivityAction.deleted, (
    project,
    now,
  ) async {
    final ids = await _db.subtreeIds(id);
    await (_db.update(_db.tasks)..where((t) => t.projectId.isIn(ids))).write(
      TasksCompanion(
        projectId: const Value(null),
        goalId: const Value(null),
        updatedAt: Value(now),
      ),
    );
    await (_db.delete(
      _db.notes,
    )..where((n) => n.projectId.isIn(ids) & n.taskId.isNull())).go();
    await (_db.update(_db.notes)..where((n) => n.projectId.isIn(ids))).write(
      NotesCompanion(projectId: const Value(null), updatedAt: Value(now)),
    );
    await (_db.delete(_db.goals)..where((g) => g.projectId.isIn(ids))).go();
    // A registered directory outlives the project it was filed under. The
    // code on the machine did not stop existing because the plan around it
    // did, so the link is cleared and the row stays. Done here because this
    // database never enables `PRAGMA foreign_keys`: nothing else would.
    await (_db.update(_db.paths)..where((p) => p.projectId.isIn(ids))).write(
      const PathsCompanion(projectId: Value(null)),
    );
    await (_db.delete(_db.projects)..where((p) => p.id.isIn(ids))).go();
    return ids.length > 1 ? 'and ${ids.length - 1} below' : null;
  });

  Future<int> _write(String id, ProjectsCompanion values) =>
      (_db.update(_db.projects)..where((p) => p.id.equals(id))).write(values);

  Future<Project> _byId(String id) =>
      (_db.select(_db.projects)..where((p) => p.id.equals(id))).getSingle();
}
