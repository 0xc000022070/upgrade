import 'package:flutter/widgets.dart';

import '../tokens.dart';
import '../icons/upgrade_icon.dart';
import '../icons/upgrade_icons.dart';
import '../spacing.dart';

class PanelTextAction extends StatelessWidget {
  const PanelTextAction({
    super.key,
    required this.label,
    required this.onTap,
    this.icon = UpgradeIcons.add,
  });

  final String label;
  final VoidCallback? onTap;
  final UpgradeIcons icon;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        height: TapTargets.minHeight,
        child: Row(
          children: [
            UpgradeIcon(
              icon,
              size: IconSizes.affordance,
              color: context.tokens.textMuted,
            ),
            const SizedBox(width: Spacing.sm),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: onTap == null
                    ? context.tokens.panelHeader.copyWith(
                        color: context.tokens.textDisabled,
                      )
                    : context.tokens.panelHeader,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
