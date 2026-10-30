import 'package:flutter/widgets.dart';

import 'package:upgrade/design/components/key_bar.dart';
import 'package:upgrade/design/components/key_cell.dart';
import 'package:upgrade/design/icons/upgrade_icons.dart';
import 'package:upgrade/platform/vnc/arming.dart';
import 'package:upgrade/platform/vnc/keysyms.dart';

class ModifierCell extends StatelessWidget {
  const ModifierCell({
    super.key,
    required this.modifier,
    required this.arming,
    required this.onArming,
  });

  final StickyModifier modifier;
  final Arming arming;
  final ValueChanged<Arming> onArming;

  @override
  Widget build(BuildContext context) {
    final armed = arming.armed(modifier);
    return KeyCell(
      label: modifier.label,
      icon: modifier == StickyModifier.superKey ? UpgradeIcons.superKey : null,
      armed: armed,
      repeat: armed ? arming.repeat : 1,
      locked: armed && arming.locked,
      minWidth: KeyBar.height,
      padding: KeyBar.cellPadding,
      onTap: () => onArming(arming.toggle(modifier)),
      onFlick: (step) {
        final next = arming.flick(modifier, step);
        if (next != null) onArming(next);
      },
      onLongPress: () => onArming(arming.latch(modifier)),
    );
  }
}
