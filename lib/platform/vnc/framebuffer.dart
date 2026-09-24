import 'dart:typed_data';

import 'rfb_messages.dart';

/// The byte order is `bgra8888`, so the three colour bytes of a BGRX pixel land where
/// they already are. Only the fourth is this app's business: the server sends nothing in
/// it, and a zero there is a fully transparent pixel once Flutter reads the buffer.
class Framebuffer {
  Framebuffer(this.width, this.height)
    : pixels = Uint8List(width * height * Rfb.bytesPerPixel) {
    _fillAlpha(0, pixels.length);
  }

  int width;
  int height;
  Uint8List pixels;
  Uint32List? _words;

  /// The same bytes a pixel at a time, as `0xAARRGGBB` on the little-endian hosts this
  /// runs on.
  Uint32List get words => _words ??= pixels.buffer.asUint32List();

  int get stride => width * Rfb.bytesPerPixel;

  int offsetOf(int x, int y) => y * stride + x * Rfb.bytesPerPixel;

  /// The old contents are dropped rather than scaled: the server follows a resize with a
  /// full update of the new geometry.
  void resize(int newWidth, int newHeight) {
    if (newWidth == width && newHeight == height) return;
    width = newWidth;
    height = newHeight;
    pixels = Uint8List(width * height * Rfb.bytesPerPixel);
    _words = null;
    _fillAlpha(0, pixels.length);
  }

  void blitRaw(Uint8List source, int x, int y, int w, int h) {
    final rowBytes = w * Rfb.bytesPerPixel;
    for (var row = 0; row < h; row++) {
      final target = offsetOf(x, y + row);
      pixels.setRange(target, target + rowBytes, source, row * rowBytes);
      _fillAlpha(target, target + rowBytes);
    }
  }

  /// The source and the destination are the same buffer and may overlap — a window dragged
  /// one pixel is the common case — so every row goes through a scratch line rather than
  /// trusting a self-overlapping `setRange`.
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

  void fill(int x, int y, int w, int h, int blue, int green, int red) =>
      fillWord(x, y, w, h, word(blue, green, red));

  void fillWord(int x, int y, int w, int h, int pixel) {
    final words = this.words;
    for (var row = 0; row < h; row++) {
      final at = (y + row) * width + x;
      words.fillRange(at, at + w, pixel);
    }
  }

  static int word(int blue, int green, int red) =>
      0xFF000000 | red << 16 | green << 8 | blue;

  void _fillAlpha(int from, int to) {
    for (var at = from + 3; at < to; at += Rfb.bytesPerPixel) {
      pixels[at] = 0xFF;
    }
  }
}
