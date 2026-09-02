import 'enums.dart';

/// Read models for the screens. They are query results, not stored rows —
/// progress in particular is computed (SPEC.md §33: one behavior, consistently),
/// never persisted.
class NextAction {
  const NextAction({
    required this.taskId,
    required this.title,
    required this.projectName,
    required this.suggested,
  });

  final String taskId;
  final String title;

  /// Null when the task is loose.
  final String? projectName;

  /// True when nothing was flagged and the screen picked the row itself, which
  /// SPEC.md §37 asks be labelled rather than presented as a decision already
  /// taken.
  final bool suggested;
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

  /// "TASK COMPLETED", "PROJECT UPDATED" — the §22 left column.
  String get label =>
      '${entityType.wire} ${action.wire}'.replaceAll('_', ' ').toUpperCase();
}

/// One row of the PROJECTS list (SPEC.md §19, §37). Everything the row shows is
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
