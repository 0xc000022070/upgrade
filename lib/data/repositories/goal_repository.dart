import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import 'package:upgrade/data/database.dart';
import 'package:upgrade/data/enums.dart';
import 'package:upgrade/data/views.dart';
import 'package:upgrade/data/repositories/activity_repository.dart';
import 'package:upgrade/data/repositories/mutation.dart';

class GoalRepository {
  GoalRepository(this._db, this._activity);

  final AppDatabase _db;
  final ActivityRepository _activity;
  static const _uuid = Uuid();

  late final _mutations = Mutations<Goal>(
    db: _db,
    activity: _activity,
    entityType: EntityType.goal,
    read: _byId,
    title: (goal) => goal.title,
    context: (goal) => _projectName(goal.projectId),
  );

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

  Future<void> rename(String id, String title, {DateTime? at}) => _mutations
      .on(id)
      .at(at)
      .titled(title)
      .unchangedWhen((goal) => goal.title == title)
      .writes(ActivityAction.updated, (goal, now) async {
        await (_db.update(_db.goals)..where((g) => g.id.equals(id))).write(
          GoalsCompanion(title: Value(title)),
        );
        return null;
      });

  /// The items under a deleted goal fall back to the project's DROPS.
  Future<void> delete(String id, {DateTime? at}) => _mutations
      .on(id)
      .at(at)
      .writes(ActivityAction.deleted, (goal, now) async {
        await (_db.update(_db.tasks)..where((t) => t.goalId.equals(id))).write(
          TasksCompanion(goalId: const Value(null), updatedAt: Value(now)),
        );
        await (_db.delete(_db.goals)..where((g) => g.id.equals(id))).go();
        return null;
      });

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
