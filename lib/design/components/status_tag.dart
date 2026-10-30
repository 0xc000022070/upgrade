import 'package:flutter/widgets.dart';

import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/design/spacing.dart';

class StatusTag extends StatelessWidget {
  const StatusTag(this.label, {super.key, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.sm, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: color, width: Borders.hairline),
        borderRadius: BorderRadius.circular(Radii.sharp),
      ),
      child: Text(label, style: context.tokens.label.copyWith(color: color)),
    );
  }
}
