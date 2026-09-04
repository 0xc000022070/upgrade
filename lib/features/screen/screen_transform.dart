import 'dart:ui';

/// The view of the framebuffer: fit to the width, zoomable about
/// a pinch centre, pannable once it overflows.
///
/// Immutable and widget-free so the mapping the spec asks for a test on — touch
/// to framebuffer coordinates, at fit and under zoom — can be checked as
/// arithmetic instead of through a gesture.
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

  /// 1.0 is the fit. Never below: the framebuffer is never drawn smaller
  /// than the width it was fitted to, so there is no state with black bars on
  /// both sides and nothing to pan.
  final double zoom;

  /// The top-left of the scaled framebuffer in viewport coordinates, before
  /// clamping. Held raw so a pinch that pushes past an edge and comes back does
  /// not lose where it was.
  final Offset pan;

  /// "the framebuffer scaled to fit the width".
  double get fitScale =>
      framebuffer.width == 0 ? 1.0 : viewport.width / framebuffer.width;

  double get scale => fitScale * zoom;

  Size get scaledSize =>
      Size(framebuffer.width * scale, framebuffer.height * scale);

  /// Where the image actually lands: centred on any axis with room to spare,
  /// and clamped to the edges on any axis that overflows.
  Offset get origin {
    final size = scaledSize;
    return Offset(
      _axis(viewport.width, size.width, pan.dx),
      _axis(viewport.height, size.height, pan.dy),
    );
  }

  /// A behaviour hangs off this: a two-finger drag pans when there is
  /// something to pan and sends wheel events when there is not.
  bool get canPan {
    final size = scaledSize;
    return size.width > viewport.width || size.height > viewport.height;
  }

  /// A touch in the viewport, as a framebuffer pixel. Clamped, because a tap on
  /// the black ground beside the image is still a tap the host should get —
  /// at the edge nearest to it.
  Offset toFramebuffer(Offset local) {
    if (scale == 0) return Offset.zero;
    final at = (local - origin) / scale;
    return Offset(
      at.dx.clamp(0.0, framebuffer.width - 1),
      at.dy.clamp(0.0, framebuffer.height - 1),
    );
  }

  /// "pinch zooms about the pinch centre" — the framebuffer pixel under
  /// the fingers stays under them.
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
    // From [origin], not from [pan]: a drag that ran into an edge starts its
    // way back from the edge rather than from wherever the raw offset drifted.
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
    // A resized desktop is a different picture: the old zoom would frame a
    // part of it nobody chose.
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
