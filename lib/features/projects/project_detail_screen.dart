import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/drop_selection.dart';
import '../../application/formatting.dart';
import '../../application/navigation.dart';
import '../../application/providers.dart';
import '../../data/database.dart';
import '../../data/enums.dart';
import '../../data/views.dart';
import '../../design/colors.dart';
import '../../design/components/action_block.dart';
import '../../design/components/list_row.dart';
import '../../design/components/panel.dart';
import '../../design/components/panel_sheet.dart';
import '../../design/components/section.dart';
import '../../design/effects/glitch.dart';
import '../../design/icons/hotline_icon.dart';
import '../../design/icons/hotline_icons.dart';
import '../../design/spacing.dart';
import '../../design/sprite.dart';
import '../../design/typography.dart';
import '../home/capture_bar.dart';
import '../screen_scaffold.dart';
import '../tasks/drops_panel.dart';
import '../tasks/selection_bar.dart';
import '../tasks/task_row.dart';
import 'project_form_screen.dart';
import 'project_row.dart';
import '../../app/static_surface.dart';

void openProjectDetail(BuildContext context, String projectId) {
  Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(
      // A child opens on top of its parent, and a breadcrumb segment
      // pops back to the ancestor it names. The name is how the stack is
      // searched for that route — the alternative is counting pops, which is
      // wrong the moment anything else is pushed in between.
      settings: RouteSettings(name: projectRouteName(projectId)),
      builder: (_) => ProjectDetailScreen(projectId: projectId),
    ),
  );
}

String projectRouteName(String projectId) => 'project/$projectId';

/// A hero card carrying the project's one number, the objective when there is
/// one, a panel per goal, the project's own DROPS, then notes.
class ProjectDetailScreen extends ConsumerStatefulWidget {
  const ProjectDetailScreen({super.key, required this.projectId});

  final String projectId;

  @override
  ConsumerState<ProjectDetailScreen> createState() =>
      _ProjectDetailScreenState();
}

class _ProjectDetailScreenState extends ConsumerState<ProjectDetailScreen> {
  /// The new-goal editor is a panel of its own at the top of the goal
  /// list; renaming turns the goal's own panel into the same editor. Only one
  /// of the two is ever open, so they share the field.
  bool _creating = false;
  String? _renaming;

  /// Project detail entry is one of the two screen-level events. It is bound
  /// to the hero rather than to the whole screen — the tear is panel scale, and
  /// a whole route tearing on arrival would read as a transition.
  final _entry = GlitchController();
  bool _entered = false;
  Animation<double>? _push;

  /// The capture bar pinned here has no nav icon to land on, so the
  /// DROPS panel the row lands in takes the event. Owned by the screen because
  /// the bar that fires it and the panel that plays it are siblings.
  final _landing = GlitchController();

  @override
  void dispose() {
    _push?.removeStatusListener(_onPush);
    _entry.dispose();
    _landing.dispose();
    super.dispose();
  }

