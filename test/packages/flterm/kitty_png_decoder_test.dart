// ignore_for_file: implementation_imports -- decodePngRgba lives in flterm/src, unexported
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart' show ZLibEncoder, getCrc32;
import 'package:flterm/src/controller/kitty_png_decoder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  final random = Random(7);

  Uint8List reference(Uint8List png) {
    final image = img.decodePng(png)!;
    // package:image scales 2-bit samples by 75, so 3 lands on 225 instead of 255.
    if (image.format == img.Format.uint2 && !image.hasPalette) {
      return Uint8List.fromList([
        for (final pixel in image) ...[
          for (var c = 0; c < 3; c++) pixel.r.toInt() * 85,
          255,
        ],
      ]);
    }
    return image
        .convert(format: img.Format.uint8, numChannels: 4)
        .toUint8List();
  }

  img.Image noise(img.Image image) {
    for (final pixel in image) {
      for (var c = 0; c < pixel.length; c++) {
        pixel[c] = random.nextInt(pixel.maxChannelValue.toInt() + 1);
      }
    }
    return image;
  }

  test('decodes every colour type and depth the way package:image did', () {
    final shapes = <String, img.Image Function()>{
      for (final (depth, format) in [
        (1, img.Format.uint1),
        (2, img.Format.uint2),
        (4, img.Format.uint4),
        (8, img.Format.uint8),
        (16, img.Format.uint16),
      ])
        'gray $depth': () =>
            img.Image(width: 13, height: 7, format: format, numChannels: 1),
      for (final channels in [2, 3, 4])
        for (final (depth, format) in [
          (8, img.Format.uint8),
          (16, img.Format.uint16),
        ])
          '$channels channels $depth': () => img.Image(
            width: 13,
            height: 7,
            format: format,
            numChannels: channels,
          ),
      for (final (depth, format) in [
        (1, img.Format.uint1),
        (2, img.Format.uint2),
        (4, img.Format.uint4),
        (8, img.Format.uint8),
      ])
        'palette $depth': () {
          final image = img.Image(
            width: 13,
            height: 7,
            format: format,
            numChannels: 4,
            withPalette: true,
          );
          final palette = image.palette!;
          for (var i = 0; i < palette.numColors; i++) {
            palette.setRgba(
              i,
              random.nextInt(256),
              random.nextInt(256),
              random.nextInt(256),
              random.nextInt(256),
            );
          }
          for (final pixel in image) {
            pixel.index = random.nextInt(palette.numColors);
          }
          return image;
        },
    };
    for (final MapEntry(key: name, value: make) in shapes.entries) {
      for (final filter in img.PngFilter.values) {
        final image = make();
        final png = img.PngEncoder(filter: filter)
            .encode(image.hasPalette ? image : noise(image));
        final decoded = decodePngRgba(png)!;
        expect((decoded.width, decoded.height), (13, 7), reason: name);
        expect(decoded.rgba, reference(png), reason: '$name, $filter');
      }
    }
  });

  test('decodes an Adam7 interlaced image', () {
    const width = 11, height = 9;
    final pixels = Uint8List.fromList([
      for (var i = 0; i < width * height * 4; i++) random.nextInt(256),
    ]);
    final scanlines = BytesBuilder();
    for (final [x0, y0, dx, dy] in const [
      [0, 0, 8, 8],
      [4, 0, 8, 8],
      [0, 4, 4, 8],
      [2, 0, 4, 4],
      [0, 2, 2, 4],
      [1, 0, 2, 2],
      [0, 1, 1, 2],
    ]) {
      for (var y = y0; y < height; y += dy) {
        if (x0 >= width) break;
        scanlines.addByte(0);
        for (var x = x0; x < width; x += dx) {
          scanlines.add(
            pixels.sublist((y * width + x) * 4, (y * width + x + 1) * 4),
          );
        }
      }
    }
    final png = _png(
      width,
      height,
      colourType: 6,
      interlaced: true,
      data: scanlines.takeBytes(),
    );
    expect(decodePngRgba(png)!.rgba, pixels);
    expect(reference(png), pixels);
  });

  test('keys out the tRNS colour of gray and truecolour images', () {
    final gray = _png(
      3,
      1,
      colourType: 0,
      data: Uint8List.fromList([0, 9, 7, 9]),
      extra: {
        'tRNS': [0, 9],
      },
    );
    expect(decodePngRgba(gray)!.rgba, [9, 9, 9, 0, 7, 7, 7, 255, 9, 9, 9, 0]);
    final rgb = _png(
      2,
      1,
      colourType: 2,
      data: Uint8List.fromList([0, 1, 2, 3, 1, 2, 4]),
      extra: {
        'tRNS': [0, 1, 0, 2, 0, 3],
      },
    );
    expect(decodePngRgba(rgb)!.rgba, [1, 2, 3, 0, 1, 2, 4, 255]);
  });

  test('refuses what it cannot or must not decode', () {
    final idat = Uint8List(1 + 4);
    expect(decodePngRgba(Uint8List.fromList('GIF89a..'.codeUnits)), isNull);
    expect(decodePngRgba(_png(1, 1, colourType: 5, data: idat)), isNull);
    expect(
      decodePngRgba(_png(1, 1, colourType: 3, data: Uint8List(2))),
      isNull,
    );
    expect(decodePngRgba(_png(5000, 5000, colourType: 6, data: idat)), isNull);
    final truncated = img.encodePng(noise(img.Image(width: 4, height: 4)));
    expect(
      () => decodePngRgba(
        Uint8List.sublistView(truncated, 0, truncated.length ~/ 2),
      ),
      throwsA(anything),
    );
  });
}

Uint8List _png(
  int width,
  int height, {
  required int colourType,
  required Uint8List data,
  bool interlaced = false,
  Map<String, List<int>> extra = const {},
}) {
  final out = BytesBuilder()..add(const [137, 80, 78, 71, 13, 10, 26, 10]);
  void chunk(String kind, List<int> body) {
    final typed = [...kind.codeUnits, ...body];
    out
      ..add((ByteData(4)..setUint32(0, body.length)).buffer.asUint8List())
      ..add(typed)
      ..add((ByteData(4)..setUint32(0, getCrc32(typed))).buffer.asUint8List());
  }

  final header = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8)
    ..setUint8(9, colourType)
    ..setUint8(12, interlaced ? 1 : 0);
  chunk('IHDR', header.buffer.asUint8List());
  extra.forEach(chunk);
  chunk('IDAT', ZLibEncoder().encodeBytes(data));
  chunk('IEND', const []);
  return out.takeBytes();
}
