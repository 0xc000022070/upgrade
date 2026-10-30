import 'package:flutter/widgets.dart';

import 'package:upgrade/design/motion.dart';

class SlideSteps extends StatefulWidget {
  const SlideSteps({
    super.key,
    required this.child,
    this.onUp,
    this.onDown,
    this.enabled = true,
  });

  static const threshold = 24.0;
  static const travel = 32.0;

  final Widget child;

  /// Named for the step they take and not for the direction that fires them: a slide left
  /// is up.
  final VoidCallback? onUp;
  final VoidCallback? onDown;

  final bool enabled;

  @override
  State<SlideSteps> createState() => _SlideStepsState();
}

class _SlideStepsState extends State<SlideSteps>
    with SingleTickerProviderStateMixin {
  late final AnimationController _snap = AnimationController(
    vsync: this,
    duration: Motion.fast,
  )..addListener(() => setState(() {}));

  Animation<double>? _returning;
  double _offset = 0;

  @override
  void dispose() {
    _snap.dispose();
    super.dispose();
  }

  double get _position => _returning?.value ?? _offset;

  void _start(DragStartDetails details) {
    _snap.stop();
    setState(() {
      _returning = null;
      _offset = 0;
    });
  }

  void _update(DragUpdateDetails details) {
    setState(() {
      _offset = (_offset + details.delta.dx).clamp(
        widget.onUp == null ? 0.0 : -SlideSteps.travel,
        widget.onDown == null ? 0.0 : SlideSteps.travel,
      );
    });
  }

  void _release({bool commit = true}) {
    final travelled = _offset;
    setState(() {
      _returning = Tween(
        begin: travelled,
        end: 0.0,
      ).animate(CurvedAnimation(parent: _snap, curve: Motion.exit));
      _offset = 0;
    });
    _snap.forward(from: 0);
    if (!commit) return;
    if (travelled <= -SlideSteps.threshold) {
      widget.onUp?.call();
    } else if (travelled >= SlideSteps.threshold) {
      widget.onDown?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return GestureDetector(
      behavior: HitTestBehavior.deferToChild,
      onHorizontalDragStart: _start,
      onHorizontalDragUpdate: _update,
      onHorizontalDragEnd: (_) => _release(),
      onHorizontalDragCancel: () => _release(commit: false),
      child: Transform.translate(
        offset: Offset(_position, 0),
        child: widget.child,
      ),
    );
  }
}
