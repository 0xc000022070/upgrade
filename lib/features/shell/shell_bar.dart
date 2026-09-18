import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../../design/tokens.dart';
import '../../design/components/cell_divider.dart';
import '../../design/components/key_cell.dart';
import '../../design/icons/dazzle_icons.dart';
import '../../design/spacing.dart';
import '../../platform/shell/strip_bytes.dart';
import '../../platform/vnc/keysyms.dart';

typedef _BarKey = ({String label, int keysym, DazzleIcons? icon});

const _barKeys = <_BarKey>[
  (label: 'ESC', keysym: Keysyms.escape, icon: null),
  (label: 'TAB', keysym: Keysyms.tab, icon: null),
  (label: 'LEFT', keysym: Keysyms.left, icon: DazzleIcons.arrowLeft),
  (label: 'UP', keysym: Keysyms.up, icon: DazzleIcons.arrowUp),
  (label: 'DOWN', keysym: Keysyms.down, icon: DazzleIcons.arrowDown),
  (label: 'RIGHT', keysym: Keysyms.right, icon: DazzleIcons.arrowRight),
  (label: 'END', keysym: Keysyms.end, icon: null),
];

/// No `SHIFT`, which the soft keyboard already applies to what it sends, and no `SUPER`,
/// which belongs to a compositor and not to a terminal.
const _barModifiers = <StickyModifier>[StickyModifier.ctrl, StickyModifier.alt];

/// How much of the scrolling half a fade covers at the end it goes on past, and how much
/// of that is the bar's surface before the gradient starts. A fade that only thins is not
/// seen: a glyph sits in the middle of its cell, where a gradient spread over the whole
/// width has already run out.
const _fadeWidth = 32.0;
const _fadeSolid = 0.28;

const _barHeight = RowMetrics.minHeight;

const _cellPadding = RowMetrics.padding;

/// How many keys one arming can be made to last. Two is the chord the gesture exists for
/// — `CTRL D` twice out of an agent — and three is the margin for a process that ignored
/// the first interrupt. Past that a user is holding a key down, which a soft keyboard
/// does not do.
const _maxRepeat = 3;

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

  @override
  Widget build(BuildContext context) {
    return Container(
      height: _barHeight,
      decoration: BoxDecoration(
        color: context.tokens.surfacePrimary,
        border: Border(top: BorderSide(color: context.tokens.borderSubtle)),
      ),
      child: Row(
        // The cells take the row's height rather than setting one, so the hit area is
        // the whole bar less the hairline that draws its top edge.
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _Keys(
              children: [
                KeyCell(
                  key: const ValueKey('bar-find'),
                  label: 'FIND',
                  icon: DazzleIcons.search,
                  armed: searching,
                  minWidth: _barHeight,
                  padding: _cellPadding,
                  onTap: () => onFind?.call(),
                ),
                for (final modifier in _barModifiers)
                  KeyCell(
                    key: ValueKey('bar-${modifier.label}'),
                    label: modifier.label,
                    armed: sticky.contains(modifier),
                    repeat: sticky.contains(modifier) ? repeat : 1,
                    locked: locked && sticky.contains(modifier),
                    minWidth: _barHeight,
                    padding: _cellPadding,
                    onTap: () => _toggle(modifier),
                    onFlick: (step) => _flick(modifier, step),
                    onLongPress: () => _latch(modifier),
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
              ],
            ),
          ),
          const CellDivider(),
          KeyCell(
            key: const ValueKey('bar-ATTACH'),
            label: clipCount == 0 ? 'ATTACH' : 'ATTACH!',
            minWidth: _barHeight,
            padding: _cellPadding,
            onTap: () => onAttach?.call(),
          ),
          KeyCell(
            key: const ValueKey('bar-keyboard'),
            label: 'KEYBOARD',
            icon: DazzleIcons.keyboard,
            armed: keyboardOpen,
            minWidth: _barHeight,
            padding: _cellPadding,
            onTap: onKeyboard,
          ),
        ],
      ),
    );
  }

  /// A key goes as its bytes, and nothing else: the armed set is spent where every byte
  /// passes, which is the only place that sees the characters the IME types straight into
  /// the terminal as well as these.
  void _send(int keysym) {
    final bytes = stripBytes(keysym, sticky);
    if (bytes != null) onBytes(bytes);
  }

  /// The latch and the count belong to the set, so a modifier tapped on under a latch is
  /// latched with it, and the arming ends when the last one is tapped off.
  void _toggle(StickyModifier modifier) {
    final next = Set.of(sticky);
    if (!next.remove(modifier)) next.add(modifier);
    if (next.isEmpty) {
      onSticky(next, 1, false);
      return;
    }
    onSticky(next, repeat, locked);
  }

  /// A press held over a modifier latches the arming: armed until it is tapped off, and
  /// spent by nothing in between.
  void _latch(StickyModifier modifier) =>
      onSticky({...sticky, modifier}, 1, true);

  /// A drag down arms the modifier and counts up, a drag up counts back and then lets it
  /// go. Down from nothing lands on two rather than one: arming for a single key is what
  /// the tap already does. A latched arming only comes down.
  void _flick(StickyModifier modifier, int step) {
    final armed = sticky.contains(modifier);
    if (locked && armed) {
      if (step > 0) return;
      onSticky(Set.of(sticky)..remove(modifier), 1, false);
      return;
    }
    if (step > 0) {
      final next = armed ? repeat + 1 : 2;
      if (armed && next > _maxRepeat) return;
      onSticky({...sticky, modifier}, next, false);
      return;
    }
    if (!armed) return;
    if (repeat > 2) {
      // A copy, not the set the caller handed down: the store empties what it is
      // given before it fills it.
      onSticky(Set.of(sticky), repeat - 1, false);
      return;
    }
    onSticky(Set.of(sticky)..remove(modifier), 1, false);
  }
}

