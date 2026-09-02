import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../database.dart';
import '../enums.dart';
import '../views.dart';
import 'activity_repository.dart';

/// SPEC.md §39.1/§39.2. A goal is a grouping inside one project; it owns no
/// state, so every operation here is about where items sit, not about the goal.
class GoalRepository {
  GoalRepository(this._db, this._activity);

  final AppDatabase _db;
  final ActivityRepository _activity;
  static const _uuid = Uuid();

  Stream<List<Goal>> watchByProject(String projectId) {
    return (_db.select(_db.goals)
          ..where((g) => g.projectId.equals(projectId))
          ..orderBy([
            (g) => OrderingTerm.asc(g.sortOrder),
            (g) => OrderingTerm.asc(g.createdAt),
          ]))
        .watch();
  }

  Stream<List<GoalSummary>> watchSummaries(String projectId) =>
      _db.watchGoalSummaries(projectId);

  Future<String> create({
    required String projectId,
    required String title,
    DateTime? at,
  }) {
    final now = at ?? DateTime.now().toUtc();
    final id = _uuid.v7();
    return _db.transaction(() async {
      await _db
          .into(_db.goals)
          .insert(
            GoalsCompanion.insert(
              id: id,
              projectId: projectId,
              title: title,
              sortOrder: Value(await _nextOrder(projectId)),
              createdAt: now,
            ),
          );
      await _activity.log(
        entityType: EntityType.goal,
        entityId: id,
        action: ActivityAction.created,
        title: title,
        context: await _projectName(projectId),
        at: now,
      );
      return id;
    });
  }

  Future<void> rename(String id, String title, {DateTime? at}) {
    final now = at ?? DateTime.now().toUtc();
    return _db.transaction(() async {
      final goal = await _byId(id);
      if (goal.title == title) return;
      await (_db.update(_db.goals)..where((g) => g.id.equals(id))).write(
        GoalsCompanion(title: Value(title)),
      );
      await _activity.log(
        entityType: EntityType.goal,
        entityId: id,
        action: ActivityAction.updated,
        title: title,
        context: await _projectName(goal.projectId),
        at: now,
      );
    });
  }

  /// SPEC.md §39.2: the items under a deleted goal fall back to the project's
  /// DROPS. Deleting a grouping never deletes what was grouped.
  Future<void> delete(String id, {DateTime? at}) {
    final now = at ?? DateTime.now().toUtc();
    return _db.transaction(() async {
      final goal = await _byId(id);
      await (_db.update(_db.tasks)..where((t) => t.goalId.equals(id))).write(
        TasksCompanion(goalId: const Value(null), updatedAt: Value(now)),
      );
      await (_db.delete(_db.goals)..where((g) => g.id.equals(id))).go();
      await _activity.log(
        entityType: EntityType.goal,
        entityId: id,
        action: ActivityAction.deleted,
        title: goal.title,
        context: await _projectName(goal.projectId),
        at: now,
      );
    });
  }

  Future<int> _nextOrder(String projectId) async {
    final rows = await (_db.select(
      _db.goals,
    )..where((g) => g.projectId.equals(projectId))).get();
    if (rows.isEmpty) return 0;
    return rows.map((g) => g.sortOrder).reduce((a, b) => a > b ? a : b) + 1;
  }

  Future<Goal> _byId(String id) =>
      (_db.select(_db.goals)..where((g) => g.id.equals(id))).getSingle();

  Future<String?> _projectName(String projectId) async {
    final project = await (_db.select(
      _db.projects,
    )..where((p) => p.id.equals(projectId))).getSingleOrNull();
    return project?.name;
  }
}
