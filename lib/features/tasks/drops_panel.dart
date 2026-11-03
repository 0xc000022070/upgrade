import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/drops/drop_selection.dart';
import 'package:upgrade/application/formatting.dart';
import 'package:upgrade/application/drops/fresh_drops.dart';
import 'package:upgrade/data/database.dart';
import 'package:upgrade/data/enums.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/design/components/list_row.dart';
import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/design/components/panel_text_action.dart';
import 'package:upgrade/design/components/section.dart';
import 'package:upgrade/design/effects/glitch.dart';
import 'package:upgrade/design/icons/upgrade_icons.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/features/tasks/item_sheet.dart';
import 'package:upgrade/features/tasks/task_row.dart';

class DropsPanel extends ConsumerStatefulWidget {
  const DropsPanel({
    super.key,
    required this.scope,
    required this.drops,
    this.title = 'DROPS',
    this.empty = 'nothing unfiled',
    this.stateful = false,
    this.landing,
    this.onCompleted,
    this.height,
    this.onSearch,
    this.limit,
    this.byPriority = false,
    this.onOrder,
    this.onViewAll,
  });

  final String scope;
  final AsyncValue<List<Task>> drops;
  final String title;
  final String empty;

  final bool stateful;

  final GlitchController? landing;

  final ValueChanged<Task>? onCompleted;

  final double? height;

  final VoidCallback? onSearch;

  final int? limit;

  final bool byPriority;

  final VoidCallback? onOrder;

  final VoidCallback? onViewAll;

  @override
  ConsumerState<DropsPanel> createState() => _DropsPanelState();
}

class _DropsPanelState extends ConsumerState<DropsPanel> {
  DropSelectionNotifier? _selection;
  FreshDropsNotifier? _fresh;

  /// A set is pruned against what left this, never against what is missing from the list —
  /// the capture bar marks a row fresh when the write returns, and the stream delivers it a
  /// frame or more later.
  final _rendered = <String>{};
  bool _showDone = false;

  @override
  void dispose() {
    // A pushed route disposes the panel under it; the tab shell clears the mode itself for
    // the case where the panel stays mounted in an [IndexedStack]. `ref` is unusable here,
    // so the notifier read during build does it.
    _selection?.clearScopeLater(widget.scope);
    _fresh?.clearScopeLater(widget.scope);
    super.dispose();
  }

  void _hold(String id, Set<String> fresh) {
    final selection = ref.read(dropSelectionProvider.notifier);
    if (fresh.contains(id)) {
      selection.beginMany(widget.scope, fresh);
      return;
    }
    ref.read(freshDropsProvider.notifier).clear();
    selection.begin(widget.scope, id);
  }

  void _open(String id) {
    ref.read(freshDropsProvider.notifier).clear();
    openItemSheet(context, id);
  }

  /// A bundle ranks by its highest item and a fresh drop above critical, so a bundle stays
  /// adjacent and a capture stays in sight; ties keep the newest-first order.
  List<Task> _ordered(List<Task> rows, Set<String> fresh) {
    if (!widget.byPriority) return rows;
    final rank = <String, int>{};
    for (final task in rows) {
      final value = fresh.contains(task.id)
          ? Priority.values.length
          : task.priority.index;
      rank.update(
        task.bundleId ?? task.id,
        (other) => max(other, value),
        ifAbsent: () => value,
      );
    }
    final index = {for (final (i, task) in rows.indexed) task.id: i};
    int rankOf(Task task) => rank[task.bundleId ?? task.id]!;
    return [...rows]..sort((a, b) {
      final byRank = rankOf(b).compareTo(rankOf(a));
      return byRank != 0 ? byRank : index[a.id]!.compareTo(index[b.id]!);
    });
  }

