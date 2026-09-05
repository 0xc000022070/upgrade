import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../../design/colors.dart';
import '../../design/components/panel.dart';
import '../../design/spacing.dart';
import 'screen_transform.dart';

/// Where a crop goes once it is drawn: the phone's gallery, or the tray in
/// memory that ATTACH on a shell reads from. Never both.
enum CropTarget { save, hold }

/// The framebuffer and every gesture over it.
///
/// The transform is state here rather than on the controller: it is about the
/// view of the screen, not the connection to it, and a reconnect that keeps the
/// zoom the user set is the better behaviour.
class FramebufferView extends StatefulWidget {
  const FramebufferView({
    super.key,
    required this.image,
    required this.framebufferSize,
    required this.onClick,
    required this.onRightClick,
    required this.onDrag,
    required this.onWheel,
    this.cropping = false,
    this.onCrop,
  });

  final ui.Image? image;
  final Size framebufferSize;

  /// While set, one finger draws a box instead of driving the pointer, and
  /// nothing over the picture reaches the host until it is unset.
  final bool cropping;

  /// The box, in framebuffer pixels, once `SAVE` or `HOLD` is tapped under
  /// it, and which of the two.
  final void Function(CropRect rect, CropTarget target)? onCrop;

  /// Framebuffer coordinates, every one of them.
  final void Function(Offset at) onClick;
  final void Function(Offset at) onRightClick;
  final void Function(Offset at, {required bool down}) onDrag;
  final void Function(Offset at, {required bool up}) onWheel;

  @override
  State<FramebufferView> createState() => _FramebufferViewState();
}

class _FramebufferViewState extends State<FramebufferView> {
  ScreenTransform _transform = const ScreenTransform(
    framebuffer: Size.zero,
    viewport: Size.zero,
  );

  /// The `details.scale` of the last update, so a zoom is applied as a ratio
  /// between frames while the gesture's own scale is measured from its start.
  double _lastScale = 1.0;

  /// A two-finger gesture has two meanings and the fingers do not say
  /// which: a pinch changes the span between them, a drag moves both together.
  /// Decided over the whole gesture rather than frame by frame — the two
  /// pointers never move in the same event, so every frame of a two-finger
  /// drag reads as a small pinch on its own.
  _TwoFinger _mode = _TwoFinger.undecided;

  /// How far the span has to leave its starting value, and how far the fingers
  /// have to travel together, before the gesture is one or the other.
  static const _pinchDeadband = 0.25;
  static const _dragDeadband = 20.0;
  double _panTravel = 0.0;

  /// "one button 4/5 press-release per 40 px".
  static const _wheelStep = 40.0;
  double _wheelTravel = 0.0;
  Offset _wheelAt = Offset.zero;

  /// The box being drawn, in local coordinates, and whether the finger has
  /// lifted off a box big enough to keep.
  Offset? _cropStart;
  Offset? _cropEnd;
  bool _cropDrawn = false;

  @override
  void didUpdateWidget(FramebufferView old) {
    super.didUpdateWidget(old);
    if (old.cropping && !widget.cropping) _clearCrop();
  }

  void _clearCrop() {
    _cropStart = null;
    _cropEnd = null;
    _cropDrawn = false;
  }

  Rect? get _cropBox {
    final start = _cropStart;
    final end = _cropEnd;
    if (start == null || end == null) return null;
    return Rect.fromPoints(start, end);
  }

  void _onCropEnd(ScreenTransform transform) {
    final start = _cropStart;
    final end = _cropEnd;
    final rect = start == null || end == null
        ? null
        : transform.cropBetween(start, end);
    // A finger that did not move is not a selection: the box goes, the mode
    // stays, and the next drag is a fresh one.
    setState(() {
      if (rect == null) {
        _clearCrop();
      } else {
        _cropDrawn = true;
      }
    });
  }

  void _take(ScreenTransform transform, CropTarget target) {
    final start = _cropStart;
    final end = _cropEnd;
    if (start == null || end == null) return;
    final rect = transform.cropBetween(start, end);
    setState(_clearCrop);
    if (rect != null) widget.onCrop?.call(rect, target);
  }

