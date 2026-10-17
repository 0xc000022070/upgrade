import 'package:flutter/widgets.dart';

import 'package:striked/design/tokens.dart';
import 'package:striked/design/components/keyboard_toolbar.dart';
import 'package:striked/design/spacing.dart';

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
          color: context.tokens.textMuted,
        ),
        if (count > 1) ...[
          const SizedBox(width: Spacing.xs),
          Text('$count', style: context.tokens.label),
        ],
      ],
    );
  }
}

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
