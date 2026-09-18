import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/formatting.dart';
import '../../application/providers.dart';
import '../../data/database.dart';
import '../../design/tokens.dart';
import '../../design/components/list_row.dart';
import '../../design/effects/glitch.dart';
import '../../design/icons/dazzle_icon.dart';
import '../../design/icons/dazzle_icons.dart';
import '../../design/spacing.dart';
import 'item_sheet.dart';
import 'link_mark.dart';
import 'sent_tag.dart';

class TaskRow extends ConsumerStatefulWidget {
  const TaskRow({
    super.key,
    required this.task,
    this.drop = false,
    this.fresh = false,
    this.onTap,
    this.onLongPress,
    this.onDoneChanged,
  });

  final Task task;

  /// `isNext` and `blockedReason` stay in the schema and an item unfiled by MOVE carries
  /// whatever it had, so the suppression is here rather than left to the columns being
  /// empty.
  final bool drop;

  final bool fresh;

  final VoidCallback? onTap;

  final VoidCallback? onLongPress;

  final ValueChanged<bool>? onDoneChanged;

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
    // Reduce-motion drops the glitch in [DazzleIcon], so there is nothing to fire and the
    // row simply changes weight.
    if (!MediaQuery.disableAnimationsOf(context)) {
      _glitch.fire(seed: widget.task.id.hashCode);
    }
    final done = !widget.task.done;
    await ref.read(taskRepositoryProvider).setDone(widget.task.id, done);
    widget.onDoneChanged?.call(done);
  }

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    return ListRow(
      leading: DazzleIcon(
        task.done ? DazzleIcons.checkboxChecked : DazzleIcons.checkboxEmpty,
        size: IconSizes.check,
        color: task.done ? context.tokens.textDisabled : context.tokens.accent,
        glitch: _glitch,
      ),
      title: task.title,
      titleColor: task.done ? context.tokens.textMuted : null,
      value: widget.drop || widget.fresh ? relativeAge(task.createdAt) : null,
      valueColor: widget.fresh ? context.tokens.accent : null,
      subtitle: widget.drop || task.blockedReason == null
          ? null
          : '[ BLOCKED BY ] ${task.blockedReason}',
      subtitleColor: context.tokens.warning,
      // The arrow wins when a row is both flagged and sent: one flagged row per screen is the
      // mark the eye is looking for, and the tag is history.
      trailing: trailingWithLinks(
        links:
            (ref.watch(linkCountsProvider).valueOrNull ??
                const <String, int>{})[task.id] ??
            0,
        state: !widget.drop && task.isNext
            ? DazzleIcon(
                DazzleIcons.forward,
                size: IconSizes.glyph,
                color: context.tokens.accent,
              )
            : (ref.watch(sentItemsProvider).valueOrNull ?? const <String>{})
                  .contains(task.id)
            ? const SentTag()
            : null,
      ),
      onTap: widget.onTap ?? () => openItemSheet(context, task.id),
      onLongPress: widget.onLongPress ?? () => openItemSheet(context, task.id),
      onLeadingTap: _toggle,
    );
  }
}
