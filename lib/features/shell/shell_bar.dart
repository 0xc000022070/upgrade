import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../../design/colors.dart';
import '../../design/components/key_cell.dart';
import '../../design/icons/spectacle_icons.dart';
import '../../design/spacing.dart';
import '../../platform/shell/strip_bytes.dart';
import '../../platform/vnc/keysyms.dart';

/// One cell of the bar: what it is called, what it sends, and the mark it is
/// drawn as when a word is not what it is.
typedef _BarKey = ({String label, int keysym, SpectacleIcons? icon});

/// The bar's keys, in the order the two apps the user lives in put them: the
/// modifiers first, then what a shell needs to get out of something, then the
/// cursor.
const _barKeys = <_BarKey>[
  (label: 'ESC', keysym: Keysyms.escape, icon: null),
  (label: 'TAB', keysym: Keysyms.tab, icon: null),
  (label: 'LEFT', keysym: Keysyms.left, icon: SpectacleIcons.arrowLeft),
  (label: 'UP', keysym: Keysyms.up, icon: SpectacleIcons.arrowUp),
  (label: 'DOWN', keysym: Keysyms.down, icon: SpectacleIcons.arrowDown),
  (label: 'RIGHT', keysym: Keysyms.right, icon: SpectacleIcons.arrowRight),
  (label: 'END', keysym: Keysyms.end, icon: null),
];

/// The modifiers the shell keeps, in the order they are drawn. No `SHIFT`,
/// which the soft keyboard already applies to what it sends, and no `SUPER`,
/// which belongs to a compositor and not to a terminal.
const _barModifiers = <StickyModifier>[StickyModifier.ctrl, StickyModifier.alt];

/// The bar's own row, shorter than a tap target: the terminal is what the user
/// came for and every row above it is taken from the screen. The whole row is
/// the hit area, so a short cell is still not a small one.
const _barHeight = RowMetrics.minHeight;

/// A cell is its label plus this much either side, so `ATTACH` is wide and `↑`
/// is not, and never narrower than the row is tall.
const _cellPadding = RowMetrics.padding;

/// The key bar under the terminal: always there, scrolling when the phone is
/// too narrow, with the keyboard toggle pinned at the right end where a thumb
/// can find it without scrolling back.
///
/// Controlled from the outside on purpose. The armed set belongs to the
/// session, because the modifiers have to reach characters the IME types
/// straight into the terminal, which never pass through this widget.
class ShellBar extends StatelessWidget {
  const ShellBar({
    super.key,
    required this.sticky,
    required this.onSticky,
    required this.onBytes,
    required this.keyboardOpen,
    required this.onKeyboard,
    this.clipCount = 0,
    this.onAttach,
  });

  final Set<StickyModifier> sticky;
  final void Function(Set<StickyModifier>) onSticky;
  final void Function(Uint8List bytes) onBytes;
  final bool keyboardOpen;
  final VoidCallback onKeyboard;

  /// How many clips are held in memory. The cell is always on the bar, since
  /// photos come in through it whether or not anything is held; the count
  /// shows only as a mark that there is something.
  final int clipCount;
  final VoidCallback? onAttach;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: _barHeight,
      decoration: const BoxDecoration(
        color: SpectacleColors.surfacePrimary,
        border: Border(top: BorderSide(color: SpectacleColors.borderSubtle)),
      ),
      child: Row(
        // The cells take the row's height rather than setting one, so the hit
        // area is the whole bar less the hairline that draws its top edge.
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final modifier in _barModifiers)
                    KeyCell(
                      key: ValueKey('bar-${modifier.label}'),
                      label: modifier.label,
                      armed: sticky.contains(modifier),
                      minWidth: _barHeight,
                      padding: _cellPadding,
                      onTap: () => _toggle(modifier),
                    ),
                  for (final key in _barKeys)
                    KeyCell(
                      key: ValueKey('bar-${key.label}'),
                      label: key.label,
                      icon: key.icon,
                      minWidth: _barHeight,
                      padding: _cellPadding,
                      onTap: () => _send(key.keysym),
                    ),
                  KeyCell(
                    key: const ValueKey('bar-ATTACH'),
                    label: clipCount == 0 ? 'ATTACH' : 'ATTACH!',
                    minWidth: _barHeight,
                    padding: _cellPadding,
                    onTap: () => onAttach?.call(),
                  ),
                ],
              ),
            ),
          ),
          // The scroll can take the keys away from the thumb; it never takes
          // the way back to the keyboard.
          const _Divider(),
          KeyCell(
            key: const ValueKey('bar-keyboard'),
            label: 'KEYBOARD',
            icon: SpectacleIcons.keyboard,
            armed: keyboardOpen,
            minWidth: _barHeight,
            padding: _cellPadding,
            onTap: onKeyboard,
          ),
        ],
      ),
    );
  }

  /// A key goes as its bytes and spends whatever was armed. Spending it here
  /// rather than in the store keeps one rule for both halves: the armed set
  /// lasts exactly one key, wherever that key came from.
  void _send(int keysym) {
    final bytes = stripBytes(keysym, sticky);
    if (bytes != null) onBytes(bytes);
    if (sticky.isNotEmpty) onSticky(const {});
  }

  void _toggle(StickyModifier modifier) {
    final next = Set.of(sticky);
    if (!next.remove(modifier)) next.add(modifier);
    onSticky(next);
  }
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) =>
      Container(width: Borders.hairline, color: SpectacleColors.borderSubtle);
}