  /// The route pushes before the project stream has anything, so the hero is
  /// absent for the first frames. Firing on initState would spend the event on
  /// an empty header; this waits for the frame the hero actually appears, and
  /// then for the push to be over.
  void _fireOnEntry() {
    if (_entered || MediaQuery.disableAnimationsOf(context)) return;
    _entered = true;
    final push = ModalRoute.of(context)?.animation;
    // The entry event has to land on the arrived screen. Fired mid-push it
    // paints over a cross-fade of two routes, and a displaced block there
    // reads as the transition tearing rather than as this header coming
    // apart: on device the first three of the four torn frames were unusable
    // for that reason.
    if (push != null && push.status != AnimationStatus.completed) {
      _push = push..addStatusListener(_onPush);
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _entry.fire();
    });
  }

  void _onPush(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    _push?.removeStatusListener(_onPush);
    _push = null;
    if (mounted) _entry.fire();
  }

  /// `PROJECTS` pops out of the whole project stack and lands on the
  /// tab. `popUntil(isFirst)` is the shell route the tabs live in.
  void _popToProjectsTab() {
    Navigator.of(context, rootNavigator: true).popUntil((r) => r.isFirst);
    ref.read(navIndexProvider.notifier).state = 1;
  }

  /// An ancestor segment pops back to that ancestor's own screen. The
  /// route is found by name rather than by counting pops, and `isFirst` is the
  /// floor — a stack that somehow does not hold the ancestor unwinds to the
  /// shell instead of unwinding forever.
  void _popTo(String projectId) {
    final name = projectRouteName(projectId);
    // The ancestor is not always on the stack: move a project under a parent
    // the user never walked into and its crumb names a screen that was never
    // pushed. Unwinding to `isFirst` then dropped them on HOME, which is
    // neither the ancestor nor the tab. The predicate records
    // whether the name was ever on top, so the miss can land on the tab that
    // does hold the ancestor.
    var found = false;
    Navigator.of(context, rootNavigator: true).popUntil((route) {
      found = found || route.settings.name == name;
      return found || route.isFirst;
    });
    if (!found) ref.read(navIndexProvider.notifier).state = 1;
  }

  Future<void> _archive(Project project) async {
    // Archiving asks once; unarchiving is the undo and asks nothing.
    if (project.status == ProjectStatus.archived) {
      await ref.read(projectRepositoryProvider).unarchive(project.id);
      return;
    }
    final confirmed = await confirmSheet(
      context,
      title: 'ARCHIVE PROJECT?',
      confirmLabel: 'ARCHIVE',
    );
    if (!confirmed) return;
    await ref.read(projectRepositoryProvider).archive(project.id);
  }

  Future<void> _goalActions(GoalSummary goal) async {
    final action = await showPanelSheet<_GoalAction>(
      context,
      title: goal.title.toUpperCase(),
      builder: (context) => PanelSheetBody(
        title: goal.title.toUpperCase(),
        children: [
          Row(
            children: [
              Expanded(
                child: ActionBlock(
                  label: 'RENAME',
                  onTap: () => Navigator.of(context).pop(_GoalAction.rename),
                ),
              ),
              const SizedBox(width: Spacing.md),
              Expanded(
                child: ActionBlock(
                  label: 'DELETE',
                  tone: HotlineColors.warning,
                  onTap: () => Navigator.of(context).pop(_GoalAction.delete),
                ),
              ),
            ],
          ),
        ],
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _GoalAction.rename:
        setState(() {
          _creating = false;
          _renaming = goal.goalId;
        });
      case _GoalAction.delete:
        // The goal goes, its items fall back to the project's DROPS —
        // so this destroys a heading, never work.
        final confirmed = await confirmSheet(
          context,
          title: 'DELETE GOAL?',
          confirmLabel: 'DELETE',
        );
        if (!confirmed) return;
        await ref.read(goalRepositoryProvider).delete(goal.goalId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final project = ref.watch(projectProvider(widget.projectId)).valueOrNull;
    if (project != null) _fireOnEntry();
    final goals = ref.watch(projectGoalsProvider(widget.projectId));
    final drops = ref.watch(projectDropsProvider(widget.projectId));
    final notes = ref.watch(projectNotesProvider(widget.projectId));
    final children = ref.watch(projectChildrenProvider(widget.projectId));
    final summary = ref.watch(projectSummaryProvider(widget.projectId));
    final ancestors =
        ref.watch(projectAncestorsProvider(widget.projectId)).valueOrNull ??
        const <ProjectCrumb>[];

    final rows = goals.valueOrNull ?? const <GoalSummary>[];
    final kids = children.valueOrNull ?? const <ProjectSummary>[];
    final archived = project?.status == ProjectStatus.archived;
    // A project is hidden when it or any ancestor is archived. Under a
    // hidden ancestor the project keeps its own status — that is what makes
    // unarchiving the parent restore the subtree as it was — so it is dim and
    // its own UNARCHIVE is absent rather than offered and inert.
    final ancestorArchived = ancestors.any(
      (crumb) => crumb.status == ProjectStatus.archived,
    );
    final hidden = archived || ancestorArchived;
    final hasObjective = (project?.objective ?? '').trim().isNotEmpty;
    final selecting = ref
        .watch(dropSelectionProvider)
        .ownedBy(widget.projectId);

    return Scaffold(
      bottomNavigationBar: project == null || hidden
          ? null
          // A Scaffold insets its body for the keyboard and leaves the bottom
          // slot where it is, so on device the field and the CAPTURE block went
          // under the IME and the project was captured into blind — Home mounts
          // the bar inside its own body and never had this. The inset is added
          // here rather than by moving the mount, so the bar keeps its slot and
          // the panels keep scrolling under it.
          : Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.viewInsetsOf(context).bottom,
              ),
              // The slot is the selection bar's while this project's
              // DROPS panel owns the mode, and the capture bar's the rest of
              // the time. Same frame either way, so the panels do not move.
              child: selecting
                  ? SelectionBar(scope: widget.projectId)
                  : CaptureBar(
                      scope: widget.projectId,
                      fixedTarget: ItemTarget.project(widget.projectId),
                      landing: _landing,
                    ),
            ),
      body: StaticSurface(
        child: ScreenScaffold(
          title: project?.name.toUpperCase() ?? 'PROJECT',
          // The path down to this project, self excluded — the name is
          // already the title. Every segment pops the stack back to what it
          // names, and `PROJECTS` pops all the way out to the tab.
          breadcrumbSegments: [
            CrumbSegment('PROJECTS', onTap: () => _popToProjectsTab()),
            for (final crumb in ancestors)
              CrumbSegment(
                crumb.name.toUpperCase(),
                onTap: () => _popTo(crumb.id),
              ),
          ],
          // EDIT and ARCHIVE ride the breadcrumb row, not the
          // title row — the title is the project's name and the widest line on
          // the screen.
          breadcrumbTrailing: project == null
              ? null
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    PanelAffordance(
                      'EDIT',
                      icon: HotlineIcons.edit,
                      onTap: () => openProjectForm(context, project: project),
                    ),
                    // Nothing to offer while an ancestor is archived —
                    // unarchiving here would not bring the project back.
                    if (!ancestorArchived) ...[
                      const SizedBox(width: Spacing.lg),
                      PanelAffordance(
                        archived ? 'UNARCHIVE' : 'ARCHIVE',
                        showIcon: false,
                        onTap: () => _archive(project),
                      ),
                    ],
                  ],
                ),
          header: project == null
              ? null
              : Padding(
                  padding: const EdgeInsets.only(bottom: Spacing.panelGap),
                  child: GlitchPanel(
                    controller: _entry,
                    // The number under the title counts the subtree.
                    // A parent whose work is all in its children reads 0 OF 0
                    // otherwise, which is the one thing the aggregate exists to
                    // stop it saying.
                    child: _HeroCard(
                      project: project,
                      doneCount: summary.valueOrNull?.doneCount ?? 0,
                      totalCount: summary.valueOrNull?.totalCount ?? 0,
                    ),
                  ),
                ),
          children: [
            PanelStack(
              children: [
                if (project != null) ...[
                  // A status panel that always says ACTIVE is a row that never
                  // carries information. It appears only when the project is
                  // off its normal track.
                  if (project.status != ProjectStatus.active)
                    Panel(
                      title: 'STATUS',
                      affordance: PanelAffordance(
                        project.status.name.toUpperCase(),
                        showIcon: false,
                        color: HotlineColors.warning,
                      ),
                    ),
                  // An objective is optional, and an OBJECTIVE panel
                  // with nothing in it is a header explaining that there is no
                  // header.
                  if (hasObjective)
                    Panel(
                      title: 'OBJECTIVE',
                      child: Text(
                        project.objective,
                        style: HotlineText.rowTitle,
                        maxLines: 3,
                      ),
                    ),
                  // The immediate children, after the objective and
                  // before the goals. Absent on a childless root — there is no
                  // hierarchy there to be discoverable — and present but empty
                  // on a childless child, where the depth is the point.
                  if (kids.isNotEmpty || project.parentId != null)
                    Panel(
                      title: 'PROJECTS',
                      affordance: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          PanelAffordance('${kids.length}', showIcon: false),
                          if (!hidden) ...[
                            const SizedBox(width: Spacing.lg),
                            PanelAffordance(
                              'NEW',
                              icon: HotlineIcons.add,
                              onTap: () => openProjectForm(
                                context,
                                parentId: widget.projectId,
                              ),
                            ),
                          ],
                        ],
                      ),
                      bodyPadding: panelRowsPadding,
                      child: AsyncSection(
                        value: children,
                        empty: 'nothing under this project',
                        builder: (items) => ListRowGroup(
                          children: [
                            for (final child in items)
                              ProjectRow(
                                key: ValueKey(child.projectId),
                                project: child,
                                dim: hidden,
                                onTap: () =>
                                    openProjectDetail(context, child.projectId),
                              ),
                          ],
                        ),
                      ),
                    ),
                ],
                // `NEW +` lives on the GOALS strip; the goals themselves
                // are panels under it, each its own list.
                Panel(
                  title: 'GOALS',
                  affordance: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      PanelAffordance('${rows.length}', showIcon: false),
                      const SizedBox(width: Spacing.lg),
                      PanelAffordance(
                        'NEW',
                        icon: HotlineIcons.add,
                        onTap: () => setState(() {
                          _renaming = null;
                          _creating = true;
                        }),
                      ),
                    ],
                  ),
                ),
                if (_creating)
                  _GoalEditor(
                    key: const ValueKey('new-goal'),
                    hint: 'what it is for',
                    onCancel: () => setState(() => _creating = false),
                    onSubmit: (title) async {
                      setState(() => _creating = false);
                      await ref
                          .read(goalRepositoryProvider)
                          .create(projectId: widget.projectId, title: title);
                    },
                  ),
                for (final goal in rows)
                  if (_renaming == goal.goalId)
                    _GoalEditor(
                      key: ValueKey('rename-${goal.goalId}'),
                      initial: goal.title,
                      onCancel: () => setState(() => _renaming = null),
                      onSubmit: (title) async {
                        setState(() => _renaming = null);
                        await ref
                            .read(goalRepositoryProvider)
                            .rename(goal.goalId, title);
                      },
                    )
                  else
                    _GoalPanel(
                      key: ValueKey(goal.goalId),
                      goal: goal,
                      onHeaderLongPress: () => _goalActions(goal),
                    ),
                // Filed to the project, under no goal. Same panel HOME uses,
                // so the multi-select comes with it — but the rows are tasks,
                // so they carry their state.
                DropsPanel(
                  scope: widget.projectId,
                  drops: drops,
                  empty: 'nothing unfiled here',
                  stateful: true,
                  landing: _landing,
                ),
                Panel(
                  title: 'NOTES',
                  affordance: PanelAffordance(
                    '${notes.valueOrNull?.length ?? 0}',
                    showIcon: false,
                  ),
                  bodyPadding: panelRowsPadding,
                  child: AsyncSection(
                    value: notes,
                    empty: 'no notes',
                    builder: (items) => ListRowGroup(
                      children: [
                        for (final note in items) _NoteRow(note: note),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

enum _GoalAction { rename, delete }

/// One panel per goal, its progress on the strip, its items inside. A
/// done item stays where it is and goes dim — under a goal there is nowhere
/// else for it to be, so nothing has to hold it in place while a glitch plays.
class _GoalPanel extends ConsumerWidget {
  const _GoalPanel({
    super.key,
    required this.goal,
    required this.onHeaderLongPress,
  });

  final GoalSummary goal;
  final VoidCallback onHeaderLongPress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(goalTasksProvider(goal.goalId));
    return Panel(
      title: goal.title.toUpperCase(),
      affordance: PanelAffordance(
        '${goal.doneCount}/${goal.totalCount}',
        showIcon: false,
      ),
      // Rename and delete hang off the goal's own strip; nothing else on
      // the screen would carry them without inventing a menu.
      onHeaderLongPress: onHeaderLongPress,
      bodyPadding: panelRowsPadding,
      child: AsyncSection(
        value: tasks,
        empty: 'nothing under this goal',
        builder: (items) => ListRowGroup(
          children: [
            for (final task in items)
              TaskRow(key: ValueKey(task.id), task: task),
          ],
        ),
      ),
    );
  }
}

/// The single-line editor a goal is created and renamed in. Submit is
/// enter; the strip's `x` is the way out, and an empty submit is one too.
class _GoalEditor extends StatefulWidget {
  const _GoalEditor({
    super.key,
    required this.onSubmit,
    required this.onCancel,
    this.initial,
    this.hint,
  });

  final ValueChanged<String> onSubmit;
  final VoidCallback onCancel;
  final String? initial;
  final String? hint;

  @override
  State<_GoalEditor> createState() => _GoalEditorState();
}

class _GoalEditorState extends State<_GoalEditor> {
  late final _field = TextEditingController(text: widget.initial ?? '');

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _submit() {
    final title = _field.text.trim();
    if (title.isEmpty) {
      widget.onCancel();
      return;
    }
    widget.onSubmit(title);
  }

  @override
  Widget build(BuildContext context) {
    return Panel(
      title: widget.initial == null ? 'NEW GOAL' : 'RENAME GOAL',
      affordance: PanelAffordance(
        'CANCEL',
        showIcon: false,
        onTap: widget.onCancel,
      ),
      child: TextField(
        controller: _field,
        autofocus: true,
        style: HotlineText.rowTitleLead,
        maxLines: 1,
        cursorColor: HotlineColors.accent,
        cursorWidth: 2,
        cursorRadius: Radius.zero,
        textCapitalization: TextCapitalization.none,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(),
        decoration: InputDecoration(
          isDense: true,
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: Spacing.sm),
          hintText: widget.hint,
          hintStyle: HotlineText.rowSubtitle,
        ),
      ),
    );
  }
}

/// The card that opens the screen — the project's own mark at hero size
/// and what it is. The name is the screen title, so repeating it here would
/// spend the widest line in the app on a string already read two lines above.
///
/// Progress lives here: the OBJECTIVE panel used to carry the number and it is
/// gone whenever the objective is, but the number is not optional.
class _HeroCard extends StatelessWidget {
  const _HeroCard({
    required this.project,
    required this.doneCount,
    required this.totalCount,
  });

  final Project project;
  final int doneCount;
  final int totalCount;

  @override
  Widget build(BuildContext context) {
    final ratio = totalCount == 0 ? 0.0 : doneCount / totalCount;
    return Panel(
      bodyPadding: const EdgeInsets.all(Spacing.lg),
      child: Row(
        children: [
          // The mascot takes the summary's icon position, one static
          // idle frame. Not the ticker — the card is on screen for as long as
          // the project is open, and a breathing skeleton next to the one big
          // number would be the thing the eye tracks.
          const Sprite(state: 'idle', scale: 2, frame: 0),
          const SizedBox(width: Spacing.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (project.description.trim().isNotEmpty) ...[
                  Text(
                    project.description,
                    // With the name gone the description is the whole card, so
                    // it takes the lead row size rather than the subtitle's.
                    style: HotlineText.rowTitleLead.copyWith(
                      color: HotlineColors.textSecondary,
                    ),
                    maxLines: 3,
                  ),
                  const SizedBox(height: RowMetrics.lineGap),
                ],
                Text(
                  '$doneCount OF $totalCount TASKS',
                  style: HotlineText.label,
                ),
              ],
            ),
          ),
          const SizedBox(width: Spacing.lg),
          Text('${(ratio * 100).round()}%', style: HotlineText.heroPercent),
        ],
      ),
    );
  }
}

class _NoteRow extends StatelessWidget {
  const _NoteRow({required this.note});

  final Note note;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: RowMetrics.padding),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: HotlineIcon(
              HotlineIcons.note,
              size: IconSizes.glyph,
              color: HotlineColors.textDisabled,
            ),
          ),
          const SizedBox(width: Spacing.lg),
          Expanded(child: Text(note.content, style: HotlineText.noteBody)),
          const SizedBox(width: Spacing.lg),
          Text(relativeAge(note.createdAt), style: HotlineText.label),
        ],
      ),
    );
  }
}
