import 'dart:math' as math;
import 'dart:ui';

typedef CropRect = ({int left, int top, int width, int height});

/// Anything under it is a finger that did not move, not a selection.
const minimumCrop = 8;

class ScreenTransform {
  const ScreenTransform({
    required this.framebuffer,
    required this.viewport,
    this.zoom = 1.0,
    this.pan = Offset.zero,
  });

  static const maxZoom = 8.0;

  final Size framebuffer;
  final Size viewport;

  /// 1.0 is the fit. Never below: the framebuffer is never drawn smaller than the width it
  /// was fitted to, so there is no state with black bars on both sides and nothing to pan.
  final double zoom;

  /// Held raw so a pinch that pushes past an edge and comes back does not lose where it was.
  final Offset pan;

  double get fitScale =>
      framebuffer.width == 0 ? 1.0 : viewport.width / framebuffer.width;

  double get scale => fitScale * zoom;

  Size get scaledSize =>
      Size(framebuffer.width * scale, framebuffer.height * scale);

  Offset get origin {
    final size = scaledSize;
    return Offset(
      _axis(viewport.width, size.width, pan.dx),
      _axis(viewport.height, size.height, pan.dy),
    );
  }

  bool get canPan {
    final size = scaledSize;
    return size.width > viewport.width || size.height > viewport.height;
  }

  /// Clamped, because a tap on the black ground beside the image is still a tap the host
  /// should get — at the edge nearest to it.
  Offset toFramebuffer(Offset local) {
    if (scale == 0) return Offset.zero;
    final at = (local - origin) / scale;
    return Offset(
      at.dx.clamp(0.0, framebuffer.width - 1),
      at.dy.clamp(0.0, framebuffer.height - 1),
    );
  }

  /// In whatever order the corners came. Null when it is narrower or shorter than
  /// [minimumCrop] once mapped, which a drag on a zoomed-out picture reaches sooner than
  /// one at 1:1.
  CropRect? cropBetween(Offset a, Offset b) {
    if (scale == 0) return null;
    final p = (a - origin) / scale;
    final q = (b - origin) / scale;
    final left = math
        .min(p.dx, q.dx)
        .floor()
        .clamp(0, framebuffer.width)
        .toInt();
    final top = math
        .min(p.dy, q.dy)
        .floor()
        .clamp(0, framebuffer.height)
        .toInt();
    final right = math
        .max(p.dx, q.dx)
        .ceil()
        .clamp(0, framebuffer.width)
        .toInt();
    final bottom = math
        .max(p.dy, q.dy)
        .ceil()
        .clamp(0, framebuffer.height)
        .toInt();
    final width = right - left;
    final height = bottom - top;
    if (width < minimumCrop || height < minimumCrop) return null;
    return (left: left, top: top, width: width, height: height);
  }

  ScreenTransform zoomedAbout(Offset focus, double factor) {
    final next = (zoom * factor).clamp(1.0, maxZoom);
    if (next == zoom) return this;
    final anchor = toFramebuffer(focus);
    final nextScale = fitScale * next;
    return ScreenTransform(
      framebuffer: framebuffer,
      viewport: viewport,
      zoom: next,
      pan: focus - Offset(anchor.dx * nextScale, anchor.dy * nextScale),
    );
  }

  ScreenTransform pannedBy(Offset delta) => ScreenTransform(
    framebuffer: framebuffer,
    viewport: viewport,
    zoom: zoom,
    // From [origin], not from [pan]: a drag that ran into an edge starts its way back from
    // the edge rather than from wherever the raw offset drifted.
    pan: origin + delta,
  );

  ScreenTransform withViewport(Size next) => ScreenTransform(
    framebuffer: framebuffer,
    viewport: next,
    zoom: zoom,
    pan: pan,
  );

  ScreenTransform withFramebuffer(Size next) => ScreenTransform(
    framebuffer: next,
    viewport: viewport,
    // A resized desktop is a different picture: the old zoom would frame a part of it nobody
    // chose.
    zoom: 1.0,
  );

  @override
  bool operator ==(Object other) =>
      other is ScreenTransform &&
      other.framebuffer == framebuffer &&
      other.viewport == viewport &&
      other.zoom == zoom &&
      other.pan == pan;

  @override
  int get hashCode => Object.hash(framebuffer, viewport, zoom, pan);

  static double _axis(double viewportExtent, double contentExtent, double at) {
    if (contentExtent <= viewportExtent) {
      return (viewportExtent - contentExtent) / 2;
    }
    return at.clamp(viewportExtent - contentExtent, 0.0);
  }
}
