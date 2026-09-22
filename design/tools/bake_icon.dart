import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dazzle/design/ascii/braille.dart';
import 'package:dazzle/design/ascii/kitten.dart';

const _ground = [0x08, 0x09, 0x0B];
const _figure = [0xE8, 0xE8, 0xE3];

const _adaptiveFraction = 58 / 108;
const _legacyFraction = 58 / 72;

const _cols = 18;
const _rows = 9;

const _cellAspect = 2.0;

const _pose = KittenPose(yaw: 0.12, scale: 0.95);

const _samples = 3;

const _cellWidth = 6.0;
const _dotPitch = _cellWidth / brailleCols;

const _dotRadius = _dotPitch * 0.5 * 0.82;

class _Density {
  const _Density(this.dir, this.adaptive, this.legacy);

  final String dir;

  final int adaptive;
  final int legacy;
}

const _densities = [
  _Density('mdpi', 108, 48),
  _Density('hdpi', 162, 72),
  _Density('xhdpi', 216, 96),
  _Density('xxhdpi', 324, 144),
  _Density('xxxhdpi', 432, 192),
];

Uint8List _grid() {
  final width = _cols * brailleCols;
  final height = _rows * brailleRows;
  final frame = renderKitten(
    width: width,
    height: height,
    rowPitch: 1.0,
    pose: _pose,
    samples: _samples,
  );
  final out = Uint8List(_cols * _rows);
  for (var y = 0; y < _rows; y++) {
    for (var x = 0; x < _cols; x++) {
      out[y * _cols + x] = brailleCell(frame.shade, width, x, y);
    }
  }
  return out;
}

class _Layout {
  const _Layout(this.cell, this.x, this.y);

  final double cell;
  final double x;
  final double y;
}

double _quadrant(double a, double b, double r) {
  final ax = min(a, r);
  final by = min(b, r);
  if (ax <= 0 || by <= 0) return 0;

  final cross = sqrt(max(0.0, r * r - by * by));
  if (ax <= cross) return ax * by;

  double arc(double x) =>
      0.5 *
      (x * sqrt(max(0.0, r * r - x * x)) +
          r * r * asin((x / r).clamp(-1.0, 1.0)));
  return cross * by + arc(ax) - arc(cross);
}

double _corner(double x, double y, double r) =>
    (x < 0 ? -1 : 1) * (y < 0 ? -1 : 1) * _quadrant(x.abs(), y.abs(), r);

void _splat(Float64List cover, int size, double cx, double cy, double r) {
  final fromX = max(0, (cx - r).floor());
  final toX = min(size - 1, (cx + r).ceil());
  final fromY = max(0, (cy - r).floor());
  final toY = min(size - 1, (cy + r).ceil());
  for (var py = fromY; py <= toY; py++) {
    final y0 = py - cy;
    final y1 = y0 + 1.0;
    for (var px = fromX; px <= toX; px++) {
      final x0 = px - cx;
      final x1 = x0 + 1.0;
      final area =
          _corner(x1, y1, r) -
          _corner(x0, y1, r) -
          _corner(x1, y0, r) +
          _corner(x0, y0, r);
      if (area > 0) cover[py * size + px] += area;
    }
  }
}

Uint8List _raster(Uint8List grid, int size, _Layout at) {
  final cover = Float64List(size * size);
  final unit = at.cell / _cellWidth;

  for (var gy = 0; gy < _rows; gy++) {
    for (var gx = 0; gx < _cols; gx++) {
      final bits = grid[gy * _cols + gx];
      if (bits == 0) continue;
      final left = at.x + gx * at.cell;
      final top = at.y + gy * at.cell * _cellAspect;
      for (var row = 0; row < brailleRows; row++) {
        for (var col = 0; col < brailleCols; col++) {
          if (bits & (1 << brailleBit(col, row)) == 0) continue;
          _splat(
            cover,
            size,
            left + (col + 0.5) * _dotPitch * unit,
            top + (row + 0.5) * _dotPitch * unit,
            _dotRadius * unit,
          );
        }
      }
    }
  }

  final out = Uint8List(size * size);
  for (var i = 0; i < out.length; i++) {
    out[i] = (cover[i] * 255).round().clamp(0, 255);
  }
  return out;
}

class _Bounds {
  const _Bounds(this.minX, this.minY, this.maxX, this.maxY);

  final int minX;
  final int minY;
  final int maxX;
  final int maxY;

  bool get empty => maxX < minX;
  int get extent => max(maxX - minX + 1, maxY - minY + 1);
  double get centreX => (minX + maxX) / 2;
  double get centreY => (minY + maxY) / 2;
}

_Bounds _bounds(Uint8List alpha, int size) {
  var minX = size, minY = size, maxX = -1, maxY = -1;
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      if (alpha[y * size + x] == 0) continue;
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }
  }
  return _Bounds(minX, minY, maxX, maxY);
}

