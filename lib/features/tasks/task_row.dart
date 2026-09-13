import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/formatting.dart';
import '../../application/providers.dart';
import '../../data/database.dart';
import '../../design/colors.dart';
import '../../design/components/list_row.dart';
import '../../design/effects/glitch.dart';
import '../../design/icons/dazzle_icon.dart';
import '../../design/icons/dazzle_icons.dart';
import '../../design/spacing.dart';
import 'item_sheet.dart';
import 'link_mark.dart';
import 'sent_tag.dart';

/// The row opens the quick view, the left glyph is the toggle, and the glitch
/// is bound to the state change rather than to the tap.
///
/// This is the row of every item the app lists: a task under a goal, a task in
/// a project's own DROPS panel, and an unfiled drop on HOME. They share the
/// checkbox because they share the gesture — the column a finger lands on is
/// the same column, and a drop that drew its own would be a second thing to
/// learn for the same answer.
class TaskRow extends ConsumerStatefulWidget {
  const TaskRow({
    super.key,
    required this.task,
    this.drop = false,
    this.fresh = false,
    this.onTap,
    this.onLongPress,
  });

  final Task task;

  /// Unfiled: no project at all. Such a row shows whether it is done and
  /// nothing else. `isNext` and `blockedReason` stay in the schema and an item
  /// unfiled by MOVE carries whatever it had, so the suppression is here rather
  /// than left to the columns being empty.
  ///
  /// It also carries its age in the value column at all times. A filed row has
  /// a panel and a goal to say where it is; an unfiled one has only when it
  /// was written down.
  final bool drop;

  /// Captured on this screen and not left behind yet. A filed
  /// row carries no age column at all, so the age *is* the highlight here — it
  /// arrives in accent with the freshness and leaves with it.
  final bool fresh;

  /// The panel may have something to do before the sheet: HOME's drops let go
  /// of the fresh set, because a pushed route counts as leaving the screen.
  final VoidCallback? onTap;

  /// The project's DROPS panel keeps its multi-select, so holding a row
  /// there begins the selection instead of opening the sheet.
  final VoidCallback? onLongPress;

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
    // Reduce-motion drops the glitch in [DazzleIcon], so there is nothing to
    // fire and the row simply changes weight.
    if (!MediaQuery.disableAnimationsOf(context)) {
      _glitch.fire(seed: widget.task.id.hashCode);
    }
    await ref
        .read(taskRepositoryProvider)
        .setDone(widget.task.id, !widget.task.done);
  }

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    return ListRow(
      leading: DazzleIcon(
        task.done
            ? DazzleIcons.checkboxChecked
            : DazzleIcons.checkboxEmpty,
        size: IconSizes.check,
        color: task.done
            ? DazzleColors.textDisabled
            : DazzleColors.accent,
        glitch: _glitch,
      ),
      title: task.title,
      titleColor: task.done ? DazzleColors.textMuted : null,
      value: widget.drop || widget.fresh ? relativeAge(task.createdAt) : null,
      valueColor: widget.fresh ? DazzleColors.accent : null,
      // The blocked reason is the row's second line, in warning, so a held
      // task is legible without opening it.
      subtitle: widget.drop || task.blockedReason == null
          ? null
          : '[ BLOCKED BY ] ${task.blockedReason}',
      subtitleColor: DazzleColors.warning,
      // The accent forward arrow is the only mark on the flagged row, and it is
      // the same glyph HOME's NEXT ACTION carries.
      // A row that was sent and then filed keeps the tag, in the same slot.
      // The arrow wins when both are true: one flagged row per screen is the
      // mark the eye is looking for, and the tag is history.
      trailing: trailingWithLinks(
        links:
            (ref.watch(linkCountsProvider).valueOrNull ??
                const <String, int>{})[task.id] ??
            0,
        state: !widget.drop && task.isNext
            ? const DazzleIcon(
                DazzleIcons.forward,
                size: IconSizes.glyph,
                color: DazzleColors.accent,
              )
            : (ref.watch(sentItemsProvider).valueOrNull ?? const <String>{})
                  .contains(task.id)
            ? const SentTag()
            : null,
      ),
      // A filed task's verbs are the quick view's footer: more than two icons
      // can carry, so holding it opens the sheet unless the panel says
      // otherwise.
      onTap: widget.onTap ?? () => openItemSheet(context, task.id),
      onLongPress: widget.onLongPress ?? () => openItemSheet(context, task.id),
      onLeadingTap: _toggle,
    );
  }
}
