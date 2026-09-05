/// The ZRLE regression list: vectors for every subencoding, and
/// the one zlib stream that outlives every rect in a session.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:spectacle/platform/vnc/framebuffer.dart';
import 'package:spectacle/platform/vnc/vnc_failure.dart';
import 'package:spectacle/platform/vnc/zrle.dart';

/// A CPIXEL in this session's format: the three low bytes of BGRX, in wire
/// order. RFC 6143 drops the byte the pixel format never reads.
List<int> cpixel(int blue, int green, int red) => [blue, green, red];

const _a = (0x11, 0x22, 0x33);
const _b = (0x44, 0x55, 0x66);
const _c = (0x77, 0x88, 0x99);
const _d = (0xAA, 0xBB, 0xCC);
const _e = (0xDD, 0xEE, 0xFF);

List<int> wire((int, int, int) pixel) => cpixel(pixel.$1, pixel.$2, pixel.$3);

/// What the framebuffer should hold for a pixel: BGR from the wire, alpha
/// forced opaque.
List<int> opaque((int, int, int) pixel) => [pixel.$1, pixel.$2, pixel.$3, 0xFF];

List<int> pixelAt(Framebuffer buffer, int x, int y) {
  final at = buffer.offsetOf(x, y);
  return buffer.pixels.sublist(at, at + 4);
}

/// wayvnc's writer, as far as this decoder can tell: one deflate stream for
/// the whole session, flushed with `Z_SYNC_FLUSH` at the end of every rect and
/// never ended.
class DeflateSession {
  final RawZLibFilter _filter = RawZLibFilter.deflateFilter();

  Uint8List rect(List<int> data) {
    _filter.process(data, 0, data.length);
    final out = BytesBuilder();
    List<int>? part;
    while ((part = _filter.processed(flush: false)) != null) {
      out.add(part!);
    }
    while ((part = _filter.processed(flush: true, end: false)) != null) {
      out.add(part!);
    }
    return out.takeBytes();
  }
}

