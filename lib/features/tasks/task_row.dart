import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers.dart';
import '../../data/database.dart';
import '../../design/colors.dart';
import '../../design/components/list_row.dart';
import '../../design/effects/glitch.dart';
import '../../design/icons/hotline_icon.dart';
import '../../design/icons/hotline_icons.dart';
import '../../design/spacing.dart';
import 'item_sheet.dart';

/// SPEC.md §39.4: the row opens the quick view, the left glyph is the toggle.
/// §16b binds the glitch to the state change rather than to the tap.
///
/// §39.11 (ruling reversed 2026-09-02): this is the row of every task of a
/// project, under a goal or in the project's own DROPS panel. Only an unfiled
/// item — no project at all — is a drop, and a drop uses [ListRow] directly.
class TaskRow extends ConsumerStatefulWidget {
  const TaskRow({super.key, required this.task, this.onLongPress});

  final Task task;

  /// §39.13: the project's DROPS panel keeps its multi-select, so holding a row
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
    // Reduce-motion drops the glitch in [HotlineIcon], so there is nothing to
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
      // A filed task's verbs are the quick view's footer: more than two icons
      // can carry, so holding it opens the sheet unless the panel says
      // otherwise.
      onTap: () => openItemSheet(context, task.id),
      onLongPress: widget.onLongPress ?? () => openItemSheet(context, task.id),
      onLeadingTap: _toggle,
    );
  }
}
