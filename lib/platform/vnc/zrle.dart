import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'framebuffer.dart';
import 'vnc_failure.dart';

/// One zlib stream for the whole session: the server's deflate window spans every rect
/// it has ever sent, so the inflater is opened once and fed for as long as the
/// connection lives. Resetting it desynchronises the stream permanently, and the symptom
/// is a screen that decodes for a second and then turns to noise.
class ZrleDecoder {
  ZrleDecoder() {
    _sink = ZLibDecoder().startChunkedConversion(_collector);
  }

  static const tileSize = 64;

  /// CPIXEL is 3 bytes for this pixel format: all three colour maxima sit inside the low
  /// three bytes, so the fourth carries nothing and is left off the wire. Little-endian
  /// with red at shift 16 puts those bytes in B, G, R order, the framebuffer's own.
  static const cpixelBytes = 3;

  final BytesBuilder _pending = BytesBuilder(copy: false);
  late final Sink<List<int>> _collector = _CollectorSink(_pending);
  late final ByteConversionSink _sink;

  /// The server flushes at every rect boundary, so everything it compressed for this rect
  /// is out by the time [add] returns.
  Uint8List inflate(Uint8List compressed) {
    _sink.add(compressed);
    return _pending.takeBytes();
  }

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
    // Bit 7 is the RLE flag and the low bits are the palette size, which is why the ranges
    // below read the way RFC 6143 tabulates them.
    if (subencoding == 0) {
      for (var i = 0; i < width * height; i++) {
        writer.one(cursor.cpixel());
      }
      return;
    }
    if (subencoding == 1) {
      target.fillWord(x, y, width, height, cursor.cpixel());
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
    // 17..127 and 129 are unused by the encoding and mean the stream is no longer where
    // this decoder thinks it is.
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
    // Each row is packed on its own and padded out to a whole byte, so a 65-pixel-wide tile
    // does not carry its second row's first pixels in its first row's last byte.
    for (var row = 0; row < height; row++) {
      var column = 0;
      while (column < width) {
        final packed = cursor.u8();
        for (var slot = 0; slot < perByte && column < width; slot++, column++) {
          final shift = 8 - bits * (slot + 1);
          writer.one(palette[(packed >> shift) & mask]);
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
      // The high bit says a run length follows; without it the index stands for exactly one
      // pixel.
      final pixel = palette[index & 0x7F];
      if (index & 0x80 == 0) {
        writer.one(pixel);
        written++;
        continue;
      }
      final length = cursor.runLength();
      writer.run(length, pixel);
      written += length;
    }
  }

  void close() {
    try {
      _sink.close();
    } catch (_) {
      // A session torn down mid-stream leaves the inflater with a truncated block, and
      // closing it then throws.
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

  int cpixel() {
    if (_at + ZrleDecoder.cpixelBytes > _data.length) {
      throw VncStreamClosed('zrle rect ended after ${_data.length} bytes');
    }
    final pixel = Framebuffer.word(_data[_at], _data[_at + 1], _data[_at + 2]);
    _at += ZrleDecoder.cpixelBytes;
    return pixel;
  }

  Uint32List palette(int size) {
    final palette = Uint32List(size);
    for (var i = 0; i < size; i++) {
      palette[i] = cpixel();
    }
    return palette;
  }

  /// RFC 6143: a length of one plus every 255 read, ended by the first byte below 255.
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

/// RLE runs are counted in pixels and cross tile rows freely, so the tile's geometry
/// lives here rather than in each subencoding.
class _TileWriter {
  _TileWriter(Framebuffer target, int x, int y, this._width, this._height)
    : _words = target.words,
      _stride = target.width,
      _at = y * target.width + x;

  final Uint32List _words;
  final int _stride;
  final int _width;
  final int _height;
  int _at;
  int _column = 0;
  int _row = 0;

  void one(int pixel) {
    if (_row >= _height) {
      throw VncStreamClosed('zrle run past the tile');
    }
    _words[_at + _column] = pixel;
    if (++_column == _width) {
      _column = 0;
      _row++;
      _at += _stride;
    }
  }

  void run(int count, int pixel) {
    var left = count;
    while (left > 0) {
      if (_row >= _height) {
        throw VncStreamClosed('zrle run past the tile');
      }
      final span = (_width - _column).clamp(0, left);
      final from = _at + _column;
      _words.fillRange(from, from + span, pixel);
      _column += span;
      left -= span;
      if (_column == _width) {
        _column = 0;
        _row++;
        _at += _stride;
      }
    }
  }
}