  @override
  Widget build(BuildContext context) {
    final selection = ref.watch(dropSelectionProvider);
    final selecting = selection.ownedBy(widget.scope);
    final allRows = widget.drops.value ?? const <Task>[];
    final rows = widget.stateful
        ? allRows
        : allRows.where((task) => !task.done).toList();
    final doneRows = widget.stateful
        ? const <Task>[]
        : allRows.where((task) => task.done).toList();
    final notifier = ref.read(dropSelectionProvider.notifier);
    _selection = notifier;
    final freshNotifier = ref.read(freshDropsProvider.notifier);
    _fresh = freshNotifier;
    final fresh = ref.watch(freshDropsProvider).idsIn(widget.scope);
    final ordered = _ordered(rows, fresh);
    final limit = widget.limit;
    final shown = limit == null ? ordered : ordered.take(limit).toList();
    final visibleDrops = widget.drops.whenData((_) => shown);
    final viewAll = widget.onViewAll;
    final height = widget.height;
    Widget scrolls(Widget body) =>
        height == null ? body : SingleChildScrollView(child: body);
    Widget fits(Widget panel) =>
        height == null || !_showDone ? panel : Flexible(child: panel);

    // The ids that left are the ones this panel drew and no longer draws. An id it has never
    // drawn is not gone, it has not arrived, and both sets are written by something that
    // runs ahead of the stream.
    if (widget.drops.hasValue) {
      final present = {for (final task in rows) task.id};
      final removed = _rendered.difference(present);
      _rendered
        ..clear()
        ..addAll(present);
      if (removed.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          notifier.forget(widget.scope, removed);
          freshNotifier.forget(widget.scope, removed);
        });
      }
    }

    final panel = Panel(
      title: widget.title,
      affordance: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          PanelAffordance('${rows.length}', showIcon: false),
          if (widget.onOrder case final order? when !selecting) ...[
            const SizedBox(width: Spacing.lg),
            PanelAffordance(
              widget.byPriority ? 'PRIORITY' : 'NEWEST',
              showIcon: false,
              onTap: order,
            ),
          ],
          if (rows.isNotEmpty && !selecting) ...[
            const SizedBox(width: Spacing.lg),
            PanelAffordance(
              'SELECT',
              showIcon: false,
              onTap: () => notifier.beginEmpty(widget.scope),
            ),
          ],
          if (widget.onSearch case final search? when !selecting) ...[
            const SizedBox(width: Spacing.lg),
            PanelAffordance(
              'SEARCH',
              icon: UpgradeIcons.search,
              showLabel: false,
              onTap: search,
            ),
          ],
        ],
      ),
      bodyPadding: panelRowsPadding,
      bodyFlexible: height != null,
      headerGlitch: widget.landing,
      child: scrolls(
        AsyncSection(
          value: visibleDrops,
          empty: widget.empty,
          builder: (items) => ListRowGroup(
            children: [
              for (final task in items)
                if (!selecting)
                  TaskRow(
                    key: ValueKey(task.id),
                    task: task,
                    drop: !widget.stateful,
                    fresh: fresh.contains(task.id),
                    onTap: widget.stateful ? null : () => _open(task.id),
                    onLongPress: () => _hold(task.id, fresh),
                    onDoneChanged: (done) {
                      if (!done) return;
                      freshNotifier.forget(widget.scope, {task.id});
                      widget.onCompleted?.call(task);
                    },
                  )
                else
                  ListRow(
                    title: task.title,
                    titleColor: task.done ? context.tokens.textDisabled : null,
                    value: relativeAge(task.createdAt),
                    valueColor: fresh.contains(task.id)
                        ? context.tokens.accent
                        : null,
                    leading: _SelectionBox(checked: selection.holds(task.id)),
                    leadingWidth: _SelectionBox.width,
                    onTap: () => notifier.toggle(task.id),
                    onLongPress: null,
                    trailing: null,
                  ),
              if (viewAll != null && shown.length < rows.length && !selecting)
                PanelTextAction(
                  label: 'VIEW ALL ${rows.length}',
                  icon: UpgradeIcons.forward,
                  onTap: viewAll,
                ),
            ],
          ),
        ),
      ),
    );

    final panels = PanelStack(
      children: [
        if (height == null) panel else Flexible(child: panel),
        if (doneRows.isNotEmpty)
          fits(
            Panel(
              title: 'DONE',
              affordance: PanelAffordance(
                '${doneRows.length}',
                icon: _showDone ? UpgradeIcons.collapse : UpgradeIcons.expand,
              ),
              onHeaderTap: () => setState(() => _showDone = !_showDone),
              bodyPadding: panelRowsPadding,
              bodyFlexible: height != null,
              child: !_showDone
                  ? null
                  : scrolls(
                      ListRowGroup(
                        children: [
                          for (final task in doneRows)
                            TaskRow(
                              key: ValueKey('done-${task.id}'),
                              task: task,
                              drop: true,
                              onTap: () => _open(task.id),
                            ),
                        ],
                      ),
                    ),
            ),
          ),
      ],
    );

    final bounded = height == null
        ? panels
        : ConstrainedBox(
            constraints: BoxConstraints(maxHeight: height),
            child: panels,
          );

    if (!selecting) return bounded;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) notifier.clear();
      },
      child: bounded,
    );
  }
}

class _SelectionBox extends StatelessWidget {
  const _SelectionBox({required this.checked});

  // The box wants 20px; `[x]` at the 12px row size measures ~22, so the slot is the next
  // step of the 4px rhythm that does not clip the closing bracket.
  static const width = 24.0;

  final bool checked;

  @override
  Widget build(BuildContext context) {
    return Text(
      checked ? '[x]' : '[ ]',
      style: context.tokens.rowTitle.copyWith(
        color: checked ? context.tokens.accent : context.tokens.textDisabled,
      ),
    );
  }
}
