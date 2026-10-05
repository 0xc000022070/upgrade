import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/drop_selection.dart';
import '../../application/formatting.dart';
import '../../application/navigation.dart';
import '../../application/native_plugins.dart';
import '../../application/providers.dart';
import '../../data/database.dart';
import '../../data/enums.dart';
import '../../data/repositories/path_repository.dart';
import '../../data/views.dart';
import '../../data/project_icons.dart';
import '../../design/tokens.dart';
import '../../design/components/action_block.dart';
import '../../design/components/action_sheet.dart';
import '../../design/components/ascii_mascot.dart';
import '../../design/components/list_row.dart';
import '../../design/components/panel.dart';
import '../../design/components/panel_sheet.dart';
import '../../design/components/picker_row.dart';
import '../../design/components/section.dart';
import '../../design/components/upgrade_field.dart';
import '../../design/effects/glitch.dart';
import '../../design/icons/upgrade_icon.dart';
import '../../design/icons/upgrade_icons.dart';
import '../../design/spacing.dart';
import '../code/workspace_sheet.dart';
import '../home/capture_bar.dart';
import '../hosts/hosts_screen.dart';
import '../screen_scaffold.dart';
import '../tasks/drops_panel.dart';
import '../tasks/selection_bar.dart';
import '../tasks/task_row.dart';
import 'project_form_screen.dart';
import 'project_row.dart';
import 'project_icon.dart';
import 'project_task_filter.dart';
import '../../app/static_surface.dart';

void openProjectDetail(BuildContext context, String projectId) {
  Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(
      settings: RouteSettings(name: projectRouteName(projectId)),
      builder: (_) => inheritPluginScope(
        context,
        ProjectDetailScreen(projectId: projectId),
        surface: 'project.detail',
      ),
    ),
  );
}

String projectRouteName(String projectId) => 'project/$projectId';

class ProjectDetailScreen extends ConsumerStatefulWidget {
  const ProjectDetailScreen({
    super.key,
    required this.projectId,
    this.onProjectSelected,
  });

  final String projectId;
  final ValueChanged<String>? onProjectSelected;

  @override
  ConsumerState<ProjectDetailScreen> createState() =>
      _ProjectDetailScreenState();
}

class _ProjectDetailScreenState extends ConsumerState<ProjectDetailScreen> {
  bool _creating = false;
  String? _renaming;
  final _search = TextEditingController();
  ProjectTaskFilter _filter = ProjectTaskFilter.open;

  final _entry = GlitchController();
  bool _entered = false;
  Animation<double>? _push;

  final _landing = GlitchController();

  @override
  void dispose() {
    _search.dispose();
    _push?.removeStatusListener(_onPush);
    _entry.dispose();
    _landing.dispose();
    super.dispose();
  }

