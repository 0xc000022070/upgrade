import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers.dart';
import '../../design/components/list_row.dart';
import '../../design/components/panel.dart';
import '../../design/components/section.dart';
import '../../design/components/segment_switch.dart';
import '../../design/spacing.dart';
import '../../design/icons/dazzle_icons.dart';
import '../screen_scaffold.dart';
import 'code_list.dart';
import 'project_detail_screen.dart';
import 'project_form_screen.dart';
import 'project_row.dart';

/// Two lists under one title. BOARD is the projects: one panel, the same row
/// HOME uses, plus the lead line, with the folded ARCHIVED panel under it. CODE
/// is every registered directory on every host.
///
/// They are siblings and not a hierarchy — a directory with no project and a
/// project with no directory are both ordinary — which is why the switch is a
/// segment on one screen rather than two destinations in the nav.
///
/// The pick lives here and is not persisted: the screen opens on BOARD after a
/// cold start.
class ProjectsScreen extends ConsumerStatefulWidget {
  const ProjectsScreen({super.key});

  @override
  ConsumerState<ProjectsScreen> createState() => _ProjectsScreenState();
}

class _ProjectsScreenState extends ConsumerState<ProjectsScreen> {
  bool _showArchived = false;
  int _segment = 0;

  @override
  Widget build(BuildContext context) {
    return ScreenScaffold(
      title: 'PROJECTS',
      header: SegmentSwitch(
        labels: const ['BOARD', 'CODE'],
        currentIndex: _segment,
        onSelected: (index) => setState(() => _segment = index),
      ),
      children: [if (_segment == 1) const CodeList() else _board()],
    );
  }

  Widget _board() {
    final projects = ref.watch(projectSummariesProvider);
    final archived =
        ref.watch(archivedProjectSummariesProvider).valueOrNull ?? const [];

    return PanelStack(
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
                icon: DazzleIcons.add,
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
                    onTap: () => openProjectDetail(context, project.projectId),
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
                  ? DazzleIcons.collapse
                  : DazzleIcons.expand,
            ),
            onHeaderTap: () => setState(() => _showArchived = !_showArchived),
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
    );
  }
}
