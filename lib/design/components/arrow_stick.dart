import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/design/icons/upgrade_icon.dart';
import 'package:upgrade/design/icons/upgrade_icons.dart';
import 'package:upgrade/design/spacing.dart';

const _hysteresis = 1.4;

const _glyph = IconSizes.affordance;

class ArrowStick extends StatefulWidget {
  const ArrowStick({
    super.key,
    required this.onArrow,
    this.width = TapTargets.minHeight,
    this.height = TapTargets.minHeight,
  });

  final void Function(AxisDirection direction) onArrow;

  final double width;

  final double height;

  @override
  State<ArrowStick> createState() => _ArrowStickState();
}

class _ArrowStickState extends State<ArrowStick> {
  int? _pointer;
  Offset _origin = Offset.zero;
  AxisDirection? _held;
  final _repeat = KeyRepeat();

  @override
  void dispose() {
    _repeat.stop();
    super.dispose();
  }

  void _down(PointerDownEvent event) {
    if (_pointer != null) return;
    _pointer = event.pointer;
    _origin = event.localPosition;
  }

  void _move(PointerMoveEvent event) {
    if (event.pointer != _pointer) return;
    final next = _aim(event.localPosition - _origin);
    if (next == _held) return;
    _hold(next);
  }

  void _lift(PointerEvent event) {
    if (event.pointer != _pointer) return;
    _pointer = null;
    _hold(null);
  }

  AxisDirection? _aim(Offset travel) {
    final held = _held;
    final reach = travel.distance;
    if (held == null && reach < Gestures.stick) return null;
    if (held != null && reach < Gestures.stick / 2) return null;
    final dx = travel.dx.abs();
    final dy = travel.dy.abs();
    final heldHorizontal =
        held == AxisDirection.left || held == AxisDirection.right;
    final horizontal = held == null
        ? dx >= dy
        : heldHorizontal
        ? dy <= dx * _hysteresis
        : dx > dy * _hysteresis;
    if (horizontal) {
      return travel.dx < 0 ? AxisDirection.left : AxisDirection.right;
    }
    return travel.dy < 0 ? AxisDirection.up : AxisDirection.down;
  }

  void _hold(AxisDirection? direction) {
    _repeat.stop();
    setState(() => _held = direction);
    if (direction == null) return;
    widget.onArrow(direction);
    _repeat.start(() => widget.onArrow(direction));
  }

  @override
  Widget build(BuildContext context) {
    Widget arm(AxisDirection direction, UpgradeIcons icon, Alignment at) =>
        Align(
          alignment: at,
          child: UpgradeIcon(
            icon,
            size: _glyph,
            color: _held == direction
                ? context.tokens.accent
                : context.tokens.textSecondary,
          ),
        );
    // The stick takes the pointer the moment it lands, so neither the row's scroll nor the
    // route's own gestures get a drag that starts on it.
    return RawGestureDetector(
      gestures: {
        EagerGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<EagerGestureRecognizer>(
              EagerGestureRecognizer.new,
              (_) {},
            ),
      },
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _down,
        onPointerMove: _move,
        onPointerUp: _lift,
        onPointerCancel: _lift,
        child: Semantics(
          label: 'ARROWS',
          excludeSemantics: true,
          child: SizedBox(
            width: widget.width,
            height: widget.height,
            child: Padding(
              padding: const EdgeInsets.all(Spacing.sm),
              child: Stack(
                children: [
                  arm(
                    AxisDirection.up,
                    UpgradeIcons.arrowUp,
                    Alignment.topCenter,
                  ),
                  arm(
                    AxisDirection.down,
                    UpgradeIcons.arrowDown,
                    Alignment.bottomCenter,
                  ),
                  arm(
                    AxisDirection.left,
                    UpgradeIcons.arrowLeft,
                    Alignment.centerLeft,
                  ),
                  arm(
                    AxisDirection.right,
                    UpgradeIcons.arrowRight,
                    Alignment.centerRight,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