  void _fireOnEntry() {
    if (_entered || MediaQuery.disableAnimationsOf(context)) return;
    _entered = true;
    final push = ModalRoute.of(context)?.animation;
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

  void _popToProjectsTab() {
    if (widget.onProjectSelected != null) return;
    Navigator.of(context, rootNavigator: true).popUntil((r) => r.isFirst);
    ref.read(navIndexProvider.notifier).state = 1;
  }

  void _popTo(String projectId) {
    if (widget.onProjectSelected case final select?) {
      select(projectId);
      return;
    }
    final name = projectRouteName(projectId);
    var found = false;
    Navigator.of(context, rootNavigator: true).popUntil((route) {
      found = found || route.settings.name == name;
      return found || route.isFirst;
    });
    if (!found) ref.read(navIndexProvider.notifier).state = 1;
  }

  Future<void> _archive(Project project) async {
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
                  tone: context.tokens.warning,
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
          : Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.viewInsetsOf(context).bottom,
              ),
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
          breadcrumbSegments: [
            CrumbSegment(
              'PROJECTS',
              onTap: widget.onProjectSelected == null
                  ? _popToProjectsTab
                  : null,
            ),
            for (final crumb in ancestors)
              CrumbSegment(
                crumb.name.toUpperCase(),
                onTap: () => _popTo(crumb.id),
              ),
          ],
          breadcrumbTrailing: project == null
              ? null
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    PanelAffordance(
                      'EDIT',
                      icon: UpgradeIcons.edit,
                      onTap: () => openProjectForm(
                        context,
                        project: project,
                        closeDetailOnDelete: widget.onProjectSelected == null,
                      ),
                    ),
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
                  if (project.status != ProjectStatus.active)
                    Panel(
                      title: 'STATUS',
                      affordance: PanelAffordance(
                        project.status.name.toUpperCase(),
                        showIcon: false,
                        color: context.tokens.warning,
                      ),
                    ),
                  if (hasObjective)
                    Panel(
                      title: 'OBJECTIVE',
                      child: Text(
                        project.objective,
                        style: context.tokens.rowTitle,
                        maxLines: 3,
                      ),
                    ),
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
                              icon: UpgradeIcons.add,
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
                                onTap: () => widget.onProjectSelected != null
                                    ? widget.onProjectSelected!(child.projectId)
                                    : openProjectDetail(
                                        context,
                                        child.projectId,
                                      ),
                              ),
                          ],
                        ),
                      ),
                    ),
                ],
                Panel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      UpgradeField(
                        key: const ValueKey('project-task-search'),
                        controller: _search,
                        hint: 'Search tasks',
                        semanticLabel: 'Search project tasks',
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: Spacing.md,
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                      Wrap(
                        spacing: Spacing.sm,
                        children: [
                          for (final filter in ProjectTaskFilter.values)
                            ChoiceChip(
                              label: Text(filter.name.toUpperCase()),
                              selected: _filter == filter,
                              onSelected: (_) =>
                                  setState(() => _filter = filter),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                Panel(
                  title: 'GOALS',
                  affordance: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      PanelAffordance('${rows.length}', showIcon: false),
                      const SizedBox(width: Spacing.lg),
                      PanelAffordance(
                        'NEW',
                        icon: UpgradeIcons.add,
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
                      filter: _filter,
                      query: _search.text,
                      onHeaderLongPress: () => _goalActions(goal),
                    ),
                DropsPanel(
                  scope: widget.projectId,
                  drops: drops.whenData(
                    (items) => items
                        .where((task) => _filter.matches(task, _search.text))
                        .toList(),
                  ),
                  empty: 'no ${_filter.name} drops match',
                  stateful: true,
                  landing: _landing,
                ),
                _CodePanel(projectId: widget.projectId),
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

class _CodePanel extends ConsumerWidget {
  const _CodePanel({required this.projectId});

  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final linked = ref.watch(projectWorkspacesProvider(projectId));
    return Panel(
      title: 'CODE',
      affordance: PanelAffordance(
        'LINK',
        icon: UpgradeIcons.add,
        onTap: () => _link(context, ref),
      ),
      bodyPadding: panelRowsPadding,
      child: AsyncSection(
        value: linked,
        empty: 'no directories linked',
        builder: (targets) => ListRowGroup(
          children: [
            for (final target in targets)
              ListRow(
                title: shortPathLabel(target.path.directory),
                value: target.host.name.toUpperCase(),
                onTap: () => openWorkspace(context, target.path, target.host),
                onLongPress: () => _unlink(context, ref, target),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _link(BuildContext context, WidgetRef ref) async {
    final repository = ref.read(pathRepositoryProvider);
    final all = await repository.watchTargets().first;
    final free = await repository.watchUnlinked().first;
    if (!context.mounted) return;
    final picked = await showPanelSheet<PathTarget>(
      context,
      title: 'LINK',
      builder: (context) => PanelSheetBody(
        title: 'LINK',
        children: [
          if (all.isEmpty)
            PickerRow(
              label: 'ADD A HOST',
              subtitle: 'NO WORKSPACES YET',
              onTap: () {
                Navigator.of(
                  context,
                  rootNavigator: true,
                ).popUntil((route) => route.isFirst);
                ref.read(navIndexProvider.notifier).state =
                    HostsScreen.navIndex;
              },
            )
          else if (free.isEmpty)
            const EmptyState('every directory is linked'),
          for (final target in free)
            PickerRow(
              label: shortPathLabel(target.path.directory),
              subtitle: target.host.name.toUpperCase(),
              onTap: () => Navigator.of(context).pop(target),
            ),
        ],
      ),
    );
    if (picked == null) return;
    await ref
        .read(pathRepositoryProvider)
        .setProject(picked.path.id, projectId);
  }

  Future<void> _unlink(
    BuildContext context,
    WidgetRef ref,
    PathTarget target,
  ) async {
    await showActionSheet(
      context,
      title: shortPathLabel(target.path.directory),
      actions: [
        SheetAction(
          'UNLINK',
          () =>
              ref.read(pathRepositoryProvider).setProject(target.path.id, null),
        ),
      ],
      recommendFirst: false,
    );
  }
}

class _GoalPanel extends ConsumerWidget {
  const _GoalPanel({
    super.key,
    required this.goal,
    required this.onHeaderLongPress,
    required this.filter,
    required this.query,
  });

  final GoalSummary goal;
  final VoidCallback onHeaderLongPress;
  final ProjectTaskFilter filter;
  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(goalTasksProvider(goal.goalId));
    return Panel(
      title: goal.title.toUpperCase(),
      affordance: PanelAffordance(
        '${goal.doneCount}/${goal.totalCount}',
        showIcon: false,
      ),
      onHeaderLongPress: onHeaderLongPress,
      bodyPadding: panelRowsPadding,
      child: AsyncSection(
        value: tasks.whenData(
          (items) =>
              items.where((task) => filter.matches(task, query)).toList(),
        ),
        empty: 'no ${filter.name} tasks match',
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
      child: UpgradeField(
        controller: _field,
        autofocus: true,
        style: context.tokens.rowTitleLead,
        hint: widget.hint,
        contentPadding: const EdgeInsets.symmetric(vertical: Spacing.sm),
        onSubmitted: (_) => _submit(),
      ),
    );
  }
}

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
    final icon = ProjectIconKind.fromId(project.iconId);
    return Panel(
      bodyPadding: const EdgeInsets.all(Spacing.lg),
      child: Row(
        children: [
          if (icon != null)
            ProjectIcon(icon, size: 48, color: context.tokens.accent)
          else
            AsciiMascot.compact(
              colour: context.tokens.textPrimary,
              accent: context.tokens.accent,
            ),
          const SizedBox(width: Spacing.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (project.description.trim().isNotEmpty) ...[
                  Text(
                    project.description,
                    style: context.tokens.rowTitleLead.copyWith(
                      color: context.tokens.textSecondary,
                    ),
                    maxLines: 3,
                  ),
                  const SizedBox(height: RowMetrics.lineGap),
                ],
                Text(
                  '$doneCount OF $totalCount TASKS',
                  style: context.tokens.label,
                ),
              ],
            ),
          ),
          const SizedBox(width: Spacing.lg),
          Text('${(ratio * 100).round()}%', style: context.tokens.heroPercent),
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
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: UpgradeIcon(
              UpgradeIcons.note,
              size: IconSizes.glyph,
              color: context.tokens.textDisabled,
            ),
          ),
          const SizedBox(width: Spacing.lg),
          Expanded(child: Text(note.content, style: context.tokens.noteBody)),
          const SizedBox(width: Spacing.lg),
          Text(relativeAge(note.createdAt), style: context.tokens.label),
        ],
      ),
    );
  }
}
