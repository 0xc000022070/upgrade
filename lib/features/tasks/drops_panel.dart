import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/drop_selection.dart';
import '../../application/formatting.dart';
import '../../data/database.dart';
import '../../design/colors.dart';
import '../../design/components/list_row.dart';
import '../../design/components/panel.dart';
import '../../design/components/section.dart';
import '../../design/spacing.dart';
import '../../design/typography.dart';
import 'drop_actions.dart';
import 'item_sheet.dart';
import 'task_row.dart';

/// SPEC.md §39.11 and §39.13: the panel of goal-less rows, on HOME and inside a
/// project. Holding one turns the panel's own header strip into a contextual
/// action bar.
///
/// §39.11 (ruling reversed 2026-09-02): only HOME's rows are drops. A project's
/// DROPS panel holds that project's tasks without a goal, so [stateful] gives
/// them the same [TaskRow] the goal panels use — checkbox, dim, blocked line
/// and the full quick view. The user's own device is full of pre-goal tasks
/// with state; a panel that hid it was the bug.
///
/// [scope] is what tells one DROPS panel from another. Only the panel that owns
/// the mode draws checkboxes, so entering it on HOME leaves a project's panel
/// exactly as it was.
///
/// §39.15 adds `SELECT` to the strip: the same mode, entered with nothing
/// checked, for the user who does not know the panel answers a long press.
class DropsPanel extends ConsumerStatefulWidget {
  const DropsPanel({
    super.key,
    required this.scope,
    required this.drops,
    this.title = 'DROPS',
    this.empty = 'nothing unfiled',
    this.stateful = false,
  });

  final String scope;
  final AsyncValue<List<Task>> drops;
  final String title;
  final String empty;

  /// Rows are tasks, not drops: they carry their state and open the full sheet.
  final bool stateful;

  @override
  ConsumerState<DropsPanel> createState() => _DropsPanelState();
}

class _DropsPanelState extends ConsumerState<DropsPanel> {
  DropSelectionNotifier? _selection;

  @override
  void dispose() {
    // §39.13: a selection never survives a navigation away from its panel. A
    // pushed route disposes the panel under it; the tab shell clears the mode
    // itself for the case where the panel stays mounted in an [IndexedStack].
    // `ref` is unusable here, so the notifier read during build is what does it.
    _selection?.clearScopeLater(widget.scope);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selection = ref.watch(dropSelectionProvider);
    final selecting = selection.ownedBy(widget.scope);
    final rows = widget.drops.valueOrNull ?? const <Task>[];
    final notifier = ref.read(dropSelectionProvider.notifier);
    _selection = notifier;

    // Rows that left the panel while the mode was on — moved from a sheet,
    // deleted elsewhere — must not stay in a set the batch will act on.
    if (selecting) {
      final present = {for (final task in rows) task.id};
      if (!selection.ids.every(present.contains)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) notifier.prune(widget.scope, present);
        });
      }
    }

    final panel = Panel(
      // §39.13: in the mode the strip is the action bar, so it says what is
      // checked rather than how many rows there are.
      title: selecting ? '${selection.count} SELECTED' : widget.title,
      leading: !selecting
          ? null
          : _HeaderAction(
              icon: Icons.close,
              tooltip: 'CANCEL',
              onTap: notifier.clear,
            ),
      affordance: selecting
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _HeaderAction(
                  icon: Icons.arrow_forward,
                  tooltip: 'MOVE',
                  onTap: selection.count == 0
                      ? null
                      : () => moveDrops(context, ref, selection.ids),
                ),
                _HeaderAction(
                  icon: Icons.delete_outline,
                  tooltip: 'DELETE',
                  onTap: selection.count == 0
                      ? null
                      : () => deleteDrops(context, ref, selection.ids),
                ),
              ],
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                PanelAffordance('${rows.length}', showIcon: false),
                // §39.15: the way into the mode without holding a row, next to
                // the count and tracked like `NEW +`. Hidden on an empty panel
                // — there is nothing to select — and hidden while the mode is
                // on, where the strip is already the action bar.
                if (rows.isNotEmpty) ...[
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
      child: AsyncSection(
        value: widget.drops,
        empty: widget.empty,
        builder: (items) => ListRowGroup(
          children: [
            for (final task in items)
              // §39.13: while the mode is on the box replaces the state glyph
              // in the leading slot — a selection is not a state of the item —
              // so both kinds of row look the same in it.
              if (widget.stateful && !selecting)
                TaskRow(
                  key: ValueKey(task.id),
                  task: task,
                  onLongPress: () => notifier.begin(widget.scope, task.id),
                )
              else
                ListRow(
                  title: task.title,
                  value: relativeAge(task.createdAt),
                  // §39.11: no glyph and no dim outside the mode — a drop has
                  // no state to show, and filing it is what gives it one.
                  leading: !selecting
                      ? null
                      : _SelectionBox(checked: selection.holds(task.id)),
                  leadingWidth: _SelectionBox.width,
                  // §39.13: in the mode a tap is the toggle and nothing opens.
                  onTap: selecting
                      ? () => notifier.toggle(task.id)
                      : () => openItemSheet(context, task.id),
                  // Long-press is the way in and nothing else: once the mode is
                  // on, holding a row is not a second gesture to learn.
                  onLongPress: selecting
                      ? null
                      : () => notifier.begin(widget.scope, task.id),
                ),
          ],
        ),
      ),
    );

    if (!selecting) return panel;
    // §39.13: the back gesture leaves the mode with nothing changed. The scope
    // is the panel's, so the handler is too.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) notifier.clear();
      },
      child: panel,
    );
  }
}

/// §39.13: the contextual bar's verbs are icons on the header strip, 22px in a
/// 44px hit, dim until they are pressed. A header strip is 27px tall, so the
/// hit is what makes the strip taller while the mode is on — which is also how
/// the mode announces itself.
class _HeaderAction extends StatefulWidget {
  const _HeaderAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;

  /// Not a Material tooltip: it is the semantics label, so the strip's verbs
  /// are reachable by name to a screen reader and to `phone tap`.
  final String tooltip;
  final VoidCallback? onTap;

  @override
  State<_HeaderAction> createState() => _HeaderActionState();
}

class _HeaderActionState extends State<_HeaderAction> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    final color = !enabled
        ? HotlineColors.textDisabled
        : _down
        ? HotlineColors.accent
        : HotlineColors.textSecondary;
    return Semantics(
      button: true,
      label: widget.tooltip,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: !enabled ? null : (_) => setState(() => _down = true),
        onTapCancel: !enabled ? null : () => setState(() => _down = false),
        onTapUp: !enabled ? null : (_) => setState(() => _down = false),
        onTap: widget.onTap,
        child: SizedBox(
          width: TapTargets.minHeight,
          height: TapTargets.minHeight,
          child: Center(
            child: Icon(widget.icon, size: IconSizes.toolbar, color: color),
          ),
        ),
      ),
    );
  }
}

/// §39.13 asks for a mono checkbox rather than the §39.4 glyph: done is drawn
/// with an icon, and a selection is not a state of the item.
class _SelectionBox extends StatelessWidget {
  const _SelectionBox({required this.checked});

  // §39.13 asks for a 20px box; `[x]` at the 12px row size measures ~22, so
  // the slot is the next step of the §38 4px rhythm that does not clip the
  // closing bracket.
  static const width = 24.0;

  final bool checked;

  @override
  Widget build(BuildContext context) {
    return Text(
      checked ? '[x]' : '[ ]',
      style: HotlineText.rowTitle.copyWith(
        color: checked ? HotlineColors.accent : HotlineColors.textDisabled,
      ),
    );
  }
}
