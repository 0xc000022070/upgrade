import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/providers.dart';
import 'package:upgrade/data/enums.dart';
import 'package:upgrade/data/views.dart';
import 'package:upgrade/data/project_icons.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/design/components/list_row.dart';
import 'package:upgrade/design/components/priority_row.dart';
import 'package:upgrade/features/projects/project_icon.dart';

class ProjectRow extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
    final blocked = showLead && project.isBlocked && project.lead != null;
    final named = project.status == ProjectStatus.active || dim
        ? project.name
        : '${project.name}  ·  ${project.status.name}';
    final hasObjective = project.objective.trim().isNotEmpty;
    final ink = priorityInk(context, project.priority);
    final icon = ProjectIconKind.fromId(project.iconId);
    final row = ListRow(
      leading: icon == null
          ? null
          : ProjectIcon(
              icon,
              color: dim
                  ? context.tokens.textMuted
                  : context.tokens.textSecondary,
            ),
      leadingWidth: IconSizes.lg,
      mark: PriorityMark(
        priority: project.priority,
        seed: project.projectId.hashCode,
        dim: dim,
      ),
      title: hasObjective ? named.toUpperCase() : named,
      titleMaxLines: 2,
      metadataBelow: true,
      titleColor: dim ? context.tokens.textMuted : ink.title,
      subtitle: blocked
          ? '[ BLOCKED BY ] ${project.lead}'
          : hasObjective
          ? project.objective
          : null,
      subtitleColor: blocked ? context.tokens.warning : null,
      caption: blocked
          ? (hasObjective ? project.objective : null)
          : showLead
          ? project.lead
          : null,
      value: '${project.doneCount}/${project.totalCount}  ${project.percent}%',
      valueStrong: true,
      valueColor: dim
          ? context.tokens.textMuted
          : ink.value ?? context.tokens.accent,
      onTap: onTap,
    );

    return PrioritySlide(
      priority: project.priority,
      onChanged: (priority) => ref
          .read(projectRepositoryProvider)
          .setPriority(project.projectId, priority),
      child: row,
    );
  }
}
