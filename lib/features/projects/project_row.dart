import 'package:flutter/widgets.dart';

import '../../data/enums.dart';
import '../../data/views.dart';
import '../../design/colors.dart';
import '../../design/components/list_row.dart';

/// From the mocks: the project's name is the kicker, its
/// objective is the row's title, and progress lives entirely in the right
/// column — a 56x2 bar next to `done/total  percent`.
///
/// The objective is optional. Without one the name moves down to the
/// title line and the kicker goes — a row must not spend a line on nothing.
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

  /// HOME keeps its three rows to two lines; the full list adds the one task
  /// that moves or holds each project.
  final bool showLead;

  /// The `ARCHIVED N` panel's rows. Archived work is a record, so it
  /// reads at the same weight a done item does.
  final bool dim;

  @override
  Widget build(BuildContext context) {
    final blocked = showLead && project.isBlocked && project.lead != null;
    // The status rides the name so a held project reads as one in a list of
    // running ones. Inside the `ARCHIVED` panel the header already said
    // it, so the suffix would only repeat the panel.
    final named = project.status == ProjectStatus.active || dim
        ? project.name
        : '${project.name}  ·  ${project.status.name}';
    final hasObjective = project.objective.trim().isNotEmpty;
    return ListRow(
      kicker: hasObjective ? named : null,
      title: hasObjective ? project.objective : named,
      titleColor: dim ? SpectacleColors.textMuted : null,
      subtitle: blocked ? '[ BLOCKED BY ] ${project.lead}' : null,
      subtitleColor: SpectacleColors.warning,
      caption: !blocked && showLead ? project.lead : null,
      progress: project.ratio,
      value: '${project.doneCount}/${project.totalCount}  ${project.percent}%',
      valueStrong: true,
      valueColor: dim ? SpectacleColors.textMuted : SpectacleColors.accent,
      onTap: onTap,
    );
  }
}
