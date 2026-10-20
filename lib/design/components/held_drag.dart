import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

class HeldDrag<T extends Object> extends StatefulWidget {
  const HeldDrag({
    super.key,
    required this.data,
    this.enabled = true,
    this.ghost,
    this.anchor = childDragAnchorStrategy,
    required this.child,
  });

  final T data;
  final bool enabled;

  final Widget Function(BuildContext context, Size size)? ghost;
  final DragAnchorStrategy anchor;
  final Widget child;

  @override
  State<HeldDrag<T>> createState() => _HeldDragState<T>();
}

class _HeldDragState<T extends Object> extends State<HeldDrag<T>> {
  final _size = ValueNotifier<Size?>(null);
  bool _lifted = false;
  _EdgeScroll? _scroll;

  void _start() {
    _size.value = context.size;
    _scroll?.stop();
    _scroll = _EdgeScroll([
      for (final axis in Axis.values) ?Scrollable.maybeOf(context, axis: axis),
    ]);
    setState(() => _lifted = true);
  }

  void _stop() {
    _scroll?.stop();
    _scroll = null;
    if (mounted) setState(() => _lifted = false);
  }

  @override
  void dispose() {
    _size.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LongPressDraggable<T>(
    data: widget.data,
    maxSimultaneousDrags: widget.enabled ? 1 : 0,
    dragAnchorStrategy: widget.anchor,
    onDragStarted: _start,
    onDragEnd: (_) => _stop(),
    feedback: Material(
      type: MaterialType.transparency,
      child: ValueListenableBuilder(
        valueListenable: _size,
        builder: (context, size, child) => switch ((widget.ghost, size)) {
          (final ghost?, final size?) => ghost(context, size),
          _ => SizedBox(width: size?.width, child: child),
        },
        child: Opacity(opacity: 0.9, child: widget.child),
      ),
    ),
    child: Opacity(opacity: _lifted ? 0.3 : 1, child: widget.child),
  );
}

/// Runs off the pointer itself, so it keeps scrolling after the list has
/// recycled the card being dragged.
class _EdgeScroll {
  _EdgeScroll(this.scrollables) {
    GestureBinding.instance.pointerRouter.addGlobalRoute(_route);
    _timer = Timer.periodic(const Duration(milliseconds: 16), (_) => _tick());
  }
  static const _edge = 56.0;
  final List<ScrollableState> scrollables;
  late final Timer _timer;
  Offset? _at;
  bool _stopped = false;

  void _route(PointerEvent event) {
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      stop();
    } else if (event is PointerMoveEvent) {
      _at = event.position;
    }
  }

  void _tick() {
    final at = _at;
    if (at == null) return;
    for (final scrollable in scrollables) {
      final box = scrollable.mounted
          ? scrollable.context.findRenderObject()
          : null;
      if (box is! RenderBox || !box.hasSize) continue;
      final local = box.globalToLocal(at);
      final horizontal = scrollable.position.axis == Axis.horizontal;
      final along = horizontal ? local.dx : local.dy;
      final extent = horizontal ? box.size.width : box.size.height;
      final across = horizontal ? local.dy : local.dx;
      if (across < 0 ||
          across > (horizontal ? box.size.height : box.size.width)) {
        continue;
      }
      final speed = along < _edge
          ? along - _edge
          : along > extent - _edge
          ? along - extent + _edge
          : 0.0;
      if (speed == 0) continue;
      final position = scrollable.position;
      position.jumpTo(
        (position.pixels + speed / 4).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
      );
    }
  }

  void stop() {
    if (_stopped) return;
    _stopped = true;
    _timer.cancel();
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_route);
  }
}
