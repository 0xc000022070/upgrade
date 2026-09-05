import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/drop_selection.dart';
import '../../application/formatting.dart';
import '../../application/fresh_drops.dart';
import '../../application/providers.dart';
import '../../data/database.dart';
import '../../design/colors.dart';
import '../../design/components/list_row.dart';
import '../../design/components/panel.dart';
import '../../design/components/section.dart';
import '../../design/effects/glitch.dart';
import '../../design/spacing.dart';
import '../../design/typography.dart';
import 'item_sheet.dart';
import 'sent_tag.dart';
import 'task_row.dart';

/// The panel of goal-less rows, on HOME and inside a project. Holding one turns
/// the panel's own header strip into a contextual action bar.
///
/// Only HOME's rows are drops. A project's
/// DROPS panel holds that project's tasks without a goal, so [stateful] gives
/// them the same [TaskRow] the goal panels use — checkbox, dim, blocked line
/// and the full quick view. The user's own device is full of pre-goal tasks
/// with state; a panel that hid it was the bug.
///
/// [scope] is what tells one DROPS panel from another. Only the panel that owns
/// the mode draws checkboxes, so entering it on HOME leaves a project's panel
/// exactly as it was.
///
/// `SELECT` on the strip is the same mode, entered with nothing
/// checked, for the user who does not know the panel answers a long press.
///
/// A row captured on this screen keeps an accent age until the user leaves, and
/// a long press on one of them checks the whole fresh set.
///
/// The verbs are off the strip. A header scrolls away with its
/// panel, so the mode's chrome moved to the bar in the capture bar's slot and
/// the strip says what it says outside the mode — title and count, with
/// `SELECT` hidden because the mode it opens is already on.
class DropsPanel extends ConsumerStatefulWidget {
  const DropsPanel({
    super.key,
    required this.scope,
    required this.drops,
    this.title = 'DROPS',
    this.empty = 'nothing unfiled',
    this.stateful = false,
    this.landing,
  });

  final String scope;
  final AsyncValue<List<Task>> drops;
  final String title;
  final String empty;

  /// Rows are tasks, not drops: they carry their state and open the full sheet.
  final bool stateful;

  /// Fired by the capture bar of a pushed route, where the nav
  /// icon that normally takes the landing is not on screen.
  final GlitchController? landing;

  @override
  ConsumerState<DropsPanel> createState() => _DropsPanelState();
}

class _DropsPanelState extends ConsumerState<DropsPanel> {
  DropSelectionNotifier? _selection;
  FreshDropsNotifier? _fresh;

  /// The ids this panel has actually drawn. A set is pruned against
  /// what left this, never against what is missing from the list — the capture
  /// bar marks a row fresh when the write returns, and the stream delivers it
  /// a frame or more later.
  final _rendered = <String>{};

  @override
  void dispose() {
    // A selection never survives a navigation away from its panel. A
    // pushed route disposes the panel under it; the tab shell clears the mode
    // itself for the case where the panel stays mounted in an [IndexedStack].
    // `ref` is unusable here, so the notifier read during build does it.
    _selection?.clearScopeLater(widget.scope);
    // The fresh set goes the same way, and the back gesture out of a
    // project is exactly this path.
    _fresh?.clearScopeLater(widget.scope);
    super.dispose();
  }

  /// Holding a fresh row is a gesture on the set, not on the row —
  /// every fresh row of this panel goes in. Holding anything else says the set
  /// is over, and the mode opens on that one row.
  void _hold(String id, Set<String> fresh) {
    final selection = ref.read(dropSelectionProvider.notifier);
    if (fresh.contains(id)) {
      selection.beginMany(widget.scope, fresh);
      return;
    }
    ref.read(freshDropsProvider.notifier).clear();
    selection.begin(widget.scope, id);
  }

  /// The quick view is a pushed route, which counts as leaving.
  void _open(String id) {
    ref.read(freshDropsProvider.notifier).clear();
    openItemSheet(context, id);
  }

