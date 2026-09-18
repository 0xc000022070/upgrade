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

  late final _mutations = Mutations<Project>(
    db: _db,
    activity: _activity,
    entityType: EntityType.project,
    read: _byId,
    title: (project) => project.name,
  );

  Stream<List<Project>> watchAll() => _db.watchVisibleProjects();

  Stream<List<ProjectSummary>> watchSummaries() => _db.watchRootSummaries();

  Stream<List<ProjectSummary>> watchArchivedSummaries() =>
      _db.watchArchivedSummaries();

  Stream<List<ProjectSummary>> watchChildren(String parentId) =>
      _db.watchChildSummaries(parentId);

  Stream<ProjectSummary?> watchSummary(String id) =>
      _db.watchProjectSummary(id);

  Stream<List<ProjectCrumb>> watchAncestors(String id) =>
      _db.watchAncestors(id);

  Stream<Project?> watchById(String id) => (_db.select(
    _db.projects,
  )..where((p) => p.id.equals(id))).watchSingleOrNull();

  Future<int> descendantCount(String id) async =>
      (await _db.subtreeIds(id)).length - 1;

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

  /// [parentId] is three-valued: absent leaves the parent alone, null makes the project a
  /// root, an id moves it. Descendants keep their own, so the subtree follows unwritten.
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

  Future<void> archive(String id) => setStatus(id, ProjectStatus.archived);

  Future<void> unarchive(String id) => setStatus(id, ProjectStatus.active);

  /// Un-files the items rather than deleting them, takes the goals, and repeats for every
  /// project below in the same transaction.
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
    // A registered directory outlives the project it was filed under. Cleared here because
    // this database never enables `PRAGMA foreign_keys`.
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
