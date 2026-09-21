import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../bundles.dart';
import '../database.dart';
import '../enums.dart';
import '../views.dart';
import 'activity_repository.dart';
import 'attachment_repository.dart';
import 'mutation.dart';

class TaskRepository {
  TaskRepository(AppDatabase db, this._activity)
    : _db = db,
      _attachments = AttachmentRepository(db);

  final AppDatabase _db;
  final ActivityRepository _activity;

  final AttachmentRepository _attachments;
  static const _uuid = Uuid();

  late final _mutations = Mutations<Task>(
    db: _db,
    activity: _activity,
    entityType: EntityType.task,
    read: _byId,
    title: (task) => task.title,
    context: (task) => _projectName(task.projectId),
  );

  Stream<NextAction?> watchNextAction() => _db.watchNextAction();

  Stream<List<BlockedTask>> watchBlocked() => _db.watchBlockedTasks();

  Stream<List<Task>> watchByProject(String projectId) {
    return (_db.select(_db.tasks)
          ..where((t) => t.projectId.equals(projectId))
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
        .watch()
        .map(withBundlesAdjacent);
  }

  Stream<List<Task>> watchProjectDrops(String projectId) {
    return (_db.select(_db.tasks)
          ..where((t) => t.projectId.equals(projectId) & t.goalId.isNull())
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
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

  Stream<List<Task>> watchPairCandidates(String id) {
    return (_db.select(
      _db.tasks,
    )..where((t) => t.id.equals(id))).watchSingleOrNull().asyncExpand((task) {
      final bundleId = task?.bundleId;
      return (_db.select(_db.tasks)
            ..where((t) {
              var filter = t.id.equals(id).not() & t.done.equals(false);
              if (bundleId != null) {
                // `bundle_id <> 'x'` is NULL for an unbundled row, which SQLite treats as false; the
                // null arm is what keeps plain items in the picker.
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

  Future<void> setDone(String id, bool done, {DateTime? at}) => _mutations
      .on(id)
      .at(at)
      .unchangedWhen((task) => task.done == done)
      .writes(done ? ActivityAction.completed : ActivityAction.reopened, (
        task,
        now,
      ) async {
        await _write(
          id,
          TasksCompanion(
            done: Value(done),
            // Finishing the flagged task retires the flag, or NEXT ACTION would point at something
            // already crossed off.
            isNext: done ? const Value(false) : const Value.absent(),
            updatedAt: Value(now),
          ),
        );
        return null;
      });

  Future<void> block(String id, String reason, {DateTime? at}) => _mutations
      .on(id)
      .at(at)
      .writes(ActivityAction.blocked, (task, now) async {
        await _write(
          id,
          TasksCompanion(blockedReason: Value(reason), updatedAt: Value(now)),
        );
        return reason;
      });

  Future<void> unblock(String id, {DateTime? at}) => _mutations
      .on(id)
      .at(at)
      .unchangedWhen((task) => task.blockedReason == null)
      .writes(ActivityAction.unblocked, (task, now) async {
        await _write(
          id,
          TasksCompanion(
            blockedReason: const Value(null),
            updatedAt: Value(now),
          ),
        );
        return null;
      });

  /// At most one task carries the flag; clearing the others in the same transaction is
  /// what makes that an invariant rather than a convention.
  Future<void> setNext(String id, {DateTime? at}) => _mutations
      .on(id)
      .at(at)
      .writes(ActivityAction.flaggedNext, (task, now) async {
        await _clearNext(now);
        await _write(
          id,
          TasksCompanion(isNext: const Value(true), updatedAt: Value(now)),
        );
        return null;
      });

  Future<void> unsetNext(String id, {DateTime? at}) => _mutations
      .on(id)
      .at(at)
      .unchangedWhen((task) => !task.isNext)
      .writes(ActivityAction.updated, (task, now) async {
        await _write(
          id,
          TasksCompanion(isNext: const Value(false), updatedAt: Value(now)),
        );
        return 'unflagged';
      });

  Future<void> setPriority(String id, Priority priority, {DateTime? at}) =>
      _mutations
          .on(id)
          .at(at)
          .unchangedWhen((task) => task.priority == priority)
          .writes(ActivityAction.updated, (task, now) async {
            await _write(
              id,
              TasksCompanion(priority: Value(priority), updatedAt: Value(now)),
            );
            return priority.index > task.priority.index ? 'raised' : 'lowered';
          });

  Future<void> moveToTarget(String id, ItemTarget target, {DateTime? at}) =>
      _mutations
          .on(id)
          .at(at)
          .unchangedWhen(
            (task) =>
                task.projectId == target.projectId &&
                task.goalId == target.goalId,
          )
          .context(() => _projectName(target.projectId))
          .writes(ActivityAction.moved, (task, now) async {
            final ids = await _bundleMemberIds(task);
            await (_db.update(_db.tasks)..where((t) => t.id.isIn(ids))).write(
              TasksCompanion(
                projectId: Value(target.projectId),
                goalId: Value(target.goalId),
                updatedAt: Value(now),
              ),
            );
            return ids.length > 1 ? 'bundle of ${ids.length}' : null;
          });

  /// Pairing is a union: whichever bundle already exists wins, so joining an item to a
  /// pair makes a trio rather than splitting it.
  Future<void> pair(String id, String otherId, {DateTime? at}) => _mutations
      .on(id)
      .at(at)
      .writes(ActivityAction.updated, (task, now) async {
        final other = await _byId(otherId);
        final bundleId = task.bundleId ?? other.bundleId ?? _uuid.v7();
        final ids = {
          ...await _bundleMemberIds(task),
          ...await _bundleMemberIds(other),
        };
        await (_db.update(_db.tasks)..where((t) => t.id.isIn(ids))).write(
          TasksCompanion(bundleId: Value(bundleId), updatedAt: Value(now)),
        );
        return 'paired with ${other.title}';
      });

  Future<void> unpair(String id, {DateTime? at}) => _mutations
      .on(id)
      .at(at)
      .unchangedWhen((task) => task.bundleId == null)
      .writes(ActivityAction.updated, (task, now) async {
        await _write(
          id,
          TasksCompanion(bundleId: const Value(null), updatedAt: Value(now)),
        );
        return 'unpaired';
      });

  Future<void> edit(String id, {String? title, int? effort, DateTime? at}) =>
      _mutations.on(id).at(at).titled(title).writes(ActivityAction.updated, (
        task,
        now,
      ) async {
        await _write(
          id,
          TasksCompanion(
            title: title == null ? const Value.absent() : Value(title),
            effort: effort == null ? const Value.absent() : Value(effort),
            updatedAt: Value(now),
          ),
        );
        return null;
      });

  Future<void> setPrompt(String id, String? prompt, {DateTime? at}) {
    final value = prompt?.trim();
    final stored = value == null || value.isEmpty ? null : value;
    return _mutations
        .on(id)
        .at(at)
        .unchangedWhen((task) => task.prompt == stored)
        .writes(ActivityAction.updated, (task, now) async {
          await _write(
            id,
            TasksCompanion(prompt: Value(stored), updatedAt: Value(now)),
          );
          return null;
        });
  }

  Future<bool> applyDropTitle(Task expected, String title) =>
      _db.transaction(() async {
        final current = await (_db.select(
          _db.tasks,
        )..where((t) => t.id.equals(expected.id))).getSingleOrNull();
        if (current == null ||
            current.projectId != null ||
            current != expected ||
            title.trim().isEmpty) {
          return false;
        }
        await edit(expected.id, title: title);
        return true;
      });

  /// Notes and links go with the task. A bundled item is deleted alone.
  Future<void> delete(
    String id, {
    DateTime? at,
  }) => _mutations.on(id).at(at).writes(ActivityAction.deleted, (
    task,
    now,
  ) async {
    await (_db.delete(_db.attachments)..where((a) => a.itemId.equals(id))).go();
    // Older rows migrated into `attachments` but were left behind in `links`.
    await (_db.delete(_db.links)..where((l) => l.taskId.equals(id))).go();
    await (_db.delete(_db.notes)..where((n) => n.taskId.equals(id))).go();
    await (_db.delete(_db.tasks)..where((t) => t.id.equals(id))).go();
    return null;
  });

  Future<int> _write(String id, TasksCompanion values) =>
      (_db.update(_db.tasks)..where((t) => t.id.equals(id))).write(values);

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
