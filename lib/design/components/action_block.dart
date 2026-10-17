import 'package:flutter/widgets.dart';

import 'package:striked/design/tokens.dart';
import 'package:striked/design/spacing.dart';

class ActionBlock extends StatelessWidget {
  const ActionBlock({
    super.key,
    required this.label,
    required this.onTap,
    this.tone,
    this.filled = false,
  });

  final String label;
  final VoidCallback? onTap;
  final Color? tone;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final tone = this.tone ?? context.tokens.textSecondary;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        // A [Container] with an `alignment` and no width expands to fill its constraints; the
        // sized [Align] centres the label without claiming the width.
        constraints: const BoxConstraints(minHeight: TapTargets.minHeight),
        padding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
        decoration: BoxDecoration(
          color: filled ? tone : null,
          border: Border.all(color: tone, width: Borders.hairline),
          borderRadius: BorderRadius.circular(Radii.sharp),
        ),
        child: Align(
          alignment: Alignment.center,
          widthFactor: 1,
          heightFactor: 1,
          child: Text(
            label.toUpperCase(),
            style: context.tokens.value.copyWith(
              color: filled ? context.tokens.backgroundPrimary : tone,
              letterSpacing: 1.2,
            ),
          ),
        ),
      ),
    );
  }
}
