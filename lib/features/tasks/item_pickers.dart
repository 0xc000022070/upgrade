import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:striked/application/project_tree.dart';
import 'package:striked/application/plugins/native_plugins.dart';
import 'package:striked/application/providers.dart';
import 'package:striked/data/database.dart';
import 'package:striked/data/enums.dart';
import 'package:striked/data/views.dart';
import 'package:striked/design/components/picker_row.dart';
import 'package:striked/design/components/panel_sheet.dart';
import 'package:striked/design/components/striked_field.dart';
import 'package:striked/design/spacing.dart';
import 'package:striked/design/tokens.dart';

class TargetPickerBody extends ConsumerWidget {
  const TargetPickerBody({
    super.key,
    required this.current,
    required this.onPicked,
  });

  final ItemTarget? current;
  final ValueChanged<ItemTarget> onPicked;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projects =
        ref.watch(captureProjectsProvider).valueOrNull ?? const <Project>[];
    // watchAll already drops archived and orders by creation; status is the only reordering
    // the picker does, so a paused project keeps its place among its peers.
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
        if (projects.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Spacing.lg),
            child: Text(
              ref.watch(nativeSurfaceOwnerProvider('capture.targets')) == null
                  ? 'Enable Projects in Plugins to file this item into a project.'
                  : 'Create a project in Projects to add a filing destination.',
              style: context.tokens.rowSubtitle,
            ),
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
        StrikedField(
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
              query.isEmpty ? 'nothing to group with' : 'no match',
              style: context.tokens.rowSubtitle,
            ),
          )
        else
          for (final task in matches)
            PickerRow(label: task.title, onTap: () => widget.onPicked(task.id)),
      ],
    );
  }
}