void main() {
  late Framebuffer buffer;
  late ZrleDecoder decoder;

  setUp(() {
    buffer = Framebuffer(72, 8);
    decoder = ZrleDecoder();
  });

  tearDown(() => decoder.close());

  /// Every subencoding takes the same shape: one tile's bytes, decoded at an
  /// offset that is not the origin so a tile written to the wrong place shows.
  void decodeTile(List<int> data, {int width = 4, int height = 2}) {
    decoder.decodeRect(
      buffer,
      Uint8List.fromList(data),
      x: 4,
      y: 2,
      width: width,
      height: height,
    );
  }

  test('subencoding 0: a raw tile writes its CPIXELs in row order', () {
    decodeTile([
      0,
      ...wire(_a),
      ...wire(_b),
      ...wire(_c),
      ...wire(_d),
      ...wire(_d),
      ...wire(_c),
      ...wire(_b),
      ...wire(_a),
    ]);

    expect(pixelAt(buffer, 4, 2), opaque(_a));
    expect(pixelAt(buffer, 7, 2), opaque(_d));
    expect(pixelAt(buffer, 4, 3), opaque(_d));
    expect(pixelAt(buffer, 7, 3), opaque(_a));
    expect(pixelAt(buffer, 3, 2), [0, 0, 0, 0xFF], reason: 'outside the tile');
  });

  test('subencoding 1: a solid tile fills every pixel from one CPIXEL', () {
    decodeTile([1, ...wire(_b)]);

    for (var y = 2; y < 4; y++) {
      for (var x = 4; x < 8; x++) {
        expect(pixelAt(buffer, x, y), opaque(_b));
      }
    }
  });

  test('subencoding 2: a two-colour palette packs one bit per pixel', () {
    // 0b0110_0000 and 0b1001_0000: four used bits, the rest padding, and each
    // row starts on a byte of its own.
    decodeTile([2, ...wire(_a), ...wire(_b), 0x60, 0x90]);

    expect(
      [for (var x = 4; x < 8; x++) pixelAt(buffer, x, 2)],
      [opaque(_a), opaque(_b), opaque(_b), opaque(_a)],
    );
    expect(
      [for (var x = 4; x < 8; x++) pixelAt(buffer, x, 3)],
      [opaque(_b), opaque(_a), opaque(_a), opaque(_b)],
    );
  });

  test('subencoding 3: a three-colour palette packs two bits per pixel', () {
    // Indices 2, 1, 0 at shifts 6, 4 and 2.
    decodeTile(
      [3, ...wire(_a), ...wire(_b), ...wire(_c), 0x90],
      width: 3,
      height: 1,
    );

    expect(
      [for (var x = 4; x < 7; x++) pixelAt(buffer, x, 2)],
      [opaque(_c), opaque(_b), opaque(_a)],
    );
  });

  test('subencoding 5: a five-colour palette packs four bits per pixel', () {
    decodeTile(
      [
        5,
        ...wire(_a),
        ...wire(_b),
        ...wire(_c),
        ...wire(_d),
        ...wire(_e),
        0x43,
      ],
      width: 2,
      height: 1,
    );

    expect(pixelAt(buffer, 4, 2), opaque(_e));
    expect(pixelAt(buffer, 5, 2), opaque(_d));
  });

  test('subencoding 16: a full palette still packs four bits per pixel', () {
    final palette = <int>[];
    for (var i = 0; i < 16; i++) {
      palette.addAll(cpixel(i, i * 2, i * 3));
    }
    decodeTile([16, ...palette, 0xF0], width: 2, height: 1);

    expect(pixelAt(buffer, 4, 2), [15, 30, 45, 0xFF]);
    expect(pixelAt(buffer, 5, 2), [0, 0, 0, 0xFF]);
  });

  test('subencoding 128: plain RLE runs wrap across the tile rows', () {
    // Five of _a, which crosses the row edge, then three of _b.
    decodeTile([128, ...wire(_a), 4, ...wire(_b), 2]);

    expect(pixelAt(buffer, 7, 2), opaque(_a));
    expect(pixelAt(buffer, 4, 3), opaque(_a), reason: 'the fifth pixel');
    expect(pixelAt(buffer, 5, 3), opaque(_b));
    expect(pixelAt(buffer, 7, 3), opaque(_b));
  });

  test('subencoding 128: a run longer than 255 reads its length in parts', () {
    // 300 of _a then 212 of _b over a whole 64x8 tile: 1 + 255 + 44 and
    // 1 + 211.
    // A whole tile, so it starts at the top: 64 by 8 is every row the
    // framebuffer has.
    decoder.decodeRect(
      buffer,
      Uint8List.fromList([128, ...wire(_a), 255, 44, ...wire(_b), 211]),
      x: 4,
      y: 0,
      width: 64,
      height: 8,
    );

    // Pixel 299 is the last of the first run: row 4, column 43.
    expect(pixelAt(buffer, 4 + 43, 4), opaque(_a));
    expect(pixelAt(buffer, 4 + 44, 4), opaque(_b));
    expect(pixelAt(buffer, 4 + 63, 7), opaque(_b));
  });

  test('subencoding 130: palette RLE mixes single indices and runs', () {
    decodeTile([
      130,
      ...wire(_a), ...wire(_b),
      0x80, 2, // three of palette[0]
      0x01, //    one of palette[1]
      0x81, 3, // four of palette[1]
    ]);

    expect(pixelAt(buffer, 6, 2), opaque(_a));
    expect(pixelAt(buffer, 7, 2), opaque(_b));
    expect(pixelAt(buffer, 4, 3), opaque(_b));
    expect(pixelAt(buffer, 7, 3), opaque(_b));
  });

  test('a rect wider than a tile decodes its tiles left to right', () {
    decoder.decodeRect(
      buffer,
      Uint8List.fromList([1, ...wire(_a), 1, ...wire(_b)]),
      x: 0,
      y: 0,
      width: 68,
      height: 1,
    );

    expect(pixelAt(buffer, 63, 0), opaque(_a));
    expect(pixelAt(buffer, 64, 0), opaque(_b));
    expect(pixelAt(buffer, 67, 0), opaque(_b));
  });

  test('an unused subencoding is a reason line, not a wrong pixel', () {
    expect(
      () => decodeTile([17, ...wire(_a)]),
      throwsA(isA<VncStreamClosed>()),
    );
    expect(
      () => decodeTile([129, ...wire(_a)]),
      throwsA(isA<VncStreamClosed>()),
    );
  });

  test('a rect that ends mid-CPIXEL is a reason line', () {
    expect(() => decodeTile([0, 0x11, 0x22]), throwsA(isA<VncStreamClosed>()));
  });

  group('the session zlib stream', () {
    test('a second rect inflates against the first rect dictionary', () {
      final server = DeflateSession();
      final first = server.rect([1, ...wire(_a)]);
      final second = server.rect([1, ...wire(_b)]);

      decoder.decodeRect(
        buffer,
        decoder.inflate(first),
        x: 0,
        y: 0,
        width: 4,
        height: 1,
      );
      decoder.decodeRect(
        buffer,
        decoder.inflate(second),
        x: 4,
        y: 0,
        width: 4,
        height: 1,
      );

      expect(pixelAt(buffer, 0, 0), opaque(_a));
      expect(pixelAt(buffer, 4, 0), opaque(_b));
    });

    test('a decoder that never saw the first rect cannot read the second', () {
      final server = DeflateSession();
      server.rect([1, ...wire(_a)]);
      final second = server.rect([1, ...wire(_b)]);

      // Which is the whole reason the inflater is never reset: the
      // second rect is a continuation, not a stream.
      final fresh = ZrleDecoder();
      addTearDown(fresh.close);
      expect(() => fresh.inflate(second), throwsA(anything));
    });

    test('an empty flush yields no bytes and leaves the stream usable', () {
      final server = DeflateSession();
      final first = server.rect([1, ...wire(_a)]);
      expect(decoder.inflate(first), isNotEmpty);
      expect(decoder.inflate(Uint8List(0)), isEmpty);

      final second = server.rect([1, ...wire(_c)]);
      decoder.decodeRect(
        buffer,
        decoder.inflate(second),
        x: 0,
        y: 0,
        width: 2,
        height: 1,
      );
      expect(pixelAt(buffer, 0, 0), opaque(_c));
    });
  });

  test('CopyRect survives a source that overlaps its destination', () {
    buffer.fill(0, 0, 4, 1, _a.$1, _a.$2, _a.$3);
    buffer.copyRect(sourceX: 0, sourceY: 0, x: 1, y: 0, w: 4, h: 1);

    expect(pixelAt(buffer, 4, 0), opaque(_a));
  });
}
