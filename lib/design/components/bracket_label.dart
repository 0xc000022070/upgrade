import 'package:flutter/widgets.dart';

import '../colors.dart';
import '../spacing.dart';
import 'meta.dart';

/// SPEC.md §16c.7: a key fact takes the `[ LABEL ]` mono form, so the label
/// reads as a field name in a readout rather than as a heading.
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
          child: Meta(value, color: color ?? HotlineColors.textSecondary),
        ),
      ],
    );
  }
}
