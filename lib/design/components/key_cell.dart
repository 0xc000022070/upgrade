import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../tokens.dart';
import '../icons/dazzle_icon.dart';
import '../icons/dazzle_icons.dart';
import '../motion.dart';
import '../spacing.dart';

/// How far a vertical drag has to travel, once it has taken the pointer off the tap,
/// before it counts as a flick.
const _flickDistance = 8.0;

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
  final DazzleIcons? icon;
  final VoidCallback onTap;
  final bool armed;

  final bool inert;

  final int repeat;

  final bool locked;

  final void Function(int step)? onFlick;

  final VoidCallback? onLongPress;

  final double? minWidth;

  final double padding;

  final double height;

  @override
  State<KeyCell> createState() => _KeyCellState();
}

class _KeyCellState extends State<KeyCell> {
  bool _down = false;
  double _travel = 0;

  @override
  Widget build(BuildContext context) {
    final tint = widget.inert
        ? context.tokens.textMuted
        : _down || widget.armed
        ? context.tokens.accent
        : context.tokens.textSecondary;
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
      onLongPress: hold,
      // The drag and the hold share the tap's detector so the three share one arena entry: a
      // finger that moves or stays takes it and the tap under it is cancelled, rather than
      // both firing. Travel counts from the first pixel, slop included.
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
        // A container that centres its child fills whatever it is handed; the align below does
        // the centring instead, so a cell with a floor of its own takes its width from its
        // label.
        alignment: widget.minWidth == null ? Alignment.center : null,
        child: Align(
          widthFactor: widget.minWidth == null ? null : 1,
          heightFactor: 1,
          child: Semantics(
            label: widget.locked
                ? '${widget.label} latched'
                : widget.repeat > 1
                ? '${widget.label} x${widget.repeat}'
                : widget.label,
            child: icon == null
                ? _RollingLabel(
                    text: label,
                    style: context.tokens.panelHeader.copyWith(color: tint),
                  )
                : DazzleIcon(icon, size: IconSizes.toolbar, color: tint),
          ),
        ),
      ),
    );
  }
}

class _RollingLabel extends StatefulWidget {
  const _RollingLabel({required this.text, required this.style});

  final String text;
  final TextStyle style;

  @override
  State<_RollingLabel> createState() => _RollingLabelState();
}

class _RollingLabelState extends State<_RollingLabel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _roll =
      AnimationController(vsync: this, duration: Motion.fast)
        ..addStatusListener((status) {
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
          // The arriving word sizes the stack; the one leaving is laid over it and translated by
          // its whole height, so a longer word going out never measures the cell.
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
