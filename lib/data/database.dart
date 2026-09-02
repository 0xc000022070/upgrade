import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import 'enums.dart';
import 'tables.dart';
import 'views.dart';

part 'database.g.dart';

@DriftDatabase(tables: [Projects, Tasks, Notes, ActivityEvents])
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor])
    : super(executor ?? driftDatabase(name: 'hotline'));

  @override
  int get schemaVersion => 2;

  /// Pre-release, and the only data that exists is the debug fixture, so v2
  /// recreates rather than migrating (SPEC.md §37).
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onUpgrade: (m, from, to) async {
      for (final table in allTables) {
        await m.drop(table);
      }
      await m.createAll();
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
  Stream<NextAction?> watchNextAction() {
    return customSelect(
      '''
SELECT t.id AS task_id, t.title AS title, t.is_next AS is_next,
       p.name AS project_name
FROM tasks t
LEFT JOIN projects p ON p.id = t.project_id
WHERE t.done = 0 AND t.blocked_reason IS NULL
  AND (t.is_next = 1 OR p.status = 'active')
ORDER BY t.is_next DESC,
         CASE p.priority WHEN 'high' THEN 0 WHEN 'normal' THEN 1 ELSE 2 END,
         t.created_at ASC
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
        suggested: row.read<int>('is_next') == 0,
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
  Stream<List<ProjectSummary>> watchProjectSummaries() {
    return customSelect(
      """
SELECT p.id          AS project_id,
       p.name        AS name,
       p.objective   AS objective,
       p.status      AS status,
       p.priority    AS priority,
       (SELECT COUNT(*) FROM tasks t WHERE t.project_id = p.id) AS total_count,
       (SELECT COUNT(*) FROM tasks t WHERE t.project_id = p.id AND t.done = 1) AS done_count,
       (SELECT t.title FROM tasks t
         WHERE t.project_id = p.id AND t.done = 0 AND t.is_next = 1
         LIMIT 1) AS next_title,
       (SELECT t.title FROM tasks t
         WHERE t.project_id = p.id AND t.done = 0 AND t.blocked_reason IS NOT NULL
         ORDER BY t.updated_at DESC LIMIT 1) AS blocked_title
FROM projects p
WHERE p.status <> 'archived'
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
