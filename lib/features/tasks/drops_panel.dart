import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/drop_selection.dart';
import '../../application/formatting.dart';
import '../../application/fresh_drops.dart';
import '../../data/database.dart';
import '../../design/tokens.dart';
import '../../design/components/list_row.dart';
import '../../design/components/panel.dart';
import '../../design/components/section.dart';
import '../../design/effects/glitch.dart';
import '../../design/icons/dazzle_icons.dart';
import '../../design/spacing.dart';
import 'item_sheet.dart';
import 'task_row.dart';

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
  });

  final String scope;
  final AsyncValue<List<Task>> drops;
  final String title;
  final String empty;

  final bool stateful;

  final GlitchController? landing;

  final ValueChanged<String>? onCompleted;

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

  @override
  Widget build(BuildContext context) {
    final selection = ref.watch(dropSelectionProvider);
    final selecting = selection.ownedBy(widget.scope);
    final allRows = widget.drops.valueOrNull ?? const <Task>[];
    final rows = widget.stateful
        ? allRows
        : allRows.where((task) => !task.done).toList();
    final doneRows = widget.stateful
        ? const <Task>[]
        : allRows.where((task) => task.done).toList();
    final visibleDrops = widget.stateful
        ? widget.drops
        : widget.drops.whenData(
            (items) => items.where((task) => !task.done).toList(),
          );
    final notifier = ref.read(dropSelectionProvider.notifier);
    _selection = notifier;
    final freshNotifier = ref.read(freshDropsProvider.notifier);
    _fresh = freshNotifier;
    final fresh = ref.watch(freshDropsProvider).idsIn(widget.scope);

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
          if (rows.isNotEmpty && !selecting) ...[
            const SizedBox(width: Spacing.lg),
            PanelAffordance(
              'SELECT',
              showIcon: false,
              onTap: () => notifier.beginEmpty(widget.scope),
            ),
          ],
        ],
      ),
      bodyPadding: panelRowsPadding,
      headerGlitch: widget.landing,
      child: AsyncSection(
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
                    widget.onCompleted?.call(task.id);
                  },
                )
              else
                ListRow(
                  title: task.title,
                  titleColor: task.done ? context.tokens.textMuted : null,
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
          ],
        ),
      ),
    );

    final panels = PanelStack(
      children: [
        panel,
        if (doneRows.isNotEmpty)
          Panel(
            title: 'DONE',
            affordance: PanelAffordance(
              '${doneRows.length}',
              icon: _showDone ? DazzleIcons.collapse : DazzleIcons.expand,
            ),
            onHeaderTap: () => setState(() => _showDone = !_showDone),
            bodyPadding: panelRowsPadding,
            child: !_showDone
                ? null
                : ListRowGroup(
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
      ],
    );

    if (!selecting) return panels;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) notifier.clear();
      },
      child: panels,
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
