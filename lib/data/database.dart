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
    : super(executor ?? driftDatabase(name: 'spectacle'));

  @override
  int get schemaVersion => 14;

  /// From v2 on there is real data on the user's handset, so the
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
        // Links fold into attachments. The old table is left in place
        // rather than dropped: the copy is the only destructive step this
        // migration could take, and not taking it is what makes a rollback to
        // v3 still find its rows.
        await m.createTable(attachments);
        await customStatement('''
INSERT INTO attachments (id, item_id, kind, value, created_at)
SELECT id, task_id, 'url', url, created_at FROM links
''');
      }
      if (from < 5) {
        // Adds one table and touches nothing else. A preference that
        // has never been written has no row, so the defaults live in
        // [SettingsRepository] and this migration has no backfill to do.
        await m.createTable(settings);
      }
      if (from < 6) {
        // Adds one nullable column. Every existing project reads back
        // with a null parent, which is exactly what a root is, so the tree the
        // migration produces is the flat list the user already had.
        await m.addColumn(projects, projects.parentId);
      }
      if (from < 7) {
        // Three empty tables and nothing else. There is no default host to
        // backfill — the app never assumes one
        // — so an install that upgrades into v7 comes up with no key, no host
        // and no integration switched on, which is the same state a fresh
        // install has and the one the AGENTS panel renders as blocked.
        await m.createTable(keys);
        await m.createTable(hosts);
        await m.createTable(hostIntegrations);
      }
      // Adds one column with a default, so SQLite backfills every
      // existing row as it rewrites the table header and no UPDATE is needed.
      // 22 is not a guess for those rows: it is the port the transport dialled
      // unconditionally in every build that wrote them.
      //
      // Only from 7. [Migrator.createTable] above builds `hosts` from the
      // current definition, which already carries the column, so a database
      // coming from below 7 gets it there and adding it again is an error.
      if (from == 7) {
        await m.addColumn(hosts, hosts.port);
      }
      // Two empty tables. Nothing to backfill: a path is something the user
      // registers by hand, and a dispatch is written only by a send that has
      // already happened, so an upgraded install starts with neither and the
      // host form draws its paths block empty.
      if (from < 9) {
        await m.createTable(paths);
        await m.createTable(dispatches);
      }
      // The same shape as the port column above: a database from below 7 has
      // its hosts table created from the current definition, which already
      // carries these three, so only one that already had the table gets them
      // added. Nullable and not backfilled — an unpinned host pins on its next
      // connection, which is the one place the fingerprint can be learned.
      if (from >= 7 && from < 10) {
        await m.addColumn(hosts, hosts.hostKeyType);
        await m.addColumn(hosts, hosts.hostKeyFingerprint);
        await m.addColumn(hosts, hosts.hostKeyPinnedAt);
      }
      // One empty table. A tab is written when a shell opens, so an install
      // that upgrades into v11 comes up with none, which is what every install
      // before this one came up with.
      if (from < 11) {
        await m.createTable(shellTabs);
      }
      // The agent moves off the path and onto the send. Every dispatch already
      // made inherits the kind its path carried, so the sent lines keep saying
      // what picked the work up; only then is the column dropped, and a path
      // that is gone leaves the dispatch on the column's own default.
      //
      // Only from 9: below it the two tables are created above from the current
      // definitions, which carry these columns and no `paths.agent` already.
      if (from >= 9 && from < 12) {
        await m.addColumn(dispatches, dispatches.agent);
        await m.addColumn(dispatches, dispatches.model);
        await m.database.customStatement(
          'UPDATE dispatches SET agent = coalesce('
          '(SELECT agent FROM paths WHERE paths.id = dispatches.path_id), '
          "'claude')",
        );
        // The rebuild takes its shape from the current definition, so every
        // column added to `paths` after this migration was written is a column
        // this rebuild has to be told about — it is not in the old table to be
        // copied from.
        await m.alterTable(
          TableMigration(paths, newColumns: [paths.projectId]),
        );
      }
      // One nullable column, not backfilled: a host with no password is the
      // host every build before this one had. Only from 7, as the host key
      // columns above: below it the table is created from the current
      // definition, which already carries it.
      if (from >= 7 && from < 13) {
        await m.addColumn(hosts, hosts.vncPassword);
      }
      // One nullable column and no backfill: a registered directory that
      // predates the link belongs to no project, which is exactly what an
      // unlinked one is, so the list this migration produces is the flat set
      // the user already had.
      //
      // Only from 12. Below 9 `paths` is created above from the current
      // definition, and 9 to 11 goes through the rebuild above, which is the
      // same definition again — both already carry the column.
      if (from >= 12 && from < 14) {
        await m.addColumn(paths, paths.projectId);
      }
    },
  );

  /// ISO-8601 text keeps the stored instant unambiguous and keeps raw-SQL
  /// ORDER BY on timestamps correct, since UTC ISO strings sort lexically.
  @override
  DriftDatabaseOptions get options =>
      const DriftDatabaseOptions(storeDateTimeAsText: true);

  /// The flagged task, and only that: there is no suggestion fallback, so with
  /// nothing flagged there is no row and Home omits the panel entirely. A
  /// screen that picks the row itself was answering a question nobody asked.
  ///
  /// A drop is an item with no project, and a goal is optional grouping, so a
  /// project task without one is still a task and can still be the flagged row.
  ///
  /// Hidden, not archived. A task under a live project whose
  /// grandparent is archived has left the user's field of view just as
  /// completely as one under an archived project, so it leaves Home with it.
  Stream<NextAction?> watchNextAction() {
    return customSelect(
      '''
$_withVisibility
SELECT t.id AS task_id, t.title AS title, p.name AS project_name
FROM tasks t
LEFT JOIN projects p ON p.id = t.project_id
WHERE t.done = 0 AND t.blocked_reason IS NULL AND t.is_next = 1
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

  /// The recursive walks every hierarchy question is asked
  /// through, spliced into the queries below rather than declared as SQL views:
  /// drift keys stream invalidation off the [readsFrom] table set, and a view
  /// would hide `projects` from it.
  ///
  /// `visibility` carries the archived flag down from the roots, so a project
  /// is hidden when it or any ancestor is archived. It descends from roots
  /// only, so a `parent_id` cycle never enters it — and a row missing from it
  /// reads as hidden, which makes a corrupted tree degrade to invisible instead
  /// of to a hang. `subtree` pairs every project with itself and each of its
  /// descendants, under the depth bound the repository's cycle guard enforces
  /// on write, restated here where a malformed row would otherwise loop.
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

  /// Absent from `visibility` counts as hidden; see [_visibilityCte].
  static String _visible(String column) =>
      'COALESCE((SELECT v.hidden FROM visibility v WHERE v.id = $column), 1) = 0';

  /// The ordering is a projection concern, not a column sort:
  /// status and priority are stored as their names, so `ORDER BY` on either
  /// column would be alphabetical. Priority ranks first among active projects
  /// because HOME shows only the top three rows of this same list.
  /// The same projection answers both lists. Archived projects
  /// are absent from every screen that asks what to do next, and present in the
  /// one panel that exists to hold them.
  /// Progress counts the subtree, while the lead line stays the project's own:
  /// only the number aggregates, and a task is still ranked by the project it
  /// is actually filed in.
  Stream<List<ProjectSummary>> _summaries(
    String where, {
    List<Variable<Object>> variables = const [],
  }) {
    return customSelect(
      """
$_withTree
SELECT p.id           AS project_id,
       p.name         AS name,
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
         CASE p.priority WHEN 'high' THEN 0 WHEN 'normal' THEN 1 ELSE 2 END,
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

  /// Home and the Projects tab list roots only. A child is reached
  /// through its parent's detail, never from a flat list.
  Stream<List<ProjectSummary>> watchRootSummaries() =>
      _summaries("p.parent_id IS NULL AND p.status <> 'archived'");

  /// The `ARCHIVED` panel lists projects whose own status is archived
  /// and whose parent is not itself hidden — an archived branch appears once,
  /// at the point where it was archived, not once per project under it.
  Stream<List<ProjectSummary>> watchArchivedSummaries() => _summaries(
    "p.status = 'archived' "
    'AND (p.parent_id IS NULL OR ${_visible('p.parent_id')})',
  );

  /// The immediate children of one project, as the `PROJECTS N` panel
  /// on its detail. Archived children are not here — they are in the Projects
  /// tab's `ARCHIVED` panel, the one place an archived project is listed.
  Stream<List<ProjectSummary>> watchChildSummaries(String parentId) =>
      _summaries(
        "p.parent_id = ?1 AND p.status <> 'archived'",
        variables: [Variable<String>(parentId)],
      );

  /// One project's own row, for the subtree number under its title.
  Stream<ProjectSummary?> watchProjectSummary(String id) => _summaries(
    'p.id = ?1',
    variables: [Variable<String>(id)],
  ).map((rows) => rows.isEmpty ? null : rows.first);

  /// The breadcrumb: the ancestors of [id], root first, self excluded. A
  /// stream and not a read, so renaming or archiving a project two levels up
  /// repaints the crumb of the screen the user is standing on.
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

  /// Every project the user can still reach — hidden ones are dropped, so the
  /// MOVE picker and the `[ PARENT ]` picker cannot file work into
  /// a branch that is archived out of sight.
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

  /// [id] and every project under it, shallowest first. The cycle guard
  /// on write and the cascade on delete are the same walk.
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

  /// A goal's progress is counted from the items pointing at it,
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

  /// The quick view's header strip. Resolved in one read so the
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
