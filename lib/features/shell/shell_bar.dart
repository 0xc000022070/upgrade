import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import 'package:upgrade/application/shell/bar_layout.dart';
import 'package:upgrade/design/effects/glitch.dart';
import 'package:upgrade/design/components/arrow_stick.dart';
import 'package:upgrade/design/components/key_bar.dart';
import 'package:upgrade/design/components/key_cell.dart';
import 'package:upgrade/design/icons/upgrade_icons.dart';
import 'package:upgrade/platform/shell/strip_bytes.dart';
import 'package:upgrade/platform/vnc/arming.dart';
import 'package:upgrade/platform/vnc/keysyms.dart';
import 'package:upgrade/features/screen/modifier_cell.dart';
import 'package:upgrade/features/shell/input/shell_voice.dart';

const _stickKeysyms = {
  AxisDirection.up: Keysyms.up,
  AxisDirection.down: Keysyms.down,
  AxisDirection.left: Keysyms.left,
  AxisDirection.right: Keysyms.right,
};

const _arrowCells = <(String, int, UpgradeIcons)>[
  ('LEFT', Keysyms.left, UpgradeIcons.arrowLeft),
  ('UP', Keysyms.up, UpgradeIcons.arrowUp),
  ('DOWN', Keysyms.down, UpgradeIcons.arrowDown),
  ('RIGHT', Keysyms.right, UpgradeIcons.arrowRight),
];

abstract interface class BarArranger {
  Widget item(BarItem item, Widget cells);
  Widget zoneEnd({required bool pinned});
}

/// `SHIFT` only reaches the arrows and `TAB`: the soft keyboard already applies its own to
/// what it types. No `SUPER`, which belongs to a compositor and not to a terminal.
const _barModifiers = {
  BarItem.ctrl: StickyModifier.ctrl,
  BarItem.alt: StickyModifier.alt,
  BarItem.shift: StickyModifier.shift,
};

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
    this.dictation,
    this.voiceLanding,
    this.onVoicePress,
    this.onVoiceLift,
    this.onVoiceDrop,
    this.onSend,
    this.searching = false,
    this.onFind,
    this.layout = BarLayout.house,
    this.arranger,
    this.scrollController,
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

  final ShellDictation? dictation;
  final GlitchController? voiceLanding;
  final VoidCallback? onVoicePress;
  final VoidCallback? onVoiceLift;
  final VoidCallback? onVoiceDrop;
  final VoidCallback? onSend;

  final bool searching;

  final VoidCallback? onFind;

  final BarLayout layout;

  final BarArranger? arranger;

  final ScrollController? scrollController;

  Arming get _arming => Arming(sticky: sticky, repeat: repeat, locked: locked);

  void _onArming(Arming next) =>
      onSticky(next.sticky, next.repeat, next.locked);

  @override
  Widget build(BuildContext context) {
    final arranger = this.arranger;
    List<Widget> zone(List<BarItem> items, {required bool pinned}) => [
      for (final item in items)
        if (arranger == null)
          ...cellsFor(item)
        else
          arranger.item(
            item,
            IgnorePointer(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: cellsFor(item),
              ),
            ),
          ),
      if (arranger != null) arranger.zoneEnd(pinned: pinned),
    ];
    return KeyBar(
      controller: scrollController,
      keys: zone(layout.keys, pinned: false),
      pinned: [
        if (onSend != null && arranger == null)
          KeyCell(
            key: const ValueKey('bar-send'),
            label: 'SEND',
            armed: true,
            minWidth: KeyBar.height,
            padding: KeyBar.cellPadding,
            onTap: onSend!,
          ),
        ...zone(layout.pinned, pinned: true),
      ],
    );
  }

  List<Widget> cellsFor(BarItem item) => switch (item) {
    BarItem.find => [
      KeyCell(
        key: const ValueKey('bar-find'),
        label: 'FIND',
        icon: UpgradeIcons.search,
        armed: searching,
        minWidth: KeyBar.height,
        padding: KeyBar.cellPadding,
        onTap: () => onFind?.call(),
      ),
    ],
    BarItem.ctrl || BarItem.alt || BarItem.shift => [
      ModifierCell(
        key: ValueKey('bar-${_barModifiers[item]!.label}'),
        modifier: _barModifiers[item]!,
        arming: _arming,
        onArming: _onArming,
      ),
    ],
    BarItem.esc => [_key('ESC', Keysyms.escape)],
    BarItem.tab => [_key('TAB', Keysyms.tab)],
    BarItem.end => [_key('END', Keysyms.end)],
    BarItem.arrows when layout.stick => [
      ArrowStick(
        key: const ValueKey('bar-ARROWS'),
        height: KeyBar.height,
        onArrow: (direction) => _send(_stickKeysyms[direction]!),
      ),
    ],
    BarItem.arrows => [
      for (final (label, keysym, icon) in _arrowCells)
        _key(label, keysym, icon: icon, repeats: true),
    ],
    BarItem.attach => [
      KeyCell(
        key: const ValueKey('bar-ATTACH'),
        label: 'ATTACH',
        icon: UpgradeIcons.image,
        armed: clipCount > 0,
        minWidth: KeyBar.height,
        padding: KeyBar.cellPadding,
        onTap: () => onAttach?.call(),
      ),
    ],
    BarItem.voice => [
      VoiceCell(
        key: const ValueKey('bar-VOICE'),
        dictation: dictation,
        landing: voiceLanding,
        onPress: () => onVoicePress?.call(),
        onLift: () => onVoiceLift?.call(),
        onDrop: () => onVoiceDrop?.call(),
      ),
    ],
    BarItem.keyboard => [
      KeyCell(
        key: const ValueKey('bar-keyboard'),
        label: 'KEYBOARD',
        icon: UpgradeIcons.keyboard,
        armed: keyboardOpen,
        minWidth: KeyBar.height,
        padding: KeyBar.cellPadding,
        onTap: onKeyboard,
      ),
    ],
  };

  Widget _key(
    String label,
    int keysym, {
    UpgradeIcons? icon,
    bool repeats = false,
  }) => KeyCell(
    key: ValueKey('bar-$label'),
    label: label,
    icon: icon,
    repeats: repeats,
    minWidth: KeyBar.height,
    padding: KeyBar.cellPadding,
    onTap: () => _send(keysym),
  );

  /// A key goes as its bytes, and nothing else: the armed set is spent where every byte
  /// passes, which is the only place that sees the characters the IME types straight into
  /// the terminal as well as these.
  void _send(int keysym) {
    final bytes = stripBytes(keysym, sticky);
    if (bytes != null) onBytes(bytes);
  }
}
