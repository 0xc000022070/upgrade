import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/agents.dart';
import '../../application/drop_selection.dart';
import '../../application/navigation.dart';
import '../../application/providers.dart';
import '../../data/views.dart';
import '../../design/colors.dart';
import '../../design/components/list_row.dart';
import '../../design/components/panel.dart';
import '../../design/components/section.dart';
import '../../design/icons/hotline_icon.dart';
import '../../design/icons/hotline_icons.dart';
import '../../design/spacing.dart';
import '../../design/typography.dart';
import '../projects/project_detail_screen.dart';
import '../projects/project_form_screen.dart';
import '../projects/project_row.dart';
import '../screen_scaffold.dart';
import '../settings/settings_screen.dart';
import '../tasks/drops_panel.dart';
import '../tasks/item_sheet.dart';
import 'agents_panel.dart';
import 'capture_bar.dart';

/// SPEC.md §39.3 for the content, §38 for the skin. Three panels: what is
/// flagged, what is moving, what has not been filed yet. BLOCKED and RECENT are
/// gone — a blocked item still says so on its own row wherever it lives, and
/// the activity stream is still written, just not displayed.
///
/// SPEC.md §39.18: the PROJECTS panel lists roots. A child is somewhere inside
/// one of these three rows, and its work is already counted in that row's
/// number, so putting it on Home too would say the same thing twice.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  /// The tab this screen is, which is what decides whether it is on screen.
  static const navIndex = 0;

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  static const _projectCap = 3;

  /// Captured while the element is alive. `ref` throws once dispose runs, and
  /// the flag has to be put down on the way out or a Home that is gone leaves
  /// the poller running.
  late final _visible = ref.read(homeAgentsVisibleProvider.notifier);

  @override
  void initState() {
    super.initState();
    // §39.20: the panel polls only while Home is in front. Mounting is not the
    // signal — the shell keeps every tab mounted in an IndexedStack — so the
    // selected index is, and the first sync waits for the frame that is
    // building right now to finish.
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncVisible());
  }

  @override
  void dispose() {
    _visible.state = false;
    super.dispose();
  }

  void _syncVisible() {
    if (!mounted) return;
    _visible.state = ref.read(navIndexProvider) == HomeScreen.navIndex;
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(navIndexProvider, (_, _) => _syncVisible());
    final nextAction = ref.watch(nextActionProvider);
    final projects = ref.watch(projectSummariesProvider);
    final drops = ref.watch(dropsProvider);

    final selecting = ref
        .watch(dropSelectionProvider)
        .ownedBy(DropSelection.homeScope);

    final projectCount = projects.valueOrNull?.length ?? 0;
    final next = nextAction.valueOrNull;

    void openProjects() => ref.read(navIndexProvider.notifier).state = 1;

    return Column(
      children: [
        Expanded(
          child: ScreenScaffold(
            // §39.20: `TODAY_` is gone. The breadcrumb and its SYS door stay.

            // §39.16's door. Text only, in the slot a project's EDIT uses: a
            // glyph for it would be a new icon, and icons are not this side's
            // to invent.
            breadcrumbTrailing: PanelAffordance(
              'SYS',
              showIcon: false,
              onTap: () => openSettings(context),
            ),
            children: [
              PanelStack(
                children: [
                  // §39.20's order: AGENTS first, then NEXT ACTION, PROJECTS
                  // and DROPS. BLOCKED and RECENT are still §39.3's — gone.
                  const AgentsPanel(),
                  // §39.3: no suggestion fallback, so with nothing flagged
                  // there is no panel. An empty NEXT ACTION frame would be the
                  // screen asking a question it cannot answer.
                  if (next != null)
                    Panel(
                      title: 'NEXT ACTION',
                      affordance: const PanelAffordance('1', showIcon: false),
                      bodyPadding: panelRowsPadding,
                      child: _NextActionRow(task: next),
                    ),
                  // §39.2: the create affordance sits on the header strip of
                  // the panel it creates into. It keeps its own tap target next
                  // to the count, so the strip's own tap still means VIEW ALL.
                  Panel(
                    title: 'PROJECTS',
                    affordance: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        PanelAffordance('$projectCount  VIEW ALL'),
                        const SizedBox(width: Spacing.lg),
                        PanelAffordance(
                          'NEW',
                          icon: HotlineIcons.add,
                          onTap: () => openProjectForm(context),
                        ),
                      ],
                    ),
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
                          // §39.18: the cap says how much it is hiding. The
                          // strip's count says how many there are; this says
                          // that the list on screen is not all of them.
                          if (items.length > _projectCap)
                            _MoreRow(
                              count: items.length - _projectCap,
                              onTap: openProjects,
                            ),
                        ],
                      ),
                    ),
                  ),
                  DropsPanel(scope: DropSelection.homeScope, drops: drops),
                ],
              ),
            ],
          ),
        ),
        // §39.13: the capture bar stays where it is while the mode is on and
        // does nothing. The verbs are on the panel's own strip, so the bottom
        // of the screen has no second answer to what a tap means.
        IgnorePointer(ignoring: selecting, child: const CaptureBar()),
      ],
    );
  }
}

/// §39.18's `+n more`, the last row of a capped panel.
class _MoreRow extends StatelessWidget {
  const _MoreRow({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: TapTargets.minHeight,
        alignment: Alignment.centerLeft,
        child: Text('+$count MORE', style: HotlineText.label),
      ),
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
    return ListRow(
      leading: const HotlineIcon(
        HotlineIcons.forward,
        size: IconSizes.glyph,
        color: HotlineColors.accent,
      ),
      title: task.title,
      subtitle: task.projectName,
      lead: true,
      decode: true,
      // §39.4: every row opens the quick view, and this one most of all — a
      // flagged item nothing responds to is the mock the user complained about.
      onTap: () => openItemSheet(context, task.taskId),
      onLongPress: () => openItemSheet(context, task.taskId),
    );
  }
}
