import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../database.dart';
import '../enums.dart';
import '../views.dart';
import 'activity_repository.dart';

class TaskRepository {
  TaskRepository(this._db, this._activity);

  final AppDatabase _db;
  final ActivityRepository _activity;
  static const _uuid = Uuid();

  Stream<NextAction?> watchNextAction() => _db.watchNextAction();

  Stream<List<BlockedTask>> watchBlocked() => _db.watchBlockedTasks();

  Stream<List<Task>> watchByProject(String projectId) {
    return (_db.select(_db.tasks)
          ..where((t) => t.projectId.equals(projectId))
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
        .watch();
  }

  /// SPEC.md §37: a loose task is the whole of what the inbox used to be.
  Stream<List<Task>> watchLoose() {
    return (_db.select(_db.tasks)
          ..where((t) => t.projectId.isNull() & t.done.equals(false))
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
        .watch();
  }

  Future<String> create({
    required String title,
    String? projectId,
    bool isNext = false,
    int? effort,
    ActivityAction action = ActivityAction.created,
    DateTime? at,
  }) {
    final now = at ?? DateTime.now().toUtc();
    final id = _uuid.v7();
    return _db.transaction(() async {
      if (isNext) await _clearNext(now);
      await _db
          .into(_db.tasks)
          .insert(
            TasksCompanion.insert(
              id: id,
              projectId: Value(projectId),
              title: title,
              isNext: Value(isNext),
              effort: Value(effort),
              createdAt: now,
              updatedAt: now,
            ),
          );
      await _activity.log(
        entityType: EntityType.task,
        entityId: id,
        action: action,
        title: title,
        context: await _projectName(projectId),
        at: now,
      );
      return id;
    });
  }

  /// The capture bar's one write. It differs from [create] only in the event it
  /// leaves behind, which is what makes RECENT read as a dump rather than as
  /// planning.
  Future<String> capture(String title, {DateTime? at}) =>
      create(title: title, action: ActivityAction.captured, at: at);

  Future<void> setDone(String id, bool done, {DateTime? at}) {
    final now = at ?? DateTime.now().toUtc();
    return _db.transaction(() async {
      final task = await _byId(id);
      if (task.done == done) return;
      await (_db.update(_db.tasks)..where((t) => t.id.equals(id))).write(
        TasksCompanion(
          done: Value(done),
          // Finishing the flagged task retires the flag: leaving it set would
          // point NEXT ACTION at something already crossed off.
          isNext: done ? const Value(false) : const Value.absent(),
          updatedAt: Value(now),
        ),
      );
      await _activity.log(
        entityType: EntityType.task,
        entityId: id,
        action: done ? ActivityAction.completed : ActivityAction.reopened,
        title: task.title,
        context: await _projectName(task.projectId),
        at: now,
      );
    });
  }

  Future<void> block(String id, String reason, {DateTime? at}) {
    final now = at ?? DateTime.now().toUtc();
    return _db.transaction(() async {
      final task = await _byId(id);
      await (_db.update(_db.tasks)..where((t) => t.id.equals(id))).write(
        TasksCompanion(blockedReason: Value(reason), updatedAt: Value(now)),
      );
      await _activity.log(
        entityType: EntityType.task,
        entityId: id,
        action: ActivityAction.blocked,
        title: task.title,
        context: await _projectName(task.projectId),
        detail: reason,
        at: now,
      );
    });
  }

  Future<void> unblock(String id, {DateTime? at}) {
    final now = at ?? DateTime.now().toUtc();
    return _db.transaction(() async {
      final task = await _byId(id);
      if (task.blockedReason == null) return;
      await (_db.update(_db.tasks)..where((t) => t.id.equals(id))).write(
        TasksCompanion(blockedReason: const Value(null), updatedAt: Value(now)),
      );
      await _activity.log(
        entityType: EntityType.task,
        entityId: id,
        action: ActivityAction.unblocked,
        title: task.title,
        context: await _projectName(task.projectId),
        at: now,
      );
    });
  }

  /// SPEC.md §37: at most one task in the database carries the flag. Clearing
  /// the others in the same transaction is what makes that an invariant rather
  /// than a convention every call site has to remember.
  Future<void> setNext(String id, {DateTime? at}) {
    final now = at ?? DateTime.now().toUtc();
    return _db.transaction(() async {
      final task = await _byId(id);
      await _clearNext(now);
      await (_db.update(_db.tasks)..where((t) => t.id.equals(id))).write(
        TasksCompanion(isNext: const Value(true), updatedAt: Value(now)),
      );
      await _activity.log(
        entityType: EntityType.task,
        entityId: id,
        action: ActivityAction.flaggedNext,
        title: task.title,
        context: await _projectName(task.projectId),
        at: now,
      );
    });
  }

  Future<void> moveToProject(String id, String? projectId, {DateTime? at}) {
    final now = at ?? DateTime.now().toUtc();
    return _db.transaction(() async {
      final task = await _byId(id);
      if (task.projectId == projectId) return;
      await (_db.update(_db.tasks)..where((t) => t.id.equals(id))).write(
        TasksCompanion(projectId: Value(projectId), updatedAt: Value(now)),
      );
      await _activity.log(
        entityType: EntityType.task,
        entityId: id,
        action: ActivityAction.updated,
        title: task.title,
        context: await _projectName(projectId),
        detail: 'moved',
        at: now,
      );
    });
  }

  Future<void> edit(String id, {String? title, int? effort, DateTime? at}) {
    final now = at ?? DateTime.now().toUtc();
    return _db.transaction(() async {
      final task = await _byId(id);
      await (_db.update(_db.tasks)..where((t) => t.id.equals(id))).write(
        TasksCompanion(
          title: title == null ? const Value.absent() : Value(title),
          effort: effort == null ? const Value.absent() : Value(effort),
          updatedAt: Value(now),
        ),
      );
      await _activity.log(
        entityType: EntityType.task,
        entityId: id,
        action: ActivityAction.updated,
        title: title ?? task.title,
        context: await _projectName(task.projectId),
        at: now,
      );
    });
  }

  /// Deleting drops the task's notes with it: a note whose task is gone has no
  /// screen that can reach it, and the foreign key would refuse the delete.
  Future<void> delete(String id) {
    return _db.transaction(() async {
      await (_db.delete(_db.notes)..where((n) => n.taskId.equals(id))).go();
      await (_db.delete(_db.tasks)..where((t) => t.id.equals(id))).go();
    });
  }

  Future<void> _clearNext(DateTime now) =>
      (_db.update(_db.tasks)..where((t) => t.isNext.equals(true))).write(
        TasksCompanion(isNext: const Value(false), updatedAt: Value(now)),
      );

  Future<Task> _byId(String id) =>
      (_db.select(_db.tasks)..where((t) => t.id.equals(id))).getSingle();

  Future<String?> _projectName(String? projectId) async {
    if (projectId == null) return null;
    final project = await (_db.select(
      _db.projects,
    )..where((p) => p.id.equals(projectId))).getSingle();
    return project.name;
  }
}
