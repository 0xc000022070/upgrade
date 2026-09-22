import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

class _Png {
  const _Png(this.size, this.channels, this.pixels);

  final int size;
  final int channels;
  final Uint8List pixels;

  int at(int x, int y, int channel) =>
      pixels[(y * size + x) * channels + channel];

  static _Png read(String path) {
    final bytes = File(path).readAsBytesSync();
    expect(bytes.sublist(0, 8), [
      0x89,
      0x50,
      0x4E,
      0x47,
      0x0D,
      0x0A,
      0x1A,
      0x0A,
    ], reason: '$path is not a PNG');

    var width = 0, height = 0, channels = 0;
    final idat = BytesBuilder();
    var i = 8;
    while (i < bytes.length) {
      final length = ByteData.sublistView(bytes, i, i + 4).getUint32(0);
      final type = String.fromCharCodes(bytes, i + 4, i + 8);
      final body = Uint8List.sublistView(bytes, i + 8, i + 8 + length);
      final crc = ByteData.sublistView(
        bytes,
        i + 8 + length,
        i + 12 + length,
      ).getUint32(0);
      expect(
        crc,
        _crc32(Uint8List.sublistView(bytes, i + 4, i + 8 + length)),
        reason: '$path: $type is corrupt',
      );

      if (type == 'IHDR') {
        final header = ByteData.sublistView(body);
        width = header.getUint32(0);
        height = header.getUint32(4);
        expect(body[8], 8, reason: '$path is not 8 bits a channel');
        channels = switch (body[9]) {
          2 => 3,
          6 => 4,
          final other => fail('$path has colour type $other'),
        };
      } else if (type == 'IDAT') {
        idat.add(body);
      }
      i += 12 + length;
    }

    expect(width, height, reason: '$path is not square');
    final raw = Uint8List.fromList(ZLibDecoder().convert(idat.takeBytes()));
    final stride = width * channels;
    expect(raw.length, (stride + 1) * height, reason: '$path is short');

    final pixels = Uint8List(stride * height);
    for (var y = 0; y < height; y++) {
      expect(raw[y * (stride + 1)], 0, reason: '$path filters a row');
      pixels.setRange(y * stride, (y + 1) * stride, raw, y * (stride + 1) + 1);
    }
    return _Png(width, channels, pixels);
  }
}

final _crcTable = () {
  final table = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
    }
    table[n] = c;
  }
  return table;
}();

int _crc32(Uint8List bytes) {
  var c = 0xFFFFFFFF;
  for (final b in bytes) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >>> 8);
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

class _Box {
  const _Box(this.minX, this.minY, this.maxX, this.maxY);

  final int minX, minY, maxX, maxY;

  int get extent =>
      (maxX - minX + 1) > (maxY - minY + 1) ? maxX - minX + 1 : maxY - minY + 1;
  double get centreX => (minX + maxX) / 2;
  double get centreY => (minY + maxY) / 2;
}

_Box _figureOf(_Png png, bool Function(_Png png, int x, int y) inked) {
  var minX = png.size, minY = png.size, maxX = -1, maxY = -1;
  for (var y = 0; y < png.size; y++) {
    for (var x = 0; x < png.size; x++) {
      if (!inked(png, x, y)) continue;
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }
  }
  expect(maxX, greaterThanOrEqualTo(minX), reason: 'nothing is drawn');
  return _Box(minX, minY, maxX, maxY);
}

const _ground = [0x08, 0x09, 0x0B];
const _figure = [0xE8, 0xE8, 0xE3];

const _densities = {
  'mdpi': (108, 48),
  'hdpi': (162, 72),
  'xhdpi': (216, 96),
  'xxhdpi': (324, 144),
  'xxxhdpi': (432, 192),
};

String _path(String density, String name) =>
    'android/app/src/main/res/mipmap-$density/$name.png';