_Layout _solve(Uint8List grid, int size, double fraction) {
  final target = fraction * size;
  final centre = (size - 1) * 0.5;

  var cells = _Bounds(_cols, _rows, -1, -1);
  for (var y = 0; y < _rows; y++) {
    for (var x = 0; x < _cols; x++) {
      if (grid[y * _cols + x] == 0) continue;
      cells = _Bounds(
        min(cells.minX, x),
        min(cells.minY, y),
        max(cells.maxX, x),
        max(cells.maxY, y),
      );
    }
  }
  if (cells.empty) throw StateError('the figure marched to nothing');

  var cell =
      target /
      max(
        cells.maxX - cells.minX + 1,
        (cells.maxY - cells.minY + 1) * _cellAspect,
      );
  var at = _Layout(
    cell,
    centre - (cells.centreX + 0.5) * cell,
    centre - (cells.centreY + 0.5) * cell * _cellAspect,
  );

  for (var round = 0; round < 6; round++) {
    final box = _bounds(_raster(grid, size, at), size);
    if (box.empty) throw StateError('the figure rastered to nothing');
    final kx = (box.centreX - at.x) / at.cell;
    final ky = (box.centreY - at.y) / at.cell;

    cell = at.cell * (target - 0.5) / box.extent;
    if (round > 0 && box.extent <= target && cell >= at.cell) break;
    at = _Layout(cell, centre - kx * cell, centre - ky * cell);
  }
  return at;
}

Uint8List _flat(int size) {
  final out = Uint8List(size * size * 4);
  for (var i = 0; i < size * size; i++) {
    out[i * 4] = _ground[0];
    out[i * 4 + 1] = _ground[1];
    out[i * 4 + 2] = _ground[2];
    out[i * 4 + 3] = 0xFF;
  }
  return out;
}

Uint8List _tinted(Uint8List alpha, List<int> rgb) {
  final out = Uint8List(alpha.length * 4);
  for (var i = 0; i < alpha.length; i++) {
    out[i * 4] = rgb[0];
    out[i * 4 + 1] = rgb[1];
    out[i * 4 + 2] = rgb[2];
    out[i * 4 + 3] = alpha[i];
  }
  return out;
}

Uint8List _composited(Uint8List alpha) {
  final out = Uint8List(alpha.length * 3);
  for (var i = 0; i < alpha.length; i++) {
    final a = alpha[i] / 255;
    for (var c = 0; c < 3; c++) {
      out[i * 3 + c] = (_ground[c] + (_figure[c] - _ground[c]) * a).round();
    }
  }
  return out;
}

const _signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

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

int _crc32(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (final b in bytes) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >>> 8);
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

List<int> _be32(int v) => [
  (v >>> 24) & 0xFF,
  (v >>> 16) & 0xFF,
  (v >>> 8) & 0xFF,
  v & 0xFF,
];

List<int> _chunk(String type, List<int> body) {
  final payload = <int>[...ascii.encode(type), ...body];
  return [..._be32(body.length), ...payload, ..._be32(_crc32(payload))];
}

Uint8List _png(int size, Uint8List pixels, {required bool alpha}) {
  final stride = size * (alpha ? 4 : 3);
  final raw = Uint8List((stride + 1) * size);
  for (var y = 0; y < size; y++) {
    raw.setRange(
      y * (stride + 1) + 1,
      (y + 1) * (stride + 1),
      pixels,
      y * stride,
    );
  }
  return Uint8List.fromList([
    ..._signature,
    ..._chunk('IHDR', [
      ..._be32(size),
      ..._be32(size),
      8,
      alpha ? 6 : 2,
      0,
      0,
      0,
    ]),
    ..._chunk('IDAT', ZLibEncoder(level: 9).convert(raw)),
    ..._chunk('IEND', const []),
  ]);
}

void _write(String path, Uint8List bytes) =>
    File(path).writeAsBytesSync(bytes, flush: true);

void main() {
  final clock = Stopwatch()..start();
  final grid = _grid();

  for (final density in _densities) {
    final dir = 'android/app/src/main/res/mipmap-${density.dir}';
    Directory(dir).createSync(recursive: true);

    final figure = _raster(
      grid,
      density.adaptive,
      _solve(grid, density.adaptive, _adaptiveFraction),
    );
    _write(
      '$dir/ic_launcher_background.png',
      _png(density.adaptive, _flat(density.adaptive), alpha: true),
    );
    _write(
      '$dir/ic_launcher_foreground.png',
      _png(density.adaptive, _tinted(figure, _figure), alpha: true),
    );
    _write(
      '$dir/ic_launcher_monochrome.png',
      _png(
        density.adaptive,
        _tinted(figure, const [0xFF, 0xFF, 0xFF]),
        alpha: true,
      ),
    );
    _write(
      '$dir/ic_launcher.png',
      _png(
        density.legacy,
        _composited(
          _raster(
            grid,
            density.legacy,
            _solve(grid, density.legacy, _legacyFraction),
          ),
        ),
        alpha: false,
      ),
    );

    final box = _bounds(figure, density.adaptive);
    final dp = box.extent * 108 / density.adaptive;
    stdout.writeln(
      '${density.dir}: ${density.adaptive}px canvas, '
      'figure ${box.extent}px (${dp.toStringAsFixed(1)}dp)',
    );
  }

  stdout.writeln('baked in ${clock.elapsed.inMilliseconds}ms');
}
