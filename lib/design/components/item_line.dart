import 'package:flutter/widgets.dart';

import 'package:striked/design/spacing.dart';
import 'package:striked/design/tokens.dart';

({String text, int more}) itemLine(String value) {
  final lines = [
    for (final line in value.split('\n'))
      if (line.trim().isNotEmpty) line.trim(),
  ];
  if (lines.isEmpty) return (text: value.trim(), more: 0);
  return (text: lines.first, more: lines.length - 1);
}

class LineCount extends StatelessWidget {
  const LineCount(this.more, {super.key});

  final int more;

  @override
  Widget build(BuildContext context) {
    if (more <= 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(left: Spacing.md),
      child: Text(
        '+$more',
        style: context.tokens.value.copyWith(color: context.tokens.textMuted),
      ),
    );
  }
}

class ItemLine extends StatelessWidget {
  const ItemLine(this.value, {super.key, required this.style});

  final String value;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final line = itemLine(value);
    return Row(
      children: [
        Flexible(
          child: Text(
            line.text,
            style: style,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        LineCount(line.more),
      ],
    );
  }
}
