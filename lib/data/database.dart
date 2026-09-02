import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import 'enums.dart';
import 'tables.dart';
import 'views.dart';

part 'database.g.dart';

@DriftDatabase(
  tables: [Projects, Goals, Tasks, Links, Attachments, Notes, ActivityEvents],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor])
    : super(executor ?? driftDatabase(name: 'hotline'));

  @override
  int get schemaVersion => 4;

  /// SPEC.md §39.7: from v2 on there is real data on the user's handset, so the
  /// upgrade is additive — two new tables and two nullable columns, nothing
  /// dropped and nothing recreated. Only the pre-v2 path, which never left the
  /// debug fixture, still recreates.
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        for (final table in allTables) {
          await m.drop(table);
        }
        await m.createAll();
        return;
      }
      if (from < 3) {
        await m.createTable(goals);
        await m.createTable(links);
        await m.addColumn(tasks, tasks.goalId);
        await m.addColumn(tasks, tasks.bundleId);
      }
      if (from < 4) {
        // §39.10 folds links into attachments. The old table is left in place
        // rather than dropped: the copy is the only destructive step this
        // migration could take, and not taking it is what makes a rollback to
        // v3 still find its rows.
        await m.createTable(attachments);
        await customStatement('''
INSERT INTO attachments (id, item_id, kind, value, created_at)
SELECT id, task_id, 'url', url, created_at FROM links
''');
      }
    },
  );

  /// ISO-8601 text keeps the stored instant unambiguous and keeps raw-SQL
  /// ORDER BY on timestamps correct, since UTC ISO strings sort lexically.
  @override
  DriftDatabaseOptions get options =>
      const DriftDatabaseOptions(storeDateTimeAsText: true);

  /// SPEC.md §37: the flagged task, or — labelled as a suggestion — the first
  /// open task of the highest-priority active project. A loose task can be
  /// flagged but is never suggested: it has no project to rank it by.
  /// SPEC.md §39.3 drops the suggestion fallback: the panel now answers "what
  /// did I flag", so with nothing flagged there is no row and Home omits the
  /// panel entirely. A screen that picks the row itself was answering a
  /// question nobody asked.
  /// SPEC.md §39.11 (ruling reversed 2026-09-02, same day): a drop is an item
  /// with no project. A goal is optional grouping, so a project task without
  /// one is still a task and can still be the flagged row.
  Stream<NextAction?> watchNextAction() {
    return customSelect(
      '''
SELECT t.id AS task_id, t.title AS title, p.name AS project_name
FROM tasks t
LEFT JOIN projects p ON p.id = t.project_id
WHERE t.done = 0 AND t.blocked_reason IS NULL AND t.is_next = 1
  AND (p.id IS NULL OR p.status <> 'archived')
LIMIT 1
''',
      readsFrom: {tasks, projects},
    ).watch().map((rows) {
      if (rows.isEmpty) return null;
      final row = rows.first;
      return NextAction(
        taskId: row.read<String>('task_id'),
        title: row.read<String>('title'),
        projectName: row.read<String?>('project_name'),
      );
    });
  }

  Stream<List<BlockedTask>> watchBlockedTasks() {
    return customSelect(
      '''
SELECT t.id AS task_id, t.title AS title, t.blocked_reason AS reason,
       p.name AS project_name
FROM tasks t
LEFT JOIN projects p ON p.id = t.project_id
WHERE t.blocked_reason IS NOT NULL AND t.done = 0
ORDER BY t.updated_at DESC
''',
      readsFrom: {tasks, projects},
    ).watch().map(
      (rows) => rows
          .map(
            (row) => BlockedTask(
              taskId: row.read<String>('task_id'),
              title: row.read<String>('title'),
              projectName: row.read<String?>('project_name'),
              reason: row.read<String>('reason'),
            ),
          )
          .toList(),
    );
  }

  Stream<List<ActivityEntry>> watchRecentActivity({int limit = 5}) {
    return (select(activityEvents)
          ..orderBy([(e) => OrderingTerm.desc(e.createdAt)])
          ..limit(limit))
        .watch()
        .map((rows) => rows.map(activityEntryOf).toList());
  }

  /// SPEC.md §19. The ordering is a projection concern, not a column sort:
  /// status and priority are stored as their names, so `ORDER BY` on either
  /// column would be alphabetical. Priority ranks first among active projects
  /// because HOME shows only the top three rows of this same list.
  /// SPEC.md §39.14: the same projection answers both lists. Archived projects
  /// are absent from every screen that asks what to do next, and present in the
  /// one panel that exists to hold them.
  Stream<List<ProjectSummary>> watchProjectSummaries({bool archived = false}) {
    return customSelect(
      """
SELECT p.id          AS project_id,
       p.name        AS name,
       p.objective   AS objective,
       p.status      AS status,
       p.priority    AS priority,
       (SELECT COUNT(*) FROM tasks t
         WHERE t.project_id = p.id) AS total_count,
       (SELECT COUNT(*) FROM tasks t
         WHERE t.project_id = p.id AND t.done = 1) AS done_count,
       (SELECT t.title FROM tasks t
         WHERE t.project_id = p.id AND t.done = 0 AND t.is_next = 1
         LIMIT 1) AS next_title,
       (SELECT t.title FROM tasks t
         WHERE t.project_id = p.id AND t.done = 0
           AND t.blocked_reason IS NOT NULL
         ORDER BY t.updated_at DESC LIMIT 1) AS blocked_title
FROM projects p
WHERE p.status ${archived ? '=' : '<>'} 'archived'
ORDER BY CASE p.status WHEN 'active' THEN 0 WHEN 'paused' THEN 1 ELSE 2 END,
         CASE p.priority WHEN 'high' THEN 0 WHEN 'normal' THEN 1 ELSE 2 END,
         p.updated_at DESC
""",
      readsFrom: {projects, tasks},
    ).watch().map(
      (rows) => rows
          .map(
            (row) => ProjectSummary(
              projectId: row.read<String>('project_id'),
              name: row.read<String>('name'),
              objective: row.read<String>('objective'),
              status: ProjectStatus.values.byName(row.read<String>('status')),
              priority: Priority.values.byName(row.read<String>('priority')),
              doneCount: row.read<int>('done_count'),
              totalCount: row.read<int>('total_count'),
              nextActionTitle: row.read<String?>('next_title'),
              blockedTitle: row.read<String?>('blocked_title'),
            ),
          )
          .toList(),
    );
  }

  /// SPEC.md §39.1: a goal's progress is counted from the items pointing at it,
  /// never stored. One projection keeps the GOALS panel headers off an N+1.
  Stream<List<GoalSummary>> watchGoalSummaries(String projectId) {
    return customSelect(
      """
SELECT g.id        AS goal_id,
       g.project_id AS project_id,
       g.title     AS title,
       (SELECT COUNT(*) FROM tasks t WHERE t.goal_id = g.id) AS total_count,
       (SELECT COUNT(*) FROM tasks t WHERE t.goal_id = g.id AND t.done = 1) AS done_count
FROM goals g
WHERE g.project_id = ?1
ORDER BY g.sort_order ASC, g.created_at ASC
""",
      variables: [Variable<String>(projectId)],
      readsFrom: {goals, tasks},
    ).watch().map(
      (rows) => rows
          .map(
            (row) => GoalSummary(
              goalId: row.read<String>('goal_id'),
              projectId: row.read<String>('project_id'),
              title: row.read<String>('title'),
              doneCount: row.read<int>('done_count'),
              totalCount: row.read<int>('total_count'),
            ),
          )
          .toList(),
    );
  }

  /// The quick view's header strip (SPEC.md §39.4). Resolved in one read so the
  /// sheet opens with its breadcrumb already known.
  Stream<ItemLocation> watchItemLocation(String taskId) {
    return customSelect(
      """
SELECT p.name AS project_name, g.title AS goal_title
FROM tasks t
LEFT JOIN projects p ON p.id = t.project_id
LEFT JOIN goals g ON g.id = t.goal_id
WHERE t.id = ?1
""",
      variables: [Variable<String>(taskId)],
      readsFrom: {tasks, projects, goals},
    ).watch().map((rows) {
      if (rows.isEmpty) return const ItemLocation(null, null);
      return ItemLocation(
        rows.first.read<String?>('project_name'),
        rows.first.read<String?>('goal_title'),
      );
    });
  }

  static ActivityEntry activityEntryOf(ActivityEvent event) {
    final payload = event.payload == null
        ? const <String, dynamic>{}
        : jsonDecode(event.payload!) as Map<String, dynamic>;
    return ActivityEntry(
      id: event.id,
      entityType: event.entityType,
      action: event.action,
      createdAt: event.createdAt,
      title: payload['title'] as String? ?? '',
      context: payload['context'] as String?,
      detail: payload['detail'] as String?,
    );
  }
}