void main() {
  group('the launcher icon', () {
    test('every density ships all four layers at its own resolution', () {
      _densities.forEach((density, sizes) {
        final (adaptive, legacy) = sizes;
        for (final layer in [
          'ic_launcher_background',
          'ic_launcher_foreground',
          'ic_launcher_monochrome',
        ]) {
          final png = _Png.read(_path(density, layer));
          expect(png.size, adaptive, reason: '$density/$layer');
          expect(png.channels, 4, reason: '$density/$layer carries no alpha');
        }
        final png = _Png.read(_path(density, 'ic_launcher'));
        expect(png.size, legacy, reason: '$density/ic_launcher');
        expect(png.channels, 3, reason: 'the legacy icon is composited');
      });
    });

    test('the figure fits the 58dp box, centred, at every density', () {
      _densities.forEach((density, sizes) {
        final adaptive = sizes.$1;
        final png = _Png.read(_path(density, 'ic_launcher_foreground'));
        final box = _figureOf(png, (p, x, y) => p.at(x, y, 3) > 0);

        expect(
          box.extent * 108 / adaptive,
          lessThanOrEqualTo(58.0),
          reason: '$density overruns the box',
        );
        final centre = (adaptive - 1) / 2;
        final slack = adaptive / 108;
        expect((box.centreX - centre).abs(), lessThanOrEqualTo(slack));
        expect((box.centreY - centre).abs(), lessThanOrEqualTo(slack));
      });
    });

    test('the figure is not a resample of another density', () {
      final small = _Png.read(_path('mdpi', 'ic_launcher_foreground'));
      final large = _Png.read(_path('xxxhdpi', 'ic_launcher_foreground'));

      Set<int> shades(_Png png) => {
        for (var i = 0; i < png.size * png.size; i++)
          if (png.pixels[i * 4 + 3] > 0) png.pixels[i * 4 + 3],
      };

      expect(shades(large).length, greaterThan(shades(small).length));
    });

    test('the background is the flat ground and nothing else', () {
      final png = _Png.read(_path('xhdpi', 'ic_launcher_background'));
      for (var y = 0; y < png.size; y++) {
        for (var x = 0; x < png.size; x++) {
          expect(
            [
              png.at(x, y, 0),
              png.at(x, y, 1),
              png.at(x, y, 2),
              png.at(x, y, 3),
            ],
            [..._ground, 0xFF],
            reason: 'at $x,$y',
          );
        }
      }
    });

    test(
      'the figure takes the palette colour and the monochrome its alpha',
      () {
        final foreground = _Png.read(_path('xhdpi', 'ic_launcher_foreground'));
        final monochrome = _Png.read(_path('xhdpi', 'ic_launcher_monochrome'));

        expect(monochrome.size, foreground.size);
        for (var i = 0; i < foreground.size * foreground.size; i++) {
          expect(monochrome.pixels[i * 4 + 3], foreground.pixels[i * 4 + 3]);
          if (foreground.pixels[i * 4 + 3] == 0) continue;
          expect(
            foreground.pixels.sublist(i * 4, i * 4 + 3),
            _figure,
            reason: 'the figure is one colour and the shade is the alpha',
          );
        }
      },
    );

    test('the legacy icon is opaque and holds the figure at its own size', () {
      _densities.forEach((density, sizes) {
        final legacy = sizes.$2;
        final png = _Png.read(_path(density, 'ic_launcher'));
        final box = _figureOf(
          png,
          (p, x, y) =>
              p.at(x, y, 0) != _ground[0] ||
              p.at(x, y, 1) != _ground[1] ||
              p.at(x, y, 2) != _ground[2],
        );

        final box58 = legacy * 58 / 72;
        expect(
          box.extent,
          lessThanOrEqualTo(box58 + 2),
          reason: '$density overruns the box',
        );
        expect(
          box.extent,
          greaterThan(box58 - 4),
          reason: '$density draws it too small to read',
        );
      });
    });
  });
}
