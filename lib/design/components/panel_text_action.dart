import 'package:flutter/widgets.dart';

import 'package:striked/design/tokens.dart';
import 'package:striked/design/icons/striked_icon.dart';
import 'package:striked/design/icons/striked_icons.dart';
import 'package:striked/design/spacing.dart';

class PanelTextAction extends StatelessWidget {
  const PanelTextAction({
    super.key,
    required this.label,
    required this.onTap,
    this.icon = StrikedIcons.add,
  });

  final String label;
  final VoidCallback? onTap;
  final StrikedIcons icon;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        height: TapTargets.minHeight,
        child: Row(
          children: [
            StrikedIcon(
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
