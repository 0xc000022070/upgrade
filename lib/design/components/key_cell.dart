import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../colors.dart';
import '../icons/spectacle_icon.dart';
import '../icons/spectacle_icons.dart';
import '../motion.dart';
import '../spacing.dart';
import '../typography.dart';

/// How far a vertical drag has to travel, once it has taken the pointer off
/// the tap, before it counts as a flick in that direction.
const _flickDistance = 8.0;

/// One key drawn as a key: a tracked word or one of the artist's marks, with
/// the press tint and the armed accent that say what it is doing.
///
/// Shared by the screen's keys strip and the shell's bar so the two are the
/// same key under two layouts. The strip's cells take their width from the
/// row they are in and stand a full tap target tall; the bar's are shorter and
/// set their own floor, which is what [minWidth] and [padding] are for.
class KeyCell extends StatefulWidget {
  const KeyCell({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
    this.armed = false,
    this.inert = false,
    this.repeat = 1,
    this.locked = false,
    this.onFlick,
    this.onLongPress,
    this.minWidth,
    this.padding = Spacing.md,
    this.height = TapTargets.minHeight,
  });

  final String label;
  final SpectacleIcons? icon;
  final VoidCallback onTap;
  final bool armed;

  /// Drawn as a key and worth nothing: no press tint, no arming. Dimmer than a
  /// key at rest, which is the only thing that says so before it is pressed.
  final bool inert;

  /// How many things this key is armed for. Anything above one is drawn after
  /// the label, `CTRL(x2)`, and the change rolls rather than cuts.
  final int repeat;

  /// Armed for everything that follows rather than for a count. Drawn
  /// `CTRL(∞)`, which replaces the count rather than sitting beside it: a
  /// number under a modifier nothing spends says nothing.
  final bool locked;

  /// A vertical drag over the cell, `1` down and `-1` up. Null leaves the cell
  /// with nothing but its tap, which is what every key that cannot be counted
  /// wants.
  final void Function(int step)? onFlick;

  /// A press held over the cell. Null on every key that has nothing to hold —
  /// a key that sends bytes is over the moment it is pressed.
  final VoidCallback? onLongPress;

  /// A floor, not a width: a cell is as wide as its label plus [padding] on
  /// either side, and no narrower than this. Null leaves the width to whatever
  /// row the cell is in.
  final double? minWidth;

  final double padding;

  /// A full tap target unless a row stretches its cells, which is how the bar
  /// hands every cell its whole short row as a hit area.
  final double height;

  @override
  State<KeyCell> createState() => _KeyCellState();
}

class _KeyCellState extends State<KeyCell> {
  bool _down = false;
  double _travel = 0;

  @override
  Widget build(BuildContext context) {
    // The press tint, and the same accent for a modifier that is armed: both
    // mean "this key is what the next thing you do goes through". An inert key
    // has neither and is dimmer at rest than one that works.
    final tint = widget.inert
        ? SpectacleColors.textMuted
        : _down || widget.armed
        ? SpectacleColors.accent
        : SpectacleColors.textSecondary;
    final icon = widget.icon;
    final flick = widget.inert ? null : widget.onFlick;
    final hold = widget.inert ? null : widget.onLongPress;
    final label = widget.locked
        ? '${widget.label}(∞)'
        : widget.repeat > 1
        ? '${widget.label}(x${widget.repeat})'
        : widget.label;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: widget.inert ? null : (_) => setState(() => _down = true),
      onTapCancel: widget.inert ? null : () => setState(() => _down = false),
      onTapUp: widget.inert ? null : (_) => setState(() => _down = false),
      onTap: widget.inert ? null : widget.onTap,
      // The hold shares the detector with the tap for the same reason the drag
      // does: the two are in one arena, so a finger that stays wins the hold
      // and the tap under it is cancelled rather than both firing.
      onLongPress: hold,
      // The drag lives on the same detector as the tap so the two share an
      // arena entry: a finger that moves takes the drag and the tap is
      // cancelled under it, rather than both firing. The travel is counted
      // from the finger's own first pixel, slop included, so the distance
      // below is the distance the user actually moved.
      dragStartBehavior: DragStartBehavior.down,
      onVerticalDragStart: flick == null
          ? null
          : (_) {
              _travel = 0;
              setState(() => _down = true);
            },
      onVerticalDragUpdate: flick == null
          ? null
          : (details) => _travel += details.delta.dy,
      onVerticalDragCancel: flick == null
          ? null
          : () => setState(() => _down = false),
      onVerticalDragEnd: flick == null
          ? null
          : (_) {
              setState(() => _down = false);
              if (_travel.abs() < _flickDistance) return;
              flick(_travel > 0 ? 1 : -1);
            },
      child: Container(
        height: widget.height,
        constraints: widget.minWidth == null
            ? null
            : BoxConstraints(minWidth: widget.minWidth!),
        padding: widget.minWidth == null
            ? null
            : EdgeInsets.symmetric(horizontal: widget.padding),
        alignment: Alignment.center,
        // The label is still the semantics: a glyph key reads as its name to a
        // screen reader, which a bare picture would not.
        child: Semantics(
          label: widget.locked
              ? '${widget.label} latched'
              : widget.repeat > 1
              ? '${widget.label} x${widget.repeat}'
              : widget.label,
          child: icon == null
              ? _RollingLabel(
                  text: label,
                  style: SpectacleText.panelHeader.copyWith(color: tint),
                )
              : SpectacleIcon(icon, size: IconSizes.toolbar, color: tint),
        ),
      ),
    );
  }
}

/// A word that changes by rolling: the one leaving goes out through the floor
/// while the one arriving comes in through the ceiling, clipped to the line so
/// neither is ever seen outside it.
class _RollingLabel extends StatefulWidget {
  const _RollingLabel({required this.text, required this.style});

  final String text;
  final TextStyle style;

  @override
  State<_RollingLabel> createState() => _RollingLabelState();
}

class _RollingLabelState extends State<_RollingLabel>
    with SingleTickerProviderStateMixin {
  late final AnimationController
  _roll = AnimationController(vsync: this, duration: Motion.fast)
    ..addStatusListener((status) {
      // The word that left is dropped the moment it has, so the cell goes back
      // to being as wide as the word it now reads.
      if (status == AnimationStatus.completed && mounted) {
        setState(() => _leaving = null);
      }
    });

  String? _leaving;

  @override
  void didUpdateWidget(covariant _RollingLabel old) {
    super.didUpdateWidget(old);
    if (widget.text == old.text) return;
    _leaving = old.text;
    _roll.forward(from: 0);
  }

  @override
  void dispose() {
    _roll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final arriving = Text(widget.text, style: widget.style, maxLines: 1);
    final leaving = _leaving;
    if (leaving == null) return arriving;
    return ClipRect(
      child: AnimatedBuilder(
        animation: _roll,
        builder: (context, _) {
          final t = Motion.transition.transform(_roll.value);
          // The arriving word sizes the stack; the one leaving is laid over it
          // and translated by its whole height, so a longer word going out is
          // never what the cell is measured by.
          return Stack(
            children: [
              FractionalTranslation(
                translation: Offset(0, t - 1),
                child: arriving,
              ),
              Positioned.fill(
                child: FractionalTranslation(
                  translation: Offset(0, t),
                  child: Center(
                    child: Text(leaving, style: widget.style, maxLines: 1),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
