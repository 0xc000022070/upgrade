import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../database.dart';
import '../enums.dart';
import '../views.dart';
import 'activity_repository.dart';

class ProjectRepository {
  ProjectRepository(this._db, this._activity);

  final AppDatabase _db;
  final ActivityRepository _activity;
  static const _uuid = Uuid();

  Stream<List<Project>> watchAll() {
    return (_db.select(_db.projects)
          ..where((p) => p.status.equalsValue(ProjectStatus.archived).not())
          // Priority is stored as its name, so a column sort would order it
          // alphabetically; ranking by priority belongs in a projection query.
          ..orderBy([(p) => OrderingTerm.asc(p.createdAt)]))
        .watch();
  }

  Stream<List<ProjectSummary>> watchSummaries() => _db.watchProjectSummaries();

  /// SPEC.md §39.14: the Projects tab's folded `ARCHIVED N` panel, and the only
  /// list in the app that shows an archived project.
  Stream<List<ProjectSummary>> watchArchivedSummaries() =>
      _db.watchProjectSummaries(archived: true);

  Stream<Project?> watchById(String id) => (_db.select(
    _db.projects,
  )..where((p) => p.id.equals(id))).watchSingleOrNull();

  Future<String> create({
    required String name,
    String description = '',
    String objective = '',
    ProjectStatus status = ProjectStatus.active,
    Priority priority = Priority.normal,
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

  Future<void> edit(
    String id, {
    String? name,
    String? description,
    String? objective,
    ProjectStatus? status,
    Priority? priority,
  }) {
    final now = DateTime.now().toUtc();
    return _db.transaction(() async {
      final project = await _byId(id);
      await (_db.update(_db.projects)..where((p) => p.id.equals(id))).write(
        ProjectsCompanion(
          name: name == null ? const Value.absent() : Value(name),
          description: description == null
              ? const Value.absent()
              : Value(description),
          objective: objective == null
              ? const Value.absent()
              : Value(objective),
          status: status == null ? const Value.absent() : Value(status),
          priority: priority == null ? const Value.absent() : Value(priority),
          updatedAt: Value(now),
        ),
      );
      await _activity.log(
        entityType: EntityType.project,
        entityId: id,
        action: ActivityAction.updated,
        title: name ?? project.name,
        at: now,
      );
    });
  }

  Future<void> setStatus(String id, ProjectStatus status) {
    final now = DateTime.now().toUtc();
    return _db.transaction(() async {
      final project = await _byId(id);
      if (project.status == status) return;
      await (_db.update(_db.projects)..where((p) => p.id.equals(id))).write(
        ProjectsCompanion(status: Value(status), updatedAt: Value(now)),
      );
      await _activity.log(
        entityType: EntityType.project,
        entityId: id,
        action: ActivityAction.updated,
        title: project.name,
        detail: '${project.status.name} → ${status.name}',
        at: now,
      );
    });
  }

  /// SPEC.md §39.14: archive and unarchive are one tap, not a trip through the
  /// status field, but they write the same column the form's STATUS block does.
  Future<void> archive(String id) => setStatus(id, ProjectStatus.archived);

  Future<void> unarchive(String id) => setStatus(id, ProjectStatus.active);

  /// SPEC.md §39.2: deleting a project un-files its items — they become Home
  /// drops — and never deletes them. Its goals go with it, since a goal only
  /// exists inside a project. Notes attached to a surviving item follow the
  /// item; a note that only ever belonged to the project has no screen left to
  /// appear on, so it goes.
  Future<void> delete(String id, {DateTime? at}) {
    final now = at ?? DateTime.now().toUtc();
    return _db.transaction(() async {
      final project = await _byId(id);
      await (_db.update(_db.tasks)..where((t) => t.projectId.equals(id))).write(
        TasksCompanion(
          projectId: const Value(null),
          goalId: const Value(null),
          updatedAt: Value(now),
        ),
      );
      await (_db.delete(
        _db.notes,
      )..where((n) => n.projectId.equals(id) & n.taskId.isNull())).go();
      await (_db.update(_db.notes)..where((n) => n.projectId.equals(id))).write(
        NotesCompanion(projectId: const Value(null), updatedAt: Value(now)),
      );
      await (_db.delete(_db.goals)..where((g) => g.projectId.equals(id))).go();
      await (_db.delete(_db.projects)..where((p) => p.id.equals(id))).go();
      await _activity.log(
        entityType: EntityType.project,
        entityId: id,
        action: ActivityAction.deleted,
        title: project.name,
        at: now,
      );
    });
  }

  Future<Project> _byId(String id) =>
      (_db.select(_db.projects)..where((p) => p.id.equals(id))).getSingle();
}
