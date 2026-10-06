import 'package:flutter/widgets.dart';

import '../icons/upgrade_icon.dart';
import '../icons/upgrade_icons.dart';
import '../spacing.dart';
import '../tokens.dart';

const closeTargetSize = 48.0;

class CloseTarget extends StatelessWidget {
  const CloseTarget({super.key, required this.hot});

  final bool hot;

  @override
  Widget build(BuildContext context) {
    final tint = hot ? context.tokens.accent : context.tokens.textMuted;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.tokens.mediaBackdrop,
        border: Border.all(color: tint, width: Borders.hairline),
      ),
      child: Center(
        child: UpgradeIcon(UpgradeIcons.close, size: IconSizes.sm, color: tint),
      ),
    );
  }
}
