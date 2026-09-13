import 'package:flutter/widgets.dart';

import '../colors.dart';
import '../icons/dazzle_icon.dart';
import '../icons/dazzle_icons.dart';
import '../spacing.dart';
import '../typography.dart';

/// A verb drawn as a row: an icon and a word, tall enough to tap.
class PanelTextAction extends StatelessWidget {
  const PanelTextAction({
    super.key,
    required this.label,
    required this.onTap,
    this.icon = DazzleIcons.add,
  });

  final String label;
  final VoidCallback? onTap;
  final DazzleIcons icon;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        height: TapTargets.minHeight,
        child: Row(
          children: [
            DazzleIcon(
              icon,
              size: IconSizes.affordance,
              color: DazzleColors.textMuted,
            ),
            const SizedBox(width: Spacing.sm),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: onTap == null
                    ? DazzleText.panelHeader.copyWith(
                        color: DazzleColors.textDisabled,
                      )
                    : DazzleText.panelHeader,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
