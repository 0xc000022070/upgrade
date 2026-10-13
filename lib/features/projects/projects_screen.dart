import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/providers.dart';
import 'package:upgrade/application/native_plugins.dart';
import 'package:upgrade/design/components/list_row.dart';
import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/design/components/section.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/design/icons/upgrade_icons.dart';
import 'package:upgrade/features/screen_scaffold.dart';
import 'package:upgrade/features/projects/project_detail_screen.dart';
import 'package:upgrade/features/projects/project_form_screen.dart';
import 'package:upgrade/features/projects/project_row.dart';

class ProjectsScreen extends ConsumerStatefulWidget {
  const ProjectsScreen({super.key});

  @override
  ConsumerState<ProjectsScreen> createState() => _ProjectsScreenState();
}

class _ProjectsScreenState extends ConsumerState<ProjectsScreen> {
  bool _showArchived = false;
  String? _selected;
  bool _wide = false;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _wide = constraints.maxWidth >= 840;
        if (!_wide) {
          return ScreenScaffold(title: 'PROJECTS', children: [_board()]);
        }
        final projects = ref.watch(projectSummariesProvider).valueOrNull;
        final allProjects = ref.watch(projectsProvider).valueOrNull;
        final selectionExists =
            _selected != null &&
            (allProjects == null ||
                allProjects.any((project) => project.id == _selected));
        final selected =
            (selectionExists ? _selected : null) ??
            (projects?.isNotEmpty == true ? projects!.first.projectId : null);
        return Row(
          children: [
            SizedBox(
              width: 300,
              child: ScreenScaffold(title: 'PROJECTS', children: [_board()]),
            ),
            Container(width: 1, color: context.tokens.borderNormal),
            Expanded(
              child: selected == null
                  ? Center(
                      child: Text(
                        'Choose or create a project',
                        style: context.tokens.rowTitle,
                      ),
                    )
                  : inheritPluginScope(
                      context,
                      ProjectDetailScreen(
                        key: ValueKey(selected),
                        projectId: selected,
                        onProjectSelected: (id) =>
                            setState(() => _selected = id),
                      ),
                      surface: 'project.detail',
                    ),
            ),
          ],
        );
      },
    );
  }

  void _open(String id) {
    if (_wide) {
      setState(() => _selected = id);
    } else {
      openProjectDetail(context, id);
    }
  }

  Widget _board() {
    final projects = ref.watch(projectSummariesProvider);
    final archived =
        ref.watch(archivedProjectSummariesProvider).valueOrNull ?? const [];

    return PanelStack(
      children: [
        Panel(
          title: 'ALL PROJECTS',
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
                icon: UpgradeIcons.add,
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
                    onTap: () => _open(project.projectId),
                  ),
              ],
            ),
          ),
        ),
        if (archived.isNotEmpty)
          Panel(
            title: 'ARCHIVED',
            affordance: PanelAffordance(
              '${archived.length}',
              icon: _showArchived ? UpgradeIcons.collapse : UpgradeIcons.expand,
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
                          onTap: () => _open(project.projectId),
                        ),
                    ],
                  ),
          ),
      ],
    );
  }
}
