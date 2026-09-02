import 'package:flutter/widgets.dart';

import '../colors.dart';
import '../spacing.dart';
import '../typography.dart';

/// SPEC.md §16c.2: the primary action is a full-width flat block, not a border.
/// It is the only place accent covers a surface, which is why it is reserved for
/// commit-style actions and never used for navigation.
class SolidActionBar extends StatelessWidget {
  const SolidActionBar({
    super.key,
    required this.label,
    required this.onTap,
    this.tone = HotlineColors.accent,
  });

  final String label;
  final VoidCallback onTap;

  /// Destructive confirms swap the fill for a state colour (§16c.2).
  final Color tone;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: TapTargets.minHeight,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: tone,
          borderRadius: BorderRadius.circular(Radii.sharp),
        ),
        child: Text(
          label.toUpperCase(),
          style: HotlineText.valueStrong.copyWith(
            color: HotlineColors.backgroundPrimary,
            letterSpacing: 1.4,
            fontSize: 13,
          ),
        ),
      ),
    );
  }
}
