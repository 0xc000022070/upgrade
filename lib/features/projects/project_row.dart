import 'package:flutter/widgets.dart';

import '../../data/enums.dart';
import '../../data/views.dart';
import '../../design/tokens.dart';
import '../../design/components/list_row.dart';

class ProjectRow extends StatelessWidget {
  const ProjectRow({
    super.key,
    required this.project,
    required this.onTap,
    this.showLead = false,
    this.dim = false,
  });

  final ProjectSummary project;
  final VoidCallback onTap;

  final bool showLead;

  final bool dim;

  @override
  Widget build(BuildContext context) {
    final blocked = showLead && project.isBlocked && project.lead != null;
    final named = project.status == ProjectStatus.active || dim
        ? project.name
        : '${project.name}  ·  ${project.status.name}';
    final hasObjective = project.objective.trim().isNotEmpty;
    return ListRow(
      kicker: hasObjective ? named.toUpperCase() : null,
      title: hasObjective ? project.objective : named,
      titleColor: dim ? context.tokens.textMuted : null,
      subtitle: blocked ? '[ BLOCKED BY ] ${project.lead}' : null,
      subtitleColor: context.tokens.warning,
      caption: !blocked && showLead ? project.lead : null,
      progress: project.ratio,
      value: '${project.doneCount}/${project.totalCount}  ${project.percent}%',
      valueStrong: true,
      valueColor: dim ? context.tokens.textMuted : context.tokens.accent,
      onTap: onTap,
    );
  }
}
