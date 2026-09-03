import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'framebuffer.dart';
import 'vnc_failure.dart';

/// SPEC.md §39.32's ZRLE, RFC 6143 §7.7.6.
///
/// One zlib stream for the whole session, which is the part that cannot be got
/// wrong: the server's deflate window spans every rect it has ever sent, so the
/// inflater is opened once and fed for as long as the connection lives.
/// Resetting it — or decoding a rect with a fresh one — desynchronises the
/// stream permanently, and the symptom is a screen that decodes for a second
/// and then turns to noise.
class ZrleDecoder {
  ZrleDecoder() {
    _sink = ZLibDecoder().startChunkedConversion(_collector);
  }

  static const tileSize = 64;

  /// §39.32: CPIXEL is 3 bytes for this pixel format — 32 bpp, depth 24, and
  /// all three colour maxima inside the low three bytes, so the fourth carries
  /// nothing and is left off the wire. Little-endian with red at shift 16 puts
  /// those three bytes in B, G, R order, which is the framebuffer's own.
  static const cpixelBytes = 3;

  final BytesBuilder _pending = BytesBuilder(copy: false);
  late final Sink<List<int>> _collector = _CollectorSink(_pending);
  late final ByteConversionSink _sink;

  /// Inflates one rect's worth of the session stream.
  ///
  /// The server flushes at every rect boundary, so everything it compressed for
  /// this rect is out by the time [add] returns and nothing is left half-read
  /// inside the inflater.
  Uint8List inflate(Uint8List compressed) {
    _sink.add(compressed);
    return _pending.takeBytes();
  }

  /// Decodes an inflated rect into [target] at ([x], [y]).
  void decodeRect(
    Framebuffer target,
    Uint8List data, {
    required int x,
    required int y,
    required int width,
    required int height,
  }) {
    final cursor = _Cursor(data);
    for (var tileY = 0; tileY < height; tileY += tileSize) {
      final tileHeight = (height - tileY).clamp(0, tileSize);
      for (var tileX = 0; tileX < width; tileX += tileSize) {
        final tileWidth = (width - tileX).clamp(0, tileSize);
        _decodeTile(
          target,
          cursor,
          x: x + tileX,
          y: y + tileY,
          width: tileWidth,
          height: tileHeight,
        );
      }
    }
  }

  void _decodeTile(
    Framebuffer target,
    _Cursor cursor, {
    required int x,
    required int y,
    required int width,
    required int height,
  }) {
    final subencoding = cursor.u8();
    final writer = _TileWriter(target, x, y, width, height);
    // Bit 7 is the RLE flag and the low bits are the palette size, which is
    // why the ranges below read the way RFC 6143 §7.7.6 tabulates them.
    if (subencoding == 0) {
      for (var i = 0; i < width * height; i++) {
        writer.run(1, cursor.cpixel());
      }
      return;
    }
    if (subencoding == 1) {
      final pixel = cursor.cpixel();
      target.fill(x, y, width, height, pixel.blue, pixel.green, pixel.red);
      return;
    }
    if (subencoding >= 2 && subencoding <= 16) {
      _packedPalette(cursor, writer, subencoding, width, height);
      return;
    }
    if (subencoding == 128) {
      _plainRle(cursor, writer, width * height);
      return;
    }
    if (subencoding >= 130) {
      _paletteRle(cursor, writer, subencoding - 128, width * height);
      return;
    }
    // 17..127 and 129 are unused by the encoding and mean the stream is no
    // longer where this decoder thinks it is.
    throw VncStreamClosed('zrle subencoding $subencoding');
  }

