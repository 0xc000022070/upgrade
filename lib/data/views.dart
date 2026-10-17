import 'package:striked/data/database.dart';
import 'package:striked/data/enums.dart';

class NextAction {
  const NextAction({
    required this.taskId,
    required this.title,
    required this.projectName,
    required this.blockedReason,
  });

  final String taskId;
  final String title;

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

  String get label =>
      '${entityType.wire} ${action.wire}'.replaceAll('_', ' ').toUpperCase();
}

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
    this.iconId,
  });

  final String projectId;
  final String? iconId;
  final String name;
  final String objective;
  final ProjectStatus status;
  final Priority priority;
  final int doneCount;
  final int totalCount;
  final String? nextActionTitle;
  final String? blockedTitle;

  double get ratio => totalCount == 0 ? 0 : doneCount / totalCount;

  int get percent => (ratio * 100).round();

  bool get isBlocked => blockedTitle != null;

  String? get lead => blockedTitle ?? nextActionTitle;
}

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

class ItemTarget {
  const ItemTarget.drops() : projectId = null, goalId = null;
  const ItemTarget.project(String this.projectId) : goalId = null;
  const ItemTarget.goal(String this.projectId, String this.goalId);

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

class SearchHit {
  const SearchHit({
    required this.task,
    required this.location,
    required this.images,
    required this.links,
    required this.sent,
  });

  final Task task;

  final ItemLocation location;
  final int images;

  final List<String> links;
  final bool sent;
}
