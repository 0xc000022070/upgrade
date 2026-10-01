import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../../design/components/arrow_stick.dart';
import '../../design/components/key_bar.dart';
import '../../design/components/key_cell.dart';
import '../../design/icons/dazzle_icons.dart';
import '../../platform/shell/strip_bytes.dart';
import '../../platform/vnc/arming.dart';
import '../../platform/vnc/keysyms.dart';
import '../modifier_cell.dart';

typedef _BarKey = ({String label, int keysym, DazzleIcons? icon, bool repeats});

const _stickKeysyms = {
  AxisDirection.up: Keysyms.up,
  AxisDirection.down: Keysyms.down,
  AxisDirection.left: Keysyms.left,
  AxisDirection.right: Keysyms.right,
};

const _barKeys = <_BarKey>[
  (label: 'ESC', keysym: Keysyms.escape, icon: null, repeats: false),
  (label: 'TAB', keysym: Keysyms.tab, icon: null, repeats: false),
  (
    label: 'LEFT',
    keysym: Keysyms.left,
    icon: DazzleIcons.arrowLeft,
    repeats: true,
  ),
  (label: 'UP', keysym: Keysyms.up, icon: DazzleIcons.arrowUp, repeats: true),
  (
    label: 'DOWN',
    keysym: Keysyms.down,
    icon: DazzleIcons.arrowDown,
    repeats: true,
  ),
  (
    label: 'RIGHT',
    keysym: Keysyms.right,
    icon: DazzleIcons.arrowRight,
    repeats: true,
  ),
  (label: 'END', keysym: Keysyms.end, icon: null, repeats: false),
];

/// `SHIFT` only reaches the arrows and `TAB`: the soft keyboard already applies its own to
/// what it types. No `SUPER`, which belongs to a compositor and not to a terminal.
const _barModifiers = <StickyModifier>[
  StickyModifier.ctrl,
  StickyModifier.alt,
  StickyModifier.shift,
];

/// Controlled from the outside on purpose. The armed set belongs to the session, because
/// the modifiers have to reach characters the IME types straight into the terminal, which
/// never pass through this widget.
class ShellBar extends StatelessWidget {
  const ShellBar({
    super.key,
    required this.sticky,
    this.repeat = 1,
    this.locked = false,
    required this.onSticky,
    required this.onBytes,
    required this.keyboardOpen,
    required this.onKeyboard,
    this.clipCount = 0,
    this.onAttach,
    this.searching = false,
    this.onFind,
  });

  final Set<StickyModifier> sticky;

  /// It belongs to the whole arming rather than to one cell: two modifiers armed together
  /// are both spent on the same keys.
  final int repeat;

  /// A latched arming is spent by nothing and ends only when the last modifier is tapped
  /// off it, which is what a hand working a chord over and over asks for and no count says.
  final bool locked;

  final void Function(Set<StickyModifier> sticky, int repeat, bool locked)
  onSticky;
  final void Function(Uint8List bytes) onBytes;
  final bool keyboardOpen;
  final VoidCallback onKeyboard;

  final int clipCount;
  final VoidCallback? onAttach;

  final bool searching;

  final VoidCallback? onFind;

  Arming get _arming => Arming(sticky: sticky, repeat: repeat, locked: locked);

  void _onArming(Arming next) =>
      onSticky(next.sticky, next.repeat, next.locked);

  @override
  Widget build(BuildContext context) {
    final stick = MediaQuery.orientationOf(context) == Orientation.portrait;
    return KeyBar(
      keys: [
        KeyCell(
          key: const ValueKey('bar-find'),
          label: 'FIND',
          icon: DazzleIcons.search,
          armed: searching,
          minWidth: KeyBar.height,
          padding: KeyBar.cellPadding,
          onTap: () => onFind?.call(),
        ),
        for (final modifier in _barModifiers)
          ModifierCell(
            key: ValueKey('bar-${modifier.label}'),
            modifier: modifier,
            arming: _arming,
            onArming: _onArming,
          ),
        for (final key in _barKeys)
          if (!stick || !_stickKeysyms.containsValue(key.keysym))
            KeyCell(
              key: ValueKey('bar-${key.label}'),
              label: key.label,
              icon: key.icon,
              repeats: key.repeats,
              minWidth: KeyBar.height,
              padding: KeyBar.cellPadding,
              onTap: () => _send(key.keysym),
            ),
      ],
      pinned: [
        if (stick)
          ArrowStick(
            key: const ValueKey('bar-ARROWS'),
            height: KeyBar.height,
            onArrow: (direction) => _send(_stickKeysyms[direction]!),
          ),
        KeyCell(
          key: const ValueKey('bar-ATTACH'),
          label: clipCount == 0 ? 'ATTACH' : 'ATTACH!',
          minWidth: KeyBar.height,
          padding: KeyBar.cellPadding,
          onTap: () => onAttach?.call(),
        ),
        KeyCell(
          key: const ValueKey('bar-keyboard'),
          label: 'KEYBOARD',
          icon: DazzleIcons.keyboard,
          armed: keyboardOpen,
          minWidth: KeyBar.height,
          padding: KeyBar.cellPadding,
          onTap: onKeyboard,
        ),
      ],
    );
  }

  /// A key goes as its bytes, and nothing else: the armed set is spent where every byte
  /// passes, which is the only place that sees the characters the IME types straight into
  /// the terminal as well as these.
  void _send(int keysym) {
    final bytes = stripBytes(keysym, sticky);
    if (bytes != null) onBytes(bytes);
  }
}
