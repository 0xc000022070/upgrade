import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/formatting.dart';
import '../../application/providers.dart';
import '../../data/database.dart';
import '../../design/colors.dart';
import '../../design/components/list_row.dart';
import '../../design/effects/glitch.dart';
import '../../design/icons/spectacle_icon.dart';
import '../../design/icons/spectacle_icons.dart';
import '../../design/spacing.dart';
import 'item_sheet.dart';
import 'link_mark.dart';
import 'sent_tag.dart';

/// The row opens the quick view, the left glyph is the toggle, and the glitch
/// is bound to the state change rather than to the tap.
///
/// This is the row of every task of a project, under a goal or in the project's
/// own DROPS panel. Only an unfiled item — no project at all — is a drop, and a
/// drop uses [ListRow] directly.
class TaskRow extends ConsumerStatefulWidget {
  const TaskRow({
    super.key,
    required this.task,
    this.fresh = false,
    this.onLongPress,
  });

  final Task task;

  /// Captured on this screen and not left behind yet. A filed
  /// row carries no age column at all, so the age *is* the highlight here — it
  /// arrives in accent with the freshness and leaves with it.
  final bool fresh;

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
    // Reduce-motion drops the glitch in [SpectacleIcon], so there is nothing to
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
      leading: SpectacleIcon(
        task.done ? SpectacleIcons.checkboxChecked : SpectacleIcons.checkboxEmpty,
        size: IconSizes.check,
        color: task.done ? SpectacleColors.textDisabled : SpectacleColors.accent,
        glitch: _glitch,
      ),
      title: task.title,
      titleColor: task.done ? SpectacleColors.textMuted : null,
      value: widget.fresh ? relativeAge(task.createdAt) : null,
      valueColor: widget.fresh ? SpectacleColors.accent : null,
      // The blocked reason is the row's second line, in warning, so a held
      // task is legible without opening it.
      subtitle: task.blockedReason == null
          ? null
          : '[ BLOCKED BY ] ${task.blockedReason}',
      subtitleColor: SpectacleColors.warning,
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
        state: task.isNext
            ? const SpectacleIcon(
                SpectacleIcons.forward,
                size: IconSizes.glyph,
                color: SpectacleColors.accent,
              )
            : (ref.watch(sentItemsProvider).valueOrNull ?? const <String>{})
                  .contains(task.id)
            ? const SentTag()
            : null,
      ),
      // A filed task's verbs are the quick view's footer: more than two icons
      // can carry, so holding it opens the sheet unless the panel says
      // otherwise.
      onTap: () => openItemSheet(context, task.id),
      onLongPress: widget.onLongPress ?? () => openItemSheet(context, task.id),
      onLeadingTap: _toggle,
    );
  }
}
