import 'package:flutter/widgets.dart';

import '../../data/enums.dart';
import '../../data/views.dart';
import '../../design/colors.dart';
import '../../design/components/list_row.dart';

/// SPEC.md §19 and the §38 mocks: the project's name is the kicker, its
/// objective is the row's title, and progress lives entirely in the right
/// column — a 56x2 bar next to `done/total  percent`.
class ProjectRow extends StatelessWidget {
  const ProjectRow({
    super.key,
    required this.project,
    required this.onTap,
    this.showLead = false,
  });

  final ProjectSummary project;
  final VoidCallback onTap;

  /// HOME keeps its three rows to two lines; the full list adds the one task
  /// that moves or holds each project.
  final bool showLead;

  @override
  Widget build(BuildContext context) {
    final blocked = showLead && project.isBlocked && project.lead != null;
    return ListRow(
      kicker: project.status == ProjectStatus.active
          ? project.name
          : '${project.name}  ·  ${project.status.name}',
      title: project.objective,
      subtitle: blocked ? '[ BLOCKED BY ] ${project.lead}' : null,
      subtitleColor: HotlineColors.warning,
      caption: !blocked && showLead ? project.lead : null,
      progress: project.ratio,
      value: '${project.doneCount}/${project.totalCount}  ${project.percent}%',
      valueStrong: true,
      valueColor: HotlineColors.accent,
      onTap: onTap,
    );
  }
}
