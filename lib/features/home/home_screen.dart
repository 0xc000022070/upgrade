import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/formatting.dart';
import '../../application/navigation.dart';
import '../../application/providers.dart';
import '../../data/views.dart';
import '../../design/colors.dart';
import '../../design/components/activity_row.dart';
import '../../design/components/list_row.dart';
import '../../design/components/panel.dart';
import '../../design/components/section.dart';
import '../../design/icons/hotline_icon.dart';
import '../../design/icons/hotline_icons.dart';
import '../../design/spacing.dart';
import '../projects/project_detail_screen.dart';
import '../projects/project_row.dart';
import '../screen_scaffold.dart';
import '../tasks/task_actions.dart';
import 'capture_bar.dart';

/// SPEC.md §37 for the content, §38 for the skin: what is next, what is moving,
/// what is stuck, what is loose, what changed — each one a bordered panel.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  static const _projectCap = 3;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nextAction = ref.watch(nextActionProvider);
    final projects = ref.watch(projectSummariesProvider);
    final blocked = ref.watch(blockedTasksProvider);
    final loose = ref.watch(looseTasksProvider);
    final recent = ref.watch(recentActivityProvider);

    final projectCount = projects.valueOrNull?.length ?? 0;
    final blockedCount = blocked.valueOrNull?.length ?? 0;

    void openProjects() => ref.read(navIndexProvider.notifier).state = 1;

    return Column(
      children: [
        Expanded(
          child: ScreenScaffold(
            title: 'TODAY',
            children: [
              PanelStack(
                children: [
                  Panel(
                    title: 'NEXT ACTION',
                    affordance: PanelAffordance(
                      nextAction.valueOrNull == null ? '0' : '1',
                      showIcon: false,
                    ),
                    bodyPadding: panelRowsPadding,
                    child: AsyncSection<NextAction?>(
                      value: nextAction,
                      empty: 'nothing queued',
                      isEmpty: (value) => value == null,
                      builder: (task) => _NextActionRow(task: task!),
                    ),
                  ),
                  Panel(
                    title: 'PROJECTS',
                    affordance: PanelAffordance('$projectCount  VIEW ALL'),
                    onHeaderTap: openProjects,
                    bodyPadding: panelRowsPadding,
                    child: AsyncSection(
                      value: projects,
                      empty: 'no projects',
                      builder: (items) => ListRowGroup(
                        ruled: false,
                        children: [
                          for (final project in items.take(_projectCap))
                            ProjectRow(
                              project: project,
                              onTap: () =>
                                  openProjectDetail(context, project.projectId),
                            ),
                        ],
                      ),
                    ),
                  ),
                  Panel(
                    title: 'BLOCKED',
                    affordance: PanelAffordance(
                      '$blockedCount',
                      showIcon: false,
                      color: blockedCount == 0 ? null : HotlineColors.warning,
                    ),
                    bodyPadding: panelRowsPadding,
                    child: AsyncSection(
                      value: blocked,
                      empty: 'nothing blocked',
                      builder: (items) => ListRowGroup(
                        children: [
                          for (final task in items)
                            ListRow(
                              leading: const HotlineIcon(
                                HotlineIcons.blocked,
                                size: IconSizes.glyph,
                                color: HotlineColors.warning,
                              ),
                              title: task.title,
                              subtitle: task.reason,
                              subtitleColor: HotlineColors.warning,
                              caption: task.projectName,
                            ),
                        ],
                      ),
                    ),
                  ),
                  Panel(
                    title: 'LOOSE',
                    affordance: PanelAffordance(
                      '${loose.valueOrNull?.length ?? 0}',
                      showIcon: false,
                    ),
                    bodyPadding: panelRowsPadding,
                    child: AsyncSection(
                      value: loose,
                      empty: 'nothing loose',
                      builder: (items) => ListRowGroup(
                        children: [
                          for (final task in items)
                            ListRow(
                              title: task.title,
                              value: relativeAge(task.createdAt),
                              onLongPress: () =>
                                  showTaskActions(context, ref, task),
                            ),
                        ],
                      ),
                    ),
                  ),
                  Panel(
                    title: 'RECENT',
                    affordance: PanelAffordance(
                      '${recent.valueOrNull?.length ?? 0}',
                      showIcon: false,
                    ),
                    child: AsyncSection(
                      value: recent,
                      empty: 'no activity yet',
                      builder: (items) => Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final entry in items)
                            ActivityRow(
                              entry: entry,
                              timeLabel: relativeAge(entry.createdAt),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const CaptureBar(),
      ],
    );
  }
}

/// The one row on HOME that is not a list item: §35 asks the primary action to
/// be findable in one second, so it takes the accent arrow and the 13px title.
class _NextActionRow extends StatelessWidget {
  const _NextActionRow({required this.task});

  final NextAction task;

  @override
  Widget build(BuildContext context) {
    // §37: a row the screen picked is labelled as a suggestion, so it is never
    // mistaken for a decision the user already made.
    final subtitle = task.suggested
        ? [
            if (task.projectName != null) task.projectName!,
            'suggested',
          ].join('  ·  ')
        : task.projectName;
    return ListRow(
      leading: const HotlineIcon(
        HotlineIcons.forward,
        size: IconSizes.glyph,
        color: HotlineColors.accent,
      ),
      title: task.title,
      subtitle: subtitle,
      lead: true,
      decode: true,
    );
  }
}
