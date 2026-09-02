import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers.dart';
import '../../design/components/list_row.dart';
import '../../design/components/panel.dart';
import '../../design/components/section.dart';
import '../screen_scaffold.dart';
import 'project_detail_screen.dart';
import 'project_row.dart';

/// SPEC.md §19, §38: one panel, the same row HOME uses, plus the lead line —
/// the list is the same language, it just stops truncating.
class ProjectsScreen extends ConsumerWidget {
  const ProjectsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projects = ref.watch(projectSummariesProvider);

    return ScreenScaffold(
      title: 'PROJECTS',
      children: [
        Panel(
          title: 'ALL PROJECTS',
          affordance: PanelAffordance(
            '${projects.valueOrNull?.length ?? 0}',
            showIcon: false,
          ),
          bodyPadding: panelRowsPadding,
          child: AsyncSection(
            value: projects,
            empty: 'no projects',
            builder: (items) => ListRowGroup(
              children: [
                for (final project in items)
                  ProjectRow(
                    project: project,
                    showLead: true,
                    onTap: () => openProjectDetail(context, project.projectId),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