  @override
  Widget build(BuildContext context) {
    final selection = ref.watch(dropSelectionProvider);
    final selecting = selection.ownedBy(widget.scope);
    final rows = widget.drops.valueOrNull ?? const <Task>[];
    final notifier = ref.read(dropSelectionProvider.notifier);
    _selection = notifier;
    final freshNotifier = ref.read(freshDropsProvider.notifier);
    _fresh = freshNotifier;
    final fresh = ref.watch(freshDropsProvider).idsIn(widget.scope);
    // One stream for the panel rather than a query per row: the tag is a fact
    // about a handful of ids and the list can be long.
    final sent = ref.watch(sentItemsProvider).valueOrNull ?? const <String>{};

    // Rows that left the panel while the mode was on — moved from a sheet,
    // deleted elsewhere — must not stay in a set the batch will act on. The
    // fresh set goes the same way, which is what empties it when a batch takes
    // the last fresh row out.
    //
    // The ids that left are the ones this panel drew and no longer
    // draws. An id it has never drawn is not gone, it has not arrived, and both
    // sets are written by something that runs ahead of the stream.
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
          // The way into the mode without holding a row, next to the
          // count and tracked like `NEW +`. Hidden on an empty panel — there is
          // nothing to select — and hidden while the mode is on, where the bar
          // at the bottom of the screen is what the panel is doing.
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
        value: widget.drops,
        empty: widget.empty,
        builder: (items) => ListRowGroup(
          children: [
            for (final task in items)
              // While the mode is on the box replaces the state glyph
              // in the leading slot — a selection is not a state of the item —
              // so both kinds of row look the same in it.
              if (widget.stateful && !selecting)
                TaskRow(
                  key: ValueKey(task.id),
                  task: task,
                  fresh: fresh.contains(task.id),
                  onLongPress: () => _hold(task.id, fresh),
                )
              else
                ListRow(
                  title: task.title,
                  value: relativeAge(task.createdAt),
                  // The whole highlight: the age in accent instead of the
                  // dim it has by default. Nothing else on the row moves.
                  valueColor: fresh.contains(task.id)
                      ? SpectacleColors.accent
                      : null,
                  // No glyph and no dim outside the mode — a drop has
                  // no state to show, and filing it is what gives it one.
                  leading: !selecting
                      ? null
                      : _SelectionBox(checked: selection.holds(task.id)),
                  leadingWidth: _SelectionBox.width,
                  // In the mode a tap is the toggle and nothing opens.
                  onTap: selecting
                      ? () => notifier.toggle(task.id)
                      : () => _open(task.id),
                  // Long-press is the way in and nothing else: once the mode is
                  // on, holding a row is not a second gesture to learn.
                  onLongPress: selecting ? null : () => _hold(task.id, fresh),
                  // Not in the mode: the box is the row's leading edge there,
                  // and a tag next to a checkbox reads as a second thing to
                  // check.
                  trailing: !selecting && sent.contains(task.id)
                      ? const SentTag()
                      : null,
                ),
          ],
        ),
      ),
    );

    if (!selecting) return panel;
    // The back gesture leaves the mode with nothing changed. The scope
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

/// A mono checkbox rather than the row's own glyph: done is drawn
/// with an icon, and a selection is not a state of the item.
class _SelectionBox extends StatelessWidget {
  const _SelectionBox({required this.checked});

  // The box wants 20px; `[x]` at the 12px row size measures ~22, so the slot
  // is the next step of the 4px rhythm that does not clip the
  // closing bracket.
  static const width = 24.0;

  final bool checked;

  @override
  Widget build(BuildContext context) {
    return Text(
      checked ? '[x]' : '[ ]',
      style: SpectacleText.rowTitle.copyWith(
        color: checked ? SpectacleColors.accent : SpectacleColors.textDisabled,
      ),
    );
  }
}