  void _sync(Size viewport) {
    if (_transform.viewport != viewport ||
        _transform.framebuffer != widget.framebufferSize) {
      _transform = ScreenTransform(
        framebuffer: widget.framebufferSize,
        viewport: viewport,
        // A resize is a different picture and drops the zoom; a rotation is the
        // same one and keeps it.
        zoom: _transform.framebuffer == widget.framebufferSize
            ? _transform.zoom
            : 1.0,
        pan: _transform.pan,
      );
    }
  }

  void _onScaleStart(ScaleStartDetails details) {
    _lastScale = 1.0;
    _mode = _TwoFinger.undecided;
    _panTravel = 0.0;
    _wheelTravel = 0.0;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    // One finger is a tap, a long press or a long-press drag — never a pan.
    // The single-finger gestures all go to the pointer.
    if (details.pointerCount < 2) return;
    // Accumulated before the gesture is decided, so the travel the deadband
    // spent is still counted once it is.
    _wheelTravel += details.focalPointDelta.dy;
    _panTravel += details.focalPointDelta.distance;
    if (_mode == _TwoFinger.undecided) {
      if ((details.scale - 1.0).abs() > _pinchDeadband) {
        _mode = _TwoFinger.zooming;
      } else if (_panTravel > _dragDeadband) {
        _mode = _TwoFinger.dragging;
      } else {
        return;
      }
    }
    var next = _transform;
    if (_mode == _TwoFinger.zooming) {
      if (details.scale != _lastScale) {
        // Zooming about the current focal point is also what follows the
        // fingers when a pinch drifts across the screen.
        next = next.zoomedAbout(
          details.localFocalPoint,
          details.scale / _lastScale,
        );
        _lastScale = details.scale;
      } else if (next.canPan) {
        next = next.pannedBy(details.focalPointDelta);
      }
      _wheelTravel = 0.0;
    } else if (next.canPan) {
      next = next.pannedBy(details.focalPointDelta);
      _wheelTravel = 0.0;
    } else {
      // At fit, where nothing pans, the drag is a wheel. Dragging the
      // content down is scrolling up, which is button 4.
      _wheelAt = next.toFramebuffer(details.localFocalPoint);
      while (_wheelTravel.abs() >= _wheelStep) {
        final up = _wheelTravel > 0;
        widget.onWheel(_wheelAt, up: up);
        _wheelTravel -= up ? _wheelStep : -_wheelStep;
      }
    }
    if (next != _transform) setState(() => _transform = next);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = Size(constraints.maxWidth, constraints.maxHeight);
        _sync(viewport);
        final transform = _transform;
        final picture = ColoredBox(
          // Black ground, not the app's near-black. The host's own
          // desktop is the only thing lit on this route.
          color: const Color(0xFF000000),
          child: CustomPaint(
            painter: _FramebufferPainter(
              image: widget.image,
              transform: transform,
            ),
            size: viewport,
          ),
        );
        if (widget.cropping) {
          final box = _cropBox;
          return GestureDetector(
            key: const ValueKey('crop-surface'),
            // The pan is the only gesture here. A tap, a long press and a
            // pinch all fall through to nothing, which is the point of a
            // mode whose pointer must not reach the host.
            behavior: HitTestBehavior.opaque,
            onPanStart: (details) => setState(() {
              _cropStart = details.localPosition;
              _cropEnd = details.localPosition;
              _cropDrawn = false;
            }),
            onPanUpdate: (details) =>
                setState(() => _cropEnd = details.localPosition),
            onPanEnd: (_) => _onCropEnd(transform),
            child: Stack(
              children: [
                Positioned.fill(child: picture),
                if (box != null)
                  Positioned.fill(
                    child: CustomPaint(painter: _CropPainter(box: box)),
                  ),
                if (box != null && _cropDrawn)
                  _CropVerbs(
                    box: box,
                    viewport: viewport,
                    onSave: () => _take(transform, CropTarget.save),
                    onHold: () => _take(transform, CropTarget.hold),
                  ),
              ],
            ),
          );
        }
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          // Tap moves the pointer there and left-clicks.
          onTapUp: (details) =>
              widget.onClick(transform.toFramebuffer(details.localPosition)),
          onLongPressStart: (details) => widget.onRightClick(
            transform.toFramebuffer(details.localPosition),
          ),
          // "long press then drag holds button 1 while moving": the right-click
          // has already gone by then, and the drag opens with button 1 down at
          // the first move — which is how a drag out of a context menu behaves
          // on the host too.
          onLongPressMoveUpdate: (details) => widget.onDrag(
            transform.toFramebuffer(details.localPosition),
            down: true,
          ),
          onLongPressEnd: (details) => widget.onDrag(
            transform.toFramebuffer(details.localPosition),
            down: false,
          ),
          onScaleStart: _onScaleStart,
          onScaleUpdate: _onScaleUpdate,
          child: picture,
        );
      },
    );
  }
}

