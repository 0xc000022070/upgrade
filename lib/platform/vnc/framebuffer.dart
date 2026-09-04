import 'dart:typed_data';

import 'rfb_messages.dart';

/// One framebuffer: a single `Uint8List` sized by `ServerInit` or
/// `DesktopSize`, rects blitted in, and one image per update, never one per
/// rect.
///
/// The byte order is `bgra8888`, so the three colour bytes of a BGRX pixel land
/// where they already are. Only the fourth is this app's business: the server
/// sends nothing meaningful in it, and a zero there is a fully transparent
/// pixel once Flutter reads the buffer — a black screen that looks exactly like
/// a connection that never painted.
class Framebuffer {
  Framebuffer(this.width, this.height)
    : pixels = Uint8List(width * height * Rfb.bytesPerPixel) {
    _fillAlpha(0, pixels.length);
  }

  int width;
  int height;
  Uint8List pixels;

  int get stride => width * Rfb.bytesPerPixel;

  int offsetOf(int x, int y) => y * stride + x * Rfb.bytesPerPixel;

  /// A `DesktopSize` resize. The old contents are dropped rather than scaled:
  /// the server follows a resize with a full update of the new geometry, and a
  /// stretched frame in between is a worse lie than one black frame.
  void resize(int newWidth, int newHeight) {
    if (newWidth == width && newHeight == height) return;
    width = newWidth;
    height = newHeight;
    pixels = Uint8List(width * height * Rfb.bytesPerPixel);
    _fillAlpha(0, pixels.length);
  }

  /// A `Raw` rect: `w * h` BGRX pixels, rows top to bottom.
  void blitRaw(Uint8List source, int x, int y, int w, int h) {
    final rowBytes = w * Rfb.bytesPerPixel;
    for (var row = 0; row < h; row++) {
      final target = offsetOf(x, y + row);
      pixels.setRange(target, target + rowBytes, source, row * rowBytes);
      _fillAlpha(target, target + rowBytes);
    }
  }

  /// `CopyRect`. The source and the destination are the same buffer and may
  /// overlap — a window dragged one pixel is the common case — so every row
  /// goes through a scratch line rather than trusting a self-overlapping
  /// `setRange`.
  void copyRect({
    required int sourceX,
    required int sourceY,
    required int x,
    required int y,
    required int w,
    required int h,
  }) {
    final rowBytes = w * Rfb.bytesPerPixel;
    final scratch = Uint8List(rowBytes);
    for (var row = 0; row < h; row++) {
      final from = offsetOf(sourceX, sourceY + row);
      final to = offsetOf(x, y + row);
      scratch.setRange(0, rowBytes, pixels, from);
      pixels.setRange(to, to + rowBytes, scratch);
    }
  }

  /// One colour over a whole rect — ZRLE's solid tile, and the fill every RLE
  /// run reduces to.
  void fill(int x, int y, int w, int h, int blue, int green, int red) {
    for (var row = 0; row < h; row++) {
      var at = offsetOf(x, y + row);
      for (var column = 0; column < w; column++) {
        pixels[at] = blue;
        pixels[at + 1] = green;
        pixels[at + 2] = red;
        pixels[at + 3] = 0xFF;
        at += Rfb.bytesPerPixel;
      }
    }
  }

  void _fillAlpha(int from, int to) {
    for (var at = from + 3; at < to; at += Rfb.bytesPerPixel) {
      pixels[at] = 0xFF;
    }
  }
}
