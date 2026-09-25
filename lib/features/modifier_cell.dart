import 'package:flutter/widgets.dart';

import '../design/components/key_bar.dart';
import '../design/components/key_cell.dart';
import '../design/icons/dazzle_icons.dart';
import '../platform/vnc/arming.dart';
import '../platform/vnc/keysyms.dart';

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
      icon: modifier == StickyModifier.superKey ? DazzleIcons.superKey : null,
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