/// Which half of the two-finger sentence a gesture turned out to be.
enum _TwoFinger { undecided, zooming, dragging }

/// The box over the picture: everything outside it dimmed, a hairline of the
/// accent around it. The pixels inside are left exactly as they are, because
/// they are what is about to be kept.
class _CropPainter extends CustomPainter {
  const _CropPainter({required this.box});

  final Rect box;

  @override
  void paint(Canvas canvas, Size size) {
    final outside = Path()
      ..addRect(Offset.zero & size)
      ..addRect(box)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(outside, Paint()..color = const Color(0x99000000));
    canvas.drawRect(
      box,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = Borders.hairline
        ..color = SpectacleColors.accent,
    );
  }

  @override
  bool shouldRepaint(_CropPainter old) => old.box != box;
}

/// `SAVE` and `HOLD` under the box, or over it when the box runs to the
/// bottom edge, and never off the side.
class _CropVerbs extends StatelessWidget {
  const _CropVerbs({
    required this.box,
    required this.viewport,
    required this.onSave,
    required this.onHold,
  });

  final Rect box;
  final Size viewport;
  final VoidCallback onSave;
  final VoidCallback onHold;

  static const _width = 160.0;

  @override
  Widget build(BuildContext context) {
    final below = box.bottom + Spacing.sm;
    final top = below + TapTargets.minHeight <= viewport.height
        ? below
        : (box.top - Spacing.sm - TapTargets.minHeight).clamp(
            0.0,
            viewport.height - TapTargets.minHeight,
          );
    final left = box.left.clamp(
      0.0,
      (viewport.width - _width).clamp(0.0, double.infinity),
    );
    return Positioned(
      left: left,
      top: top,
      width: _width,
      height: TapTargets.minHeight,
      child: Row(
        children: [
          PanelAffordance(
            'SAVE',
            key: const ValueKey('crop-save'),
            showIcon: false,
            color: SpectacleColors.accent,
            onTap: onSave,
          ),
          const SizedBox(width: Spacing.lg),
          PanelAffordance(
            'HOLD',
            key: const ValueKey('crop-hold'),
            showIcon: false,
            color: SpectacleColors.accent,
            onTap: onHold,
          ),
        ],
      ),
    );
  }
}

class _FramebufferPainter extends CustomPainter {
  const _FramebufferPainter({required this.image, required this.transform});

  final ui.Image? image;
  final ScreenTransform transform;

  @override
  void paint(Canvas canvas, Size size) {
    final frame = image;
    if (frame == null) return;
    final origin = transform.origin;
    final scaled = transform.scaledSize;
    canvas.drawImageRect(
      frame,
      Rect.fromLTWH(0, 0, frame.width.toDouble(), frame.height.toDouble()),
      Rect.fromLTWH(origin.dx, origin.dy, scaled.width, scaled.height),
      Paint()
        // 1080p down to a phone's width is a 4x reduction, where nearest
        // sampling turns text into noise; zoomed past 1:1 it is the only
        // sampling that keeps a pixel a pixel.
        ..filterQuality = transform.scale < 1.0
            ? FilterQuality.medium
            : FilterQuality.none,
    );
  }

  @override
  bool shouldRepaint(_FramebufferPainter old) =>
      old.image != image || old.transform != transform;
}

/// The ground behind the framebuffer before there is one: `CONNECTING`
/// has nothing to draw, and a black rectangle is what it draws instead.
class ScreenGround extends StatelessWidget {
  const ScreenGround({super.key, this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: const Color(0xFF000000),
    child: Center(
      child: DefaultTextStyle.merge(
        style: const TextStyle(color: SpectacleColors.textMuted),
        child: child ?? const SizedBox.shrink(),
      ),
    ),
  );
}