/// The metrics are followed rather than the offset: the same answer covers a row scrolled
/// past its start and a row too wide for the phone that has not been touched, and a bar
/// whose keys all fit reports neither.
class _Keys extends StatefulWidget {
  const _Keys({required this.children});

  final List<Widget> children;

  @override
  State<_Keys> createState() => _KeysState();
}

class _KeysState extends State<_Keys> {
  var _before = 0.0;
  var _after = 0.0;

  bool _onMetrics(ScrollMetrics metrics) {
    if (metrics.extentBefore == _before && metrics.extentAfter == _after) {
      return false;
    }
    setState(() {
      _before = metrics.extentBefore;
      _after = metrics.extentAfter;
    });
    return false;
  }

  @override
  Widget build(BuildContext context) {
    // Two listeners because the row changes width without being scrolled: a
    // rotation and the first layout both report metrics and no scroll.
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (notification) => _onMetrics(notification.metrics),
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) => _onMetrics(notification.metrics),
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: widget.children,
              ),
            ),
            if (_before > 0) const _Fade(key: ValueKey('bar-fade-start')),
            if (_after > 0)
              const _Fade(key: ValueKey('bar-fade-end'), end: true),
          ],
        ),
      ),
    );
  }
}

class _Fade extends StatelessWidget {
  const _Fade({super.key, this.end = false});

  final bool end;

  @override
  Widget build(BuildContext context) => Positioned(
    top: 0,
    bottom: 0,
    left: end ? null : 0,
    right: end ? 0 : null,
    width: _fadeWidth,
    child: IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: end ? Alignment.centerRight : Alignment.centerLeft,
            end: end ? Alignment.centerLeft : Alignment.centerRight,
            // The same colour twice, one of them invisible: a fade to a
            // transparent black would grey the cell under it on the way out.
            colors: [
              context.tokens.surfacePrimary,
              context.tokens.surfacePrimary.withValues(alpha: 0),
            ],
            stops: const [_fadeSolid, 1],
          ),
        ),
      ),
    ),
  );
}
