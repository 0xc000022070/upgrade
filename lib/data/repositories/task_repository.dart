import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../bundles.dart';
import '../database.dart';
import '../enums.dart';
import '../views.dart';
import 'activity_repository.dart';
import 'attachment_repository.dart';

class TaskRepository {
  TaskRepository(AppDatabase db, this._activity)
    : _db = db,
      _attachments = AttachmentRepository(db);

  final AppDatabase _db;
  final ActivityRepository _activity;

  /// Owned rather than injected so a capture can write its item and its links
  /// inside one transaction (SPEC.md §39.6) without the call site holding both.
  final AttachmentRepository _attachments;
  static const _uuid = Uuid();

  Stream<NextAction?> watchNextAction() => _db.watchNextAction();

  Stream<List<BlockedTask>> watchBlocked() => _db.watchBlockedTasks();

  Stream<List<Task>> watchByProject(String projectId) {
    return (_db.select(_db.tasks)
          ..where((t) => t.projectId.equals(projectId))
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
        .watch()
        .map(withBundlesAdjacent);
  }

  /// SPEC.md §39.1: the project's own DROPS panel — filed to the project but
  /// under no goal.
  Stream<List<Task>> watchProjectDrops(String projectId) {
    return (_db.select(_db.tasks)
          ..where((t) => t.projectId.equals(projectId) & t.goalId.isNull())
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
        .watch()
        .map(withBundlesAdjacent);
  }

  Stream<List<Task>> watchByGoal(String goalId) {
    return (_db.select(_db.tasks)
          ..where((t) => t.goalId.equals(goalId))
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
        .watch()
        .map(withBundlesAdjacent);
  }

  /// SPEC.md §39.3 DROPS: unfiled items, newest first.
  /// §39.11: a drop has no done, so the panel does not filter on it. A done
  /// task that is later unfiled — by MOVE or by §39.2's project delete — keeps
  /// the column set, and filtering here would leave that row on no surface at
  /// all.
  Stream<List<Task>> watchDrops() {
    return (_db.select(_db.tasks)
          ..where((t) => t.projectId.isNull())
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
        .watch()
        .map(withBundlesAdjacent);
  }

  Stream<Task?> watchById(String id) => (_db.select(
    _db.tasks,
  )..where((t) => t.id.equals(id))).watchSingleOrNull();

  /// The `[ WITH ]` list of SPEC.md §39.4. An unbundled item has no mates, and
  /// a bundle that lost its last partner reports none either.
  Stream<List<Task>> watchMates(String id) {
    return (_db.select(
      _db.tasks,
    )..where((t) => t.id.equals(id))).watchSingleOrNull().asyncExpand((task) {
      final bundleId = task?.bundleId;
      if (bundleId == null) return Stream.value(const <Task>[]);
      return (_db.select(_db.tasks)
            ..where((t) => t.bundleId.equals(bundleId) & t.id.equals(id).not())
            ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
          .watch();
    });
  }

  /// SPEC.md §39.5 PAIR picker: open drops and ideas, newest first, excluding
  /// the item itself and whatever it already travels with.
  Stream<List<Task>> watchPairCandidates(String id) {
    return (_db.select(
      _db.tasks,
    )..where((t) => t.id.equals(id))).watchSingleOrNull().asyncExpand((task) {
      final bundleId = task?.bundleId;
      return (_db.select(_db.tasks)
            ..where((t) {
              var filter = t.id.equals(id).not() & t.done.equals(false);
              if (bundleId != null) {
                // `bundle_id <> 'x'` is NULL for an unbundled row, which
                // SQLite treats as false; the null arm is what keeps plain
                // items in the picker.
                filter =
                    filter &
                    (t.bundleId.isNull() | t.bundleId.equals(bundleId).not());
              }
              return filter;
            })
            ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
          .watch();
    });
  }

  Future<String> create({
    required String title,
    String? projectId,
    String? goalId,
    bool isNext = false,
    int? effort,
    List<NewAttachment> attachments = const [],
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
              goalId: Value(goalId),
              title: title,
              isNext: Value(isNext),
              effort: Value(effort),
              createdAt: now,
              updatedAt: now,
            ),
          );
      for (final attachment in attachments) {
        await _attachments.create(
          itemId: id,
          kind: attachment.kind,
          value: attachment.value,
          at: now,
        );
      }
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

  /// The capture bar's one write (SPEC.md §39.6): the item, its links and the
  /// event land in a single transaction, at whatever target the bar was
  /// pointing at. The distinct event is what makes a capture read as a dump
  /// rather than as planning.
  Future<String> capture(
    String title, {
    ItemTarget target = const ItemTarget.drops(),
    List<NewAttachment> attachments = const [],
    DateTime? at,
  }) => create(
    title: title,
    projectId: target.projectId,
    goalId: target.goalId,
    attachments: attachments,
    action: ActivityAction.captured,
    at: at,
  );

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

  /// SPEC.md §39.4 `UNSET`: the flag comes off without anything else taking
  /// it, so HOME's NEXT ACTION panel goes away rather than moving on.
  Future<void> unsetNext(String id, {DateTime? at}) {
    final now = at ?? DateTime.now().toUtc();
    return _db.transaction(() async {
      final task = await _byId(id);
      if (!task.isNext) return;
      await (_db.update(_db.tasks)..where((t) => t.id.equals(id))).write(
        TasksCompanion(isNext: const Value(false), updatedAt: Value(now)),
      );
      await _activity.log(
        entityType: EntityType.task,
        entityId: id,
        action: ActivityAction.updated,
        title: task.title,
        context: await _projectName(task.projectId),
        detail: 'unflagged',
        at: now,
      );
    });
  }

  /// SPEC.md §39.5: a bundle moves whole. The member lookup happens inside the
  /// transaction, so a concurrent pair cannot leave half a bundle behind.
  Future<void> moveToTarget(String id, ItemTarget target, {DateTime? at}) {
    final now = at ?? DateTime.now().toUtc();
    return _db.transaction(() async {
      final task = await _byId(id);
      if (task.projectId == target.projectId && task.goalId == target.goalId) {
        return;
      }
      final ids = await _bundleMemberIds(task);
      await (_db.update(_db.tasks)..where((t) => t.id.isIn(ids))).write(
        TasksCompanion(
          projectId: Value(target.projectId),
          goalId: Value(target.goalId),
          updatedAt: Value(now),
        ),
      );
      await _activity.log(
        entityType: EntityType.task,
        entityId: id,
        action: ActivityAction.moved,
        title: task.title,
        context: await _projectName(target.projectId),
        detail: ids.length > 1 ? 'bundle of ${ids.length}' : null,
        at: now,
      );
    });
  }

  /// SPEC.md §39.5: pairing is a union. Whichever bundle already exists wins,
  /// so joining an item to a pair makes a trio rather than splitting it.
  Future<void> pair(String id, String otherId, {DateTime? at}) {
    final now = at ?? DateTime.now().toUtc();
    return _db.transaction(() async {
      final task = await _byId(id);
      final other = await _byId(otherId);
      final bundleId = task.bundleId ?? other.bundleId ?? _uuid.v7();
      final ids = {
        ...await _bundleMemberIds(task),
        ...await _bundleMemberIds(other),
      };
      await (_db.update(_db.tasks)..where((t) => t.id.isIn(ids))).write(
        TasksCompanion(bundleId: Value(bundleId), updatedAt: Value(now)),
      );
      await _activity.log(
        entityType: EntityType.task,
        entityId: id,
        action: ActivityAction.updated,
        title: task.title,
        context: await _projectName(task.projectId),
        detail: 'paired with ${other.title}',
        at: now,
      );
    });
  }

  /// SPEC.md §39.5: unpairing clears the id on this item only; the rest of the
  /// bundle stays together.
  Future<void> unpair(String id, {DateTime? at}) {
    final now = at ?? DateTime.now().toUtc();
    return _db.transaction(() async {
      final task = await _byId(id);
      if (task.bundleId == null) return;
      await (_db.update(_db.tasks)..where((t) => t.id.equals(id))).write(
        TasksCompanion(bundleId: const Value(null), updatedAt: Value(now)),
      );
      await _activity.log(
        entityType: EntityType.task,
        entityId: id,
        action: ActivityAction.updated,
        title: task.title,
        context: await _projectName(task.projectId),
        detail: 'unpaired',
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

  /// Deleting drops the task's notes and links with it: neither has a screen
  /// that can reach it once the item is gone, and the foreign keys would refuse
  /// the delete. A bundled item is deleted alone — a bundle moves whole, it
  /// does not die whole.
  Future<void> delete(String id, {DateTime? at}) {
    final now = at ?? DateTime.now().toUtc();
    return _db.transaction(() async {
      final task = await _byId(id);
      await (_db.delete(
        _db.attachments,
      )..where((a) => a.itemId.equals(id))).go();
      // The pre-§39.10 rows migrated into `attachments` but were left behind in
      // `links`; a deleted item takes both copies with it.
      await (_db.delete(_db.links)..where((l) => l.taskId.equals(id))).go();
      await (_db.delete(_db.notes)..where((n) => n.taskId.equals(id))).go();
      await (_db.delete(_db.tasks)..where((t) => t.id.equals(id))).go();
      await _activity.log(
        entityType: EntityType.task,
        entityId: id,
        action: ActivityAction.deleted,
        title: task.title,
        context: await _projectName(task.projectId),
        at: now,
      );
    });
  }

  Future<Set<String>> _bundleMemberIds(Task task) async {
    final bundleId = task.bundleId;
    if (bundleId == null) return {task.id};
    final rows = await (_db.select(
      _db.tasks,
    )..where((t) => t.bundleId.equals(bundleId))).get();
    return {task.id, ...rows.map((row) => row.id)};
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
