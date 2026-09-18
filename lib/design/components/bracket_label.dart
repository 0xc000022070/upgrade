import 'package:flutter/widgets.dart';

import '../tokens.dart';
import '../spacing.dart';
import 'meta.dart';

class BracketLabel extends StatelessWidget {
  const BracketLabel(this.label, {super.key, required this.value, this.color});

  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Meta('[ ${label.toUpperCase()} ]', color: color),
        const SizedBox(width: Spacing.md),
        Expanded(
          child: Meta(value, color: color ?? context.tokens.textSecondary),
        ),
      ],
    );
  }
}
