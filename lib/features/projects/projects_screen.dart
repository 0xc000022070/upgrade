import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers.dart';
import '../../design/components/list_row.dart';
import '../../design/components/panel.dart';
import '../../design/components/section.dart';
import '../../design/spacing.dart';
import '../../design/icons/hotline_icons.dart';
import '../screen_scaffold.dart';
import 'project_detail_screen.dart';
import 'project_form_screen.dart';
import 'project_row.dart';

/// One panel, the same row HOME uses, plus the lead line —
/// the list is the same language, it just stops truncating. Under it is the
/// folded ARCHIVED panel.
class ProjectsScreen extends ConsumerStatefulWidget {
  const ProjectsScreen({super.key});

  @override
  ConsumerState<ProjectsScreen> createState() => _ProjectsScreenState();
}

class _ProjectsScreenState extends ConsumerState<ProjectsScreen> {
  bool _showArchived = false;

  @override
  Widget build(BuildContext context) {
    final projects = ref.watch(projectSummariesProvider);
    final archived =
        ref.watch(archivedProjectSummariesProvider).valueOrNull ?? const [];

    return ScreenScaffold(
      title: 'PROJECTS',
      children: [
        PanelStack(
          children: [
            Panel(
              title: 'ALL PROJECTS',
              // The create affordance sits on the strip of the panel
              // it creates into, and this is the only one left: HOME has
              // no PROJECTS strip to carry a second.
              affordance: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  PanelAffordance(
                    '${projects.valueOrNull?.length ?? 0}',
                    showIcon: false,
                  ),
                  const SizedBox(width: Spacing.lg),
                  PanelAffordance(
                    'NEW',
                    icon: HotlineIcons.add,
                    onTap: () => openProjectForm(context),
                  ),
                ],
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
                        onTap: () =>
                            openProjectDetail(context, project.projectId),
                      ),
                  ],
                ),
              ),
            ),
            // Archived work is kept and folded away, the way DONE is
            // folded. With nothing archived the panel is not a line of chrome.
            if (archived.isNotEmpty)
              Panel(
                title: 'ARCHIVED',
                affordance: PanelAffordance(
                  '${archived.length}',
                  icon: _showArchived
                      ? HotlineIcons.collapse
                      : HotlineIcons.expand,
                ),
                onHeaderTap: () =>
                    setState(() => _showArchived = !_showArchived),
                bodyPadding: panelRowsPadding,
                child: !_showArchived
                    ? null
                    : ListRowGroup(
                        children: [
                          for (final project in archived)
                            ProjectRow(
                              project: project,
                              dim: true,
                              onTap: () =>
                                  openProjectDetail(context, project.projectId),
                            ),
                        ],
                      ),
              ),
          ],
        ),
      ],
    );
  }
}
