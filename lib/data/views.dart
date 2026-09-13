import 'enums.dart';

/// Read models for the screens. They are query results, not stored rows —
/// progress in particular is computed — one behaviour, consistently —
/// never persisted.
class NextAction {
  const NextAction({
    required this.taskId,
    required this.title,
    required this.projectName,
    required this.blockedReason,
  });

  final String taskId;
  final String title;

  /// Null when the item is a drop.
  final String? projectName;

  final String? blockedReason;
}

class BlockedTask {
  const BlockedTask({
    required this.taskId,
    required this.title,
    required this.projectName,
    required this.reason,
  });

  final String taskId;
  final String title;
  final String? projectName;
  final String reason;
}

class ActivityEntry {
  const ActivityEntry({
    required this.id,
    required this.entityType,
    required this.action,
    required this.createdAt,
    required this.title,
    this.context,
    this.detail,
  });

  final String id;
  final EntityType entityType;
  final ActivityAction action;
  final DateTime createdAt;
  final String title;
  final String? context;
  final String? detail;

  /// "TASK COMPLETED", "PROJECT UPDATED" — the activity stream's left column.
  String get label =>
      '${entityType.wire} ${action.wire}'.replaceAll('_', ' ').toUpperCase();
}

/// One row of the PROJECTS list. Everything the row shows is
/// resolved in a single projection query so the list never fans out into N+1
/// reads as it scrolls.
class ProjectSummary {
  const ProjectSummary({
    required this.projectId,
    required this.name,
    required this.objective,
    required this.status,
    required this.priority,
    required this.doneCount,
    required this.totalCount,
    required this.nextActionTitle,
    required this.blockedTitle,
  });

  final String projectId;
  final String name;
  final String objective;
  final ProjectStatus status;
  final Priority priority;
  final int doneCount;
  final int totalCount;
  final String? nextActionTitle;
  final String? blockedTitle;

  /// A project with no tasks is 0%, not undefined.
  double get ratio => totalCount == 0 ? 0 : doneCount / totalCount;

  int get percent => (ratio * 100).round();

  /// A blocker outranks a next action: it is the thing that needs a decision.
  bool get isBlocked => blockedTitle != null;

  String? get lead => blockedTitle ?? nextActionTitle;
}

/// One segment of the breadcrumb: an ancestor of the project on
/// screen. [status] is carried because the detail screen has to know whether an
/// ancestor is archived — that is what removes its own `UNARCHIVE`.
class ProjectCrumb {
  const ProjectCrumb({
    required this.id,
    required this.name,
    required this.status,
  });

  final String id;
  final String name;
  final ProjectStatus status;
}

/// One GOALS panel header. Progress is counted from the
/// items under the goal, so an empty goal is 0/0 rather than undefined.
class GoalSummary {
  const GoalSummary({
    required this.goalId,
    required this.projectId,
    required this.title,
    required this.doneCount,
    required this.totalCount,
  });

  final String goalId;
  final String projectId;
  final String title;
  final int doneCount;
  final int totalCount;

  double get ratio => totalCount == 0 ? 0 : doneCount / totalCount;

  int get percent => (ratio * 100).round();
}

/// The quick view breadcrumb: `DROPS`,
/// `INFRA PERSONAL / DROPS`, `INFRA PERSONAL / REDUCE SAAS`.
class ItemLocation {
  const ItemLocation(this.projectName, this.goalTitle);

  final String? projectName;
  final String? goalTitle;

  List<String> get crumbs => [
    ?projectName?.toUpperCase(),
    goalTitle?.toUpperCase() ?? 'DROPS',
  ];

  String get label => crumbs.join(' / ');
}

/// Where an item can be filed. Not an enum: the goal case needs
/// its project too, since filing under a goal implies the goal's project.
class ItemTarget {
  const ItemTarget.drops() : projectId = null, goalId = null;
  const ItemTarget.project(String this.projectId) : goalId = null;
  const ItemTarget.goal(String this.projectId, String this.goalId);

  /// Where an item already sits, so the pickers can draw it as the current
  /// value without every caller repeating the two null checks.
  factory ItemTarget.of(String? projectId, String? goalId) {
    if (projectId == null) return const ItemTarget.drops();
    if (goalId == null) return ItemTarget.project(projectId);
    return ItemTarget.goal(projectId, goalId);
  }

  final String? projectId;
  final String? goalId;

  bool get isDrops => projectId == null;

  @override
  bool operator ==(Object other) =>
      other is ItemTarget &&
      other.projectId == projectId &&
      other.goalId == goalId;

  @override
  int get hashCode => Object.hash(projectId, goalId);
}
