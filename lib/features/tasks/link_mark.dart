import 'package:flutter/widgets.dart';

import '../../design/colors.dart';
import '../../design/components/keyboard_toolbar.dart';
import '../../design/spacing.dart';
import '../../design/typography.dart';

/// The mark on a row whose item holds link attachments — the glyph, and the
/// count once there is more than one.
///
/// Attachments only. A URL typed into the title is already on the row in full,
/// and marking it there would say the same thing twice.
///
/// It reads the link verb's own glyph rather than naming one: the mark and the
/// icon that attaches are the same idea, and a row that drew a different shape
/// for it would be a second vocabulary to learn.
class LinkMark extends StatelessWidget {
  const LinkMark({super.key, required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          ToolbarGlyph.link.icon,
          size: IconSizes.sm,
          color: DazzleColors.textMuted,
        ),
        if (count > 1) ...[
          const SizedBox(width: Spacing.xs),
          Text('$count', style: DazzleText.label),
        ],
      ],
    );
  }
}

/// The trailing edge of a row that may carry both marks: the link mark first,
/// then the state mark the row already had. One never replaces the other — the
/// arrow says which row is next, the tag says it was sent, and the link mark
/// says there is something to open; they answer different questions.
Widget? trailingWithLinks({required int links, Widget? state}) {
  if (links == 0) return state;
  if (state == null) return LinkMark(count: links);
  return Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      LinkMark(count: links),
      const SizedBox(width: Spacing.sm),
      state,
    ],
  );
}
