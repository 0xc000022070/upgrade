import 'package:flutter/widgets.dart';

import '../colors.dart';
import '../icons/spectacle_icon.dart';
import '../icons/spectacle_icons.dart';
import '../spacing.dart';
import '../typography.dart';

/// A verb drawn as a row: an icon and a word, tall enough to tap.
class PanelTextAction extends StatelessWidget {
  const PanelTextAction({
    super.key,
    required this.label,
    required this.onTap,
    this.icon = SpectacleIcons.add,
  });

  final String label;
  final VoidCallback? onTap;
  final SpectacleIcons icon;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        height: TapTargets.minHeight,
        child: Row(
          children: [
            SpectacleIcon(
              icon,
              size: IconSizes.affordance,
              color: SpectacleColors.textMuted,
            ),
            const SizedBox(width: Spacing.sm),
            Text(
              label,
              style: onTap == null
                  ? SpectacleText.panelHeader.copyWith(
                      color: SpectacleColors.textDisabled,
                    )
                  : SpectacleText.panelHeader,
            ),
          ],
        ),
      ),
    );
  }
}
