import 'package:flutter/widgets.dart';

import '../tokens.dart';
import '../spacing.dart';

/// The primary action is a full-width flat block, not a border.
/// It is the only place accent covers a surface, which is why it is reserved for
/// commit-style actions and never used for navigation.
class SolidActionBar extends StatelessWidget {
  const SolidActionBar({
    super.key,
    required this.label,
    required this.onTap,
    this.tone,
    this.enabled = true,
  });

  final String label;
  final VoidCallback onTap;

  /// Destructive confirms swap the fill for a state colour. Null falls back
  /// to the house accent in [build].
  final Color? tone;

  /// A form whose last requirement is a tap on a picker row
  /// cannot hide the bar until that requirement is met, because hiding the bar
  /// hides the requirement with it. A disabled bar holds its place in the dim
  /// foreground, carries the reason as its label, and swallows the tap.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final tone = this.tone ?? context.tokens.accent;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? onTap : null,
      child: Container(
        height: TapTargets.minHeight,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: enabled ? tone : context.tokens.textDisabled,
          borderRadius: BorderRadius.circular(Radii.sharp),
        ),
        child: Text(
          label.toUpperCase(),
          style: context.tokens.valueStrong.copyWith(
            color: context.tokens.backgroundPrimary,
            letterSpacing: 1.4,
            fontSize: 13,
          ),
        ),
      ),
    );
  }
}
