import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/formatting.dart';
import '../../application/providers.dart';
import '../../data/database.dart';
import '../../data/enums.dart';
import '../../design/colors.dart';
import '../../design/components/list_row.dart';
import '../../design/components/panel.dart';
import '../../design/components/section.dart';
import '../../design/components/static_background.dart';
import '../../design/effects/glitch.dart';
import '../../design/icons/hotline_icon.dart';
import '../../design/icons/hotline_icons.dart';
import '../../design/motion.dart';
import '../../design/spacing.dart';
import '../../design/typography.dart';
import '../screen_scaffold.dart';
import '../tasks/task_actions.dart';

void openProjectDetail(BuildContext context, String projectId) {
  Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(
      builder: (_) => ProjectDetailScreen(projectId: projectId),
    ),
  );
}

/// SPEC.md §37 for the content, §38.6 and the mocks for the shape: the project
/// names the screen, a hero card identifies it, a STATUS line and an OBJECTIVE
/// panel carry the one big number, then tasks and notes as panels.
class ProjectDetailScreen extends ConsumerStatefulWidget {
  const ProjectDetailScreen({super.key, required this.projectId});

  final String projectId;

  @override
  ConsumerState<ProjectDetailScreen> createState() =>
      _ProjectDetailScreenState();
}

class _ProjectDetailScreenState extends ConsumerState<ProjectDetailScreen> {
  bool _showDone = false;

  /// A toggled task leaves its group the moment the write lands, which takes
  /// the §16b glitch with it: the icon that exists to show the change is
  /// unmounted a frame after it starts. Rows named here keep the `done` value
  /// they had when the glitch fired, so the sequence plays where the user tapped
  /// and the row moves once it has settled. Only the placement waits; the write
  /// goes out immediately.
  final _settling = <String, bool>{};
  final _settleTimers = <String, Timer>{};

  void _holdForGlitch(String taskId, bool wasDone) {
    _settleTimers.remove(taskId)?.cancel();
    setState(() => _settling[taskId] = wasDone);
    _settleTimers[taskId] = Timer(Effects.glitchDuration, () {
      if (!mounted) return;
      setState(() {
        _settling.remove(taskId);
        _settleTimers.remove(taskId);
      });
    });
  }

