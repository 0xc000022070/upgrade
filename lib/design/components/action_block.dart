import 'package:flutter/widgets.dart';

import '../tokens.dart';
import '../spacing.dart';

/// A confirm block at footer scale. [SolidActionBar] is the full-width commit;
/// this is the same block sized to its label, so a row of them reads as a
/// keypad of verbs rather than as a stack of buttons.
///
/// [filled] is reserved for a state that is on or an action that
/// commits; every other block is the same rectangle drawn as a hairline
/// outline, which keeps one accent surface per row.
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
        // A [Container] with an `alignment` and no width expands to fill its
        // constraints, which turned a row of six verbs into six full-width
        // bars. The sized [Align] centres the label without claiming the
        // width, so the block is as wide as what it says.
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
