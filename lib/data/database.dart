import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import 'enums.dart';
import 'tables.dart';
import 'views.dart';

part 'database.g.dart';

@DriftDatabase(
  tables: [
    Projects,
    Goals,
    Tasks,
    Links,
    Attachments,
    Notes,
    ActivityEvents,
    Settings,
    Keys,
    Hosts,
    HostIntegrations,
    Paths,
    Dispatches,
    ShellTabs,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor])
    : super(executor ?? driftDatabase(name: 'dazzle'));

  @override
  int get schemaVersion => 19;

  /// Every installed build is at 19, so an older file is rebuilt empty rather than walked
  /// up steps no install runs any more. The next bump adds its step after this one.
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: _create,
    onUpgrade: (m, from, to) async {
      if (from < 19) {
        for (final table in allTables) {
          await m.drop(table);
        }
        await _create(m);
        return;
      }
    },
  );

  Future<void> _create(Migrator m) async {
    await m.createAll();
    await into(
      settings,
    ).insert(SettingsCompanion.insert(key: 'builtin_auto_enable', value: '0'));
  }

  /// UTC ISO-8601 strings sort lexically, which is what keeps raw-SQL ORDER BY on a
  /// timestamp correct.
  @override
  DriftDatabaseOptions get options =>
      const DriftDatabaseOptions(storeDateTimeAsText: true);

  Stream<NextAction?> watchNextAction() {
    return customSelect(
      '''
$_withVisibility
SELECT t.id AS task_id, t.title AS title, p.name AS project_name,
       t.blocked_reason AS blocked_reason
FROM tasks t
LEFT JOIN projects p ON p.id = t.project_id
WHERE t.done = 0 AND t.is_next = 1
  AND (p.id IS NULL OR ${_visible('p.id')})
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
        blockedReason: row.read<String?>('blocked_reason'),
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

  /// Spliced into the queries rather than declared as views: drift keys stream
  /// invalidation off [readsFrom], and a view would hide `projects` from it. A project
  /// missing from `visibility` reads as hidden, so a cycle degrades to invisible.
  static const _visibilityCte = """
  visibility(id, hidden) AS (
    SELECT p.id, CASE WHEN p.status = 'archived' THEN 1 ELSE 0 END
      FROM projects p WHERE p.parent_id IS NULL
    UNION ALL
    SELECT c.id,
           CASE WHEN v.hidden = 1 OR c.status = 'archived' THEN 1 ELSE 0 END
      FROM projects c JOIN visibility v ON c.parent_id = v.id
  )""";

  static const _progressCte = """
  subtree(root, id, depth) AS (
    SELECT p.id, p.id, 0 FROM projects p
    UNION ALL
    SELECT s.root, c.id, s.depth + 1
      FROM projects c JOIN subtree s ON c.parent_id = s.id
     WHERE s.depth < 32
  ),
  progress(root, total_count, done_count) AS (
    SELECT s.root,
           COUNT(t.id),
           COALESCE(SUM(CASE WHEN t.done = 1 THEN 1 ELSE 0 END), 0)
      FROM subtree s LEFT JOIN tasks t ON t.project_id = s.id
     GROUP BY s.root
  )""";

  static const _withVisibility = 'WITH RECURSIVE$_visibilityCte';
  static const _withTree = 'WITH RECURSIVE$_visibilityCte,$_progressCte';

  static String _visible(String column) =>
      'COALESCE((SELECT v.hidden FROM visibility v WHERE v.id = $column), 1) = 0';

  /// Status and priority are stored as their names, so `ORDER BY` on either column would
  /// be alphabetical.
  Stream<List<ProjectSummary>> _summaries(
    String where, {
    List<Variable<Object>> variables = const [],
  }) {
    return customSelect(
      """
$_withTree
SELECT p.id           AS project_id,
       p.name         AS name,
       p.icon_id      AS icon_id,
       p.objective    AS objective,
       p.status       AS status,
       p.priority     AS priority,
       pr.total_count AS total_count,
       pr.done_count  AS done_count,
       (SELECT t.title FROM tasks t
         WHERE t.project_id = p.id AND t.done = 0 AND t.is_next = 1
         LIMIT 1) AS next_title,
       (SELECT t.title FROM tasks t
         WHERE t.project_id = p.id AND t.done = 0
           AND t.blocked_reason IS NOT NULL
         ORDER BY t.updated_at DESC LIMIT 1) AS blocked_title
FROM projects p
JOIN progress pr ON pr.root = p.id
WHERE $where
ORDER BY CASE p.status WHEN 'active' THEN 0 WHEN 'paused' THEN 1 ELSE 2 END,
         CASE p.priority WHEN 'critical' THEN 0 WHEN 'high' THEN 1
                         WHEN 'normal' THEN 2 ELSE 3 END,
         p.updated_at DESC
""",
      variables: variables,
      readsFrom: {projects, tasks},
    ).watch().map(
      (rows) => rows
          .map(
            (row) => ProjectSummary(
              projectId: row.read<String>('project_id'),
              name: row.read<String>('name'),
              iconId: row.read<String?>('icon_id'),
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

  Stream<List<ProjectSummary>> watchRootSummaries() =>
      _summaries("p.parent_id IS NULL AND p.status <> 'archived'");

  Stream<List<ProjectSummary>> watchArchivedSummaries() => _summaries(
    "p.status = 'archived' "
    'AND (p.parent_id IS NULL OR ${_visible('p.parent_id')})',
  );

  Stream<List<ProjectSummary>> watchChildSummaries(String parentId) =>
      _summaries(
        "p.parent_id = ?1 AND p.status <> 'archived'",
        variables: [Variable<String>(parentId)],
      );

  Stream<ProjectSummary?> watchProjectSummary(String id) => _summaries(
    'p.id = ?1',
    variables: [Variable<String>(id)],
  ).map((rows) => rows.isEmpty ? null : rows.first);

  Stream<List<ProjectCrumb>> watchAncestors(String id) {
    return customSelect(
      """
WITH RECURSIVE
  chain(id, name, status, parent_id, depth) AS (
    SELECT p.id, p.name, p.status, p.parent_id, 0
      FROM projects p WHERE p.id = ?1
    UNION ALL
    SELECT a.id, a.name, a.status, a.parent_id, c.depth + 1
      FROM projects a JOIN chain c ON a.id = c.parent_id
     WHERE c.depth < 32
  )
SELECT id, name, status FROM chain WHERE depth > 0 ORDER BY depth DESC
""",
      variables: [Variable<String>(id)],
      readsFrom: {projects},
    ).watch().map(
      (rows) => rows
          .map(
            (row) => ProjectCrumb(
              id: row.read<String>('id'),
              name: row.read<String>('name'),
              status: ProjectStatus.values.byName(row.read<String>('status')),
            ),
          )
          .toList(),
    );
  }

  Stream<List<Project>> watchVisibleProjects() {
    return customSelect(
      """
$_withVisibility
SELECT p.* FROM projects p
JOIN visibility v ON v.id = p.id
WHERE v.hidden = 0
ORDER BY p.created_at ASC
""",
      readsFrom: {projects},
    ).watch().map((rows) => rows.map((row) => projects.map(row.data)).toList());
  }

  Future<List<String>> subtreeIds(String id) async {
    final rows = await customSelect(
      """
WITH RECURSIVE
  sub(id, depth) AS (
    SELECT ?1, 0
    UNION ALL
    SELECT c.id, s.depth + 1
      FROM projects c JOIN sub s ON c.parent_id = s.id
     WHERE s.depth < 32
  )
SELECT id, depth FROM sub ORDER BY depth ASC
""",
      variables: [Variable<String>(id)],
      readsFrom: {projects},
    ).get();
    return rows.map((row) => row.read<String>('id')).toList();
  }

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

  Future<int> count(TableInfo<Table, Object?> table) async {
    final rows = countAll();
    final query = selectOnly(table)..addColumns([rows]);
    return (await query.getSingle()).read(rows)!;
  }
}