  @override
  void dispose() {
    for (final timer in _settleTimers.values) {
      timer.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final project = ref.watch(projectProvider(widget.projectId)).valueOrNull;
    final tasks = ref.watch(projectTasksProvider(widget.projectId));
    final notes = ref.watch(projectNotesProvider(widget.projectId));

    bool isDone(Task task) => _settling[task.id] ?? task.done;

    final all = tasks.valueOrNull ?? const <Task>[];
    final done = all.where(isDone).toList();
    final open = all.where((task) => !isDone(task)).toList();

    return Scaffold(
      body: StaticBackgroundDriver(
        child: ScreenScaffold(
          title: project?.name.toUpperCase() ?? 'PROJECT',
          breadcrumb: '/ PERSONAL CONTROL PLANE / PROJECTS',
          onBack: () => Navigator.of(context).pop(),
          header: project == null
              ? null
              : Padding(
                  padding: const EdgeInsets.only(bottom: Spacing.panelGap),
                  child: _HeroCard(project: project),
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
                      // §38.5: no chevron — nothing on this screen changes a
                      // project's status yet, and a `>` that opens nothing is
                      // the chrome the concept was rejected for.
                      affordance: PanelAffordance(
                        project.status.name.toUpperCase(),
                        showIcon: false,
                        color: HotlineColors.warning,
                      ),
                    ),
                  Panel(
                    title: 'OBJECTIVE',
                    child: _Objective(
                      objective: project.objective,
                      doneCount: done.length,
                      totalCount: all.length,
                    ),
                  ),
                ],
                Panel(
                  title: 'OPEN',
                  affordance: PanelAffordance(
                    '${open.length}',
                    showIcon: false,
                  ),
                  bodyPadding: panelRowsPadding,
                  child: AsyncSection(
                    value: tasks,
                    empty: 'nothing open',
                    isEmpty: (_) => open.isEmpty,
                    builder: (_) => ListRowGroup(
                      children: [
                        for (final task in open)
                          TaskRow(
                            key: ValueKey(task.id),
                            task: task,
                            onToggle: _holdForGlitch,
                          ),
                      ],
                    ),
                  ),
                ),
                // §37: done work is kept but folded away — it is a record, not
                // a list the screen is asking anything of.
                if (done.isNotEmpty)
                  Panel(
                    title: 'DONE',
                    affordance: PanelAffordance(
                      '${done.length}',
                      icon: _showDone
                          ? HotlineIcons.collapse
                          : HotlineIcons.expand,
                    ),
                    onHeaderTap: () => setState(() => _showDone = !_showDone),
                    bodyPadding: panelRowsPadding,
                    child: !_showDone
                        ? null
                        : ListRowGroup(
                            children: [
                              for (final task in done)
                                TaskRow(
                                  key: ValueKey(task.id),
                                  task: task,
                                  onToggle: _holdForGlitch,
                                ),
                            ],
                          ),
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

/// §38.6: the card that opens the screen — the project's own mark at hero size
/// and what it is. The name is the screen title, so repeating it here would
/// spend the widest line in the app on a string already read two lines above.
class _HeroCard extends StatelessWidget {
  const _HeroCard({required this.project});

  final Project project;

  @override
  Widget build(BuildContext context) {
    return Panel(
      bodyPadding: const EdgeInsets.all(Spacing.lg),
      child: Row(
        children: [
          const HotlineIcon(
            HotlineIcons.project,
            size: IconSizes.hero,
            color: HotlineColors.textSecondary,
          ),
          const SizedBox(width: Spacing.lg),
          Expanded(
            child: Text(
              project.description,
              // With the name gone the description is the whole card, so it
              // takes the lead row size rather than the subtitle's.
              style: HotlineText.rowTitleLead.copyWith(
                color: HotlineColors.textSecondary,
              ),
              maxLines: 3,
            ),
          ),
        ],
      ),
    );
  }
}

/// §38.6: the objective sentence, then the only display-size number on the
/// screen with its `n OF m TASKS` readout under it. No bar — §38.4 keeps
/// progress bars short and inline, and this panel is the number's own place.
class _Objective extends StatelessWidget {
  const _Objective({
    required this.objective,
    required this.doneCount,
    required this.totalCount,
  });

  final String objective;
  final int doneCount;
  final int totalCount;

  @override
  Widget build(BuildContext context) {
    final ratio = totalCount == 0 ? 0.0 : doneCount / totalCount;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(objective, style: HotlineText.rowTitle, maxLines: 2),
              const SizedBox(height: RowMetrics.lineGap),
              Text('$doneCount OF $totalCount TASKS', style: HotlineText.label),
            ],
          ),
        ),
        const SizedBox(width: Spacing.lg),
        Text('${(ratio * 100).round()}%', style: HotlineText.heroPercent),
      ],
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

/// SPEC.md §37: the row's tap is the toggle, so the sheet moves to a long press
/// — §38 gives the right column back to data. The glitch is fired from the same
/// handler: §16b wants the effect bound to the state change, not to the tap.
class TaskRow extends ConsumerStatefulWidget {
  const TaskRow({super.key, required this.task, this.onToggle});

  final Task task;

  /// Called with the task's id and its `done` value before the write, so the
  /// list that owns this row can keep it in place while the glitch plays.
  final void Function(String taskId, bool wasDone)? onToggle;

  @override
  ConsumerState<TaskRow> createState() => _TaskRowState();
}

class _TaskRowState extends ConsumerState<TaskRow> {
  final _glitch = GlitchController();

  @override
  void dispose() {
    _glitch.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    // Reduce-motion drops the glitch in [HotlineIcon], so there is nothing to
    // hold the row in place for and it moves on the write like any other.
    if (!MediaQuery.disableAnimationsOf(context)) {
      _glitch.fire(seed: widget.task.id.hashCode);
      widget.onToggle?.call(widget.task.id, widget.task.done);
    }
    await ref
        .read(taskRepositoryProvider)
        .setDone(widget.task.id, !widget.task.done);
  }

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    return ListRow(
      leading: HotlineIcon(
        task.done ? HotlineIcons.checkboxChecked : HotlineIcons.checkboxEmpty,
        size: IconSizes.check,
        color: task.done ? HotlineColors.textDisabled : HotlineColors.accent,
        glitch: _glitch,
      ),
      title: task.title,
      titleColor: task.done ? HotlineColors.textMuted : null,
      // §37: the blocked reason is the row's second line, in warning, so a held
      // task is legible without opening it.
      subtitle: task.blockedReason == null
          ? null
          : '[ BLOCKED BY ] ${task.blockedReason}',
      subtitleColor: HotlineColors.warning,
      // The accent forward arrow is the only mark on the flagged row, and it is
      // the same glyph HOME's NEXT ACTION carries.
      trailing: task.isNext
          ? const HotlineIcon(
              HotlineIcons.forward,
              size: IconSizes.glyph,
              color: HotlineColors.accent,
            )
          : null,
      onTap: _toggle,
      onLongPress: () => showTaskActions(context, ref, task),
    );
  }
}
