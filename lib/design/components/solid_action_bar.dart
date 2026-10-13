import 'package:flutter/widgets.dart';

import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/design/spacing.dart';

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

  final Color? tone;

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