  void _packedPalette(
    _Cursor cursor,
    _TileWriter writer,
    int paletteSize,
    int width,
    int height,
  ) {
    final palette = cursor.palette(paletteSize);
    final bits = paletteSize == 2
        ? 1
        : paletteSize <= 4
        ? 2
        : 4;
    final perByte = 8 ~/ bits;
    final mask = (1 << bits) - 1;
    // Each row is packed on its own and padded out to a whole byte, so a
    // 65-pixel-wide tile does not carry its second row's first pixels in its
    // first row's last byte.
    for (var row = 0; row < height; row++) {
      var column = 0;
      while (column < width) {
        final packed = cursor.u8();
        for (var slot = 0; slot < perByte && column < width; slot++, column++) {
          final shift = 8 - bits * (slot + 1);
          writer.run(1, palette[(packed >> shift) & mask]);
        }
      }
    }
  }

  void _plainRle(_Cursor cursor, _TileWriter writer, int pixels) {
    var written = 0;
    while (written < pixels) {
      final pixel = cursor.cpixel();
      final length = cursor.runLength();
      writer.run(length, pixel);
      written += length;
    }
  }

  void _paletteRle(
    _Cursor cursor,
    _TileWriter writer,
    int paletteSize,
    int pixels,
  ) {
    final palette = cursor.palette(paletteSize);
    var written = 0;
    while (written < pixels) {
      final index = cursor.u8();
      // The high bit says a run length follows; without it the index stands
      // for exactly one pixel and costs one byte.
      final length = index & 0x80 != 0 ? cursor.runLength() : 1;
      writer.run(length, palette[index & 0x7F]);
      written += length;
    }
  }

  void close() {
    try {
      _sink.close();
    } catch (_) {
      // A session torn down mid-stream leaves the inflater with a truncated
      // block, and closing it then throws. Nothing downstream cares: the
      // decoder is being discarded.
    }
  }
}

class _CollectorSink implements Sink<List<int>> {
  _CollectorSink(this._target);

  final BytesBuilder _target;

  @override
  void add(List<int> data) => _target.add(data);

  @override
  void close() {}
}

/// One BGR triple out of the stream. A class rather than a packed int because
/// the framebuffer takes the three channels apart anyway.
class ZrlePixel {
  const ZrlePixel(this.blue, this.green, this.red);

  final int blue;
  final int green;
  final int red;
}

class _Cursor {
  _Cursor(this._data);

  final Uint8List _data;
  int _at = 0;

  int u8() {
    if (_at >= _data.length) {
      throw VncStreamClosed('zrle rect ended after ${_data.length} bytes');
    }
    return _data[_at++];
  }

  ZrlePixel cpixel() {
    if (_at + ZrleDecoder.cpixelBytes > _data.length) {
      throw VncStreamClosed('zrle rect ended after ${_data.length} bytes');
    }
    final blue = _data[_at];
    final green = _data[_at + 1];
    final red = _data[_at + 2];
    _at += ZrleDecoder.cpixelBytes;
    return ZrlePixel(blue, green, red);
  }

  List<ZrlePixel> palette(int size) => [for (var i = 0; i < size; i++) cpixel()];

  /// RFC 6143 §7.7.6: a length of one plus every 255 read, ended by the first
  /// byte below 255.
  int runLength() {
    var length = 1;
    var part = u8();
    while (part == 255) {
      length += 255;
      part = u8();
    }
    return length + part;
  }
}

/// Writes runs across a tile, wrapping at its right edge.
///
/// RLE runs are counted in pixels and cross tile rows freely, so the tile's
/// geometry lives here rather than in each subencoding.
class _TileWriter {
  _TileWriter(this._target, this._x, this._y, this._width, this._height);

  final Framebuffer _target;
  final int _x;
  final int _y;
  final int _width;
  final int _height;
  int _column = 0;
  int _row = 0;

  void run(int count, ZrlePixel pixel) {
    var left = count;
    while (left > 0) {
      if (_row >= _height) {
        throw VncStreamClosed('zrle run past the tile');
      }
      final span = (_width - _column).clamp(0, left);
      _target.fill(
        _x + _column,
        _y + _row,
        span,
        1,
        pixel.blue,
        pixel.green,
        pixel.red,
      );
      _column += span;
      left -= span;
      if (_column == _width) {
        _column = 0;
        _row++;
      }
    }
  }
}
