import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers.dart';
import '../../data/database.dart';
import '../../data/enums.dart';
import '../../data/views.dart';
import '../../design/colors.dart';
import '../../design/components/list_row.dart';
import '../../design/components/panel_sheet.dart';
import '../../design/spacing.dart';
import '../../design/typography.dart';

/// SPEC.md §39.5. Both pickers are bodies rather than routes: the quick view
/// swaps its own contents for one of them instead of opening a sheet over a
/// sheet, and §39.6's capture toolbar mounts the target picker on its own.

/// DROPS first, then every active project as a header row followed by its goals
/// indented one level, then paused projects. Archived are absent — filing into
/// something that is finished is not a move anyone means.
class TargetPickerBody extends ConsumerWidget {
  const TargetPickerBody({
    super.key,
    required this.current,
    required this.onPicked,
  });

  /// Drawn as the §16c.3 block, so the picker answers "where is it now" before
  /// it offers anywhere else.
  final ItemTarget? current;
  final ValueChanged<ItemTarget> onPicked;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projects =
        ref.watch(projectsProvider).valueOrNull ?? const <Project>[];
    // watchAll already drops archived and orders by creation; status is the
    // only reordering the picker does, so a paused project keeps its place
    // among its peers instead of being sorted twice.
    final active = projects.where((p) => p.status == ProjectStatus.active);
    final paused = projects.where((p) => p.status == ProjectStatus.paused);

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
    required this.current,
    required this.onPicked,
  });

  final Project project;
  final ItemTarget? current;
  final ValueChanged<ItemTarget> onPicked;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final goals =
        ref.watch(projectGoalsProvider(project.id)).valueOrNull ??
        const <GoalSummary>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        PickerRow(
          label: project.name.toUpperCase(),
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
        TextField(
          controller: _search,
          autofocus: true,
          style: HotlineText.rowTitle,
          cursorColor: HotlineColors.accent,
          cursorWidth: 2,
          cursorRadius: Radius.zero,
          textInputAction: TextInputAction.search,
          onChanged: (value) => setState(() => _query = value),
          decoration: const InputDecoration(
            isDense: true,
            border: InputBorder.none,
            contentPadding: EdgeInsets.symmetric(vertical: Spacing.md),
            hintText: 'search',
            hintStyle: HotlineText.rowSubtitle,
          ),
        ),
        const SheetRule(),
        if (matches.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Spacing.lg),
            child: Text(
              query.isEmpty ? 'nothing to pair with' : 'no match',
              style: HotlineText.rowSubtitle,
            ),
          )
        else
          for (final task in matches)
            PickerRow(label: task.title, onTap: () => widget.onPicked(task.id)),
      ],
    );
  }
}

/// One line of either picker. §16c.3 draws the current value as the solid
/// accent block; everything else is a plain row.
class PickerRow extends StatelessWidget {
  const PickerRow({
    super.key,
    required this.label,
    required this.onTap,
    this.value,
    this.indent = false,
    this.selected = false,
  });

  final String label;
  final String? value;
  final bool indent;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final row = selected
        ? _SelectedRow(label: label, onTap: onTap)
        : ListRow(title: label, value: value, onTap: onTap);
    if (!indent) return row;
    return Padding(
      padding: const EdgeInsets.only(left: Spacing.xl),
      child: row,
    );
  }
}

class _SelectedRow extends StatelessWidget {
  const _SelectedRow({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: TapTargets.minHeight),
        margin: const EdgeInsets.symmetric(vertical: Spacing.sm),
        padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          color: HotlineColors.accent,
          borderRadius: BorderRadius.circular(Radii.sharp),
        ),
        child: Row(
          children: [
            Text(
              '// ',
              style: HotlineText.valueStrong.copyWith(
                color: HotlineColors.backgroundPrimary,
              ),
            ),
            Expanded(
              child: Text(
                label,
                style: HotlineText.rowTitle.copyWith(
                  color: HotlineColors.backgroundPrimary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
