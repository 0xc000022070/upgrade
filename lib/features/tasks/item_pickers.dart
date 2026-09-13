import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/project_tree.dart';
import '../../application/providers.dart';
import '../../data/database.dart';
import '../../data/enums.dart';
import '../../data/views.dart';
import '../../design/components/picker_row.dart';
import '../../design/components/panel_sheet.dart';
import '../../design/components/dazzle_field.dart';
import '../../design/spacing.dart';
import '../../design/typography.dart';

/// Both pickers are bodies rather than routes: the quick view
/// swaps its own contents for one of them instead of opening a sheet over a
/// sheet, and the capture toolbar mounts the target picker on its own.

/// DROPS first, then every active project as a header row followed by its goals
/// indented one level, then paused projects. Archived are absent — filing into
/// something that is finished is not a move anyone means.
///
/// The list stays flat: the tree is for navigation, and a
/// picker that made the user walk it would be the explorer the spec refuses.
/// A child says where it sits on its own row instead, as its parent path.
class TargetPickerBody extends ConsumerWidget {
  const TargetPickerBody({
    super.key,
    required this.current,
    required this.onPicked,
  });

  /// Drawn as the solid block, so the picker answers "where is it now" before
  /// it offers anywhere else.
  final ItemTarget? current;
  final ValueChanged<ItemTarget> onPicked;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projects =
        ref.watch(captureProjectsProvider).valueOrNull ?? const <Project>[];
    // watchAll already drops archived and orders by creation; status is the
    // only reordering the picker does, so a paused project keeps its place
    // among its peers instead of being sorted twice.
    final active = projects.where((p) => p.status == ProjectStatus.active);
    final paused = projects.where((p) => p.status == ProjectStatus.paused);
    final paths = parentPaths(projects);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        PickerRow(
          label: 'DROPS',
          selected: current?.isDrops ?? false,
          onTap: () => onPicked(const ItemTarget.drops()),
        ),
        for (final project in [...active, ...paused])
          _ProjectTarget(
            project: project,
            path: paths[project.id] ?? '',
            current: current,
            onPicked: onPicked,
          ),
      ],
    );
  }
}

class _ProjectTarget extends ConsumerWidget {
  const _ProjectTarget({
    required this.project,
    required this.path,
    required this.current,
    required this.onPicked,
  });

  final Project project;

  /// The parent path, `INFRA / HOMELAB`. Empty for a root.
  final String path;
  final ItemTarget? current;
  final ValueChanged<ItemTarget> onPicked;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final goals =
        ref.watch(captureGoalsProvider(project.id)).valueOrNull ??
        const <GoalSummary>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        PickerRow(
          label: project.name.toUpperCase(),
          subtitle: path.isEmpty ? null : path,
          // A paused project is still a legal target; saying so on the row is
          // cheaper than a user filing into it and wondering where it went.
          value: project.status == ProjectStatus.paused ? 'PAUSED' : null,
          selected: current == ItemTarget.project(project.id),
          onTap: () => onPicked(ItemTarget.project(project.id)),
        ),
        for (final goal in goals)
          PickerRow(
            label: goal.title,
            value: '${goal.doneCount}/${goal.totalCount}',
            indent: true,
            selected: current == ItemTarget.goal(project.id, goal.goalId),
            onTap: () => onPicked(ItemTarget.goal(project.id, goal.goalId)),
          ),
      ],
    );
  }
}

/// Open items, newest first, minus the item itself and whatever it already
/// travels with. The search field is the first thing in the body because a
/// bundle candidate is usually something typed days ago.
class PairPickerBody extends ConsumerStatefulWidget {
  const PairPickerBody({
    super.key,
    required this.taskId,
    required this.onPicked,
  });

  final String taskId;
  final ValueChanged<String> onPicked;

  @override
  ConsumerState<PairPickerBody> createState() => _PairPickerBodyState();
}

class _PairPickerBodyState extends ConsumerState<PairPickerBody> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final candidates =
        ref.watch(pairCandidatesProvider(widget.taskId)).valueOrNull ??
        const <Task>[];
    final query = _query.trim().toLowerCase();
    final matches = query.isEmpty
        ? candidates
        : candidates
              .where((task) => task.title.toLowerCase().contains(query))
              .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        DazzleField(
          controller: _search,
          autofocus: true,
          hint: 'search',
          textInputAction: TextInputAction.search,
          contentPadding: const EdgeInsets.symmetric(vertical: Spacing.md),
          onChanged: (value) => setState(() => _query = value),
        ),
        const SheetRule(),
        if (matches.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Spacing.lg),
            child: Text(
              query.isEmpty ? 'nothing to pair with' : 'no match',
              style: DazzleText.rowSubtitle,
            ),
          )
        else
          for (final task in matches)
            PickerRow(label: task.title, onTap: () => widget.onPicked(task.id)),
      ],
    );
  }
}
