import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:upgrade/design/ascii/braille.dart';
import 'package:upgrade/design/ascii/grid.dart';
import 'package:upgrade/design/ascii/kitten.dart';
import 'package:upgrade/design/ascii/noise.dart';

const _cols = 17;
const _rows = 10;

const _rowPitch = 1.0;

const _scale = 0.95;

const _samples = 3;

typedef _Pass = void Function(
  int i,
  int n,
  Float64List shade,
  int width,
  int height,
);

class _State {
  const _State({
    required this.name,
    required this.frames,
    required this.fps,
    required this.loops,
    required this.pose,
    this.pass,
    this.spark = true,
  });

  final String name;
  final int frames;
  final int fps;
  final bool loops;
  final KittenPose Function(int i, int n) pose;
  final _Pass? pass;

  final bool spark;
}

double _turn(int i, int n) => 2 * pi * i / n;

void _band(int i, int n, Float64List shade, int width, int height) {
  final half = height / 12.0;
  final at = (i / n) * (height + 4) - 2;
  for (var y = 0; y < height; y++) {
    final d = (y - at).abs();
    if (d > half) continue;
    final lift = 0.34 * (1.0 - d / half);
    for (var x = 0; x < width; x++) {
      final v = shade[y * width + x];
      if (v > 0) shade[y * width + x] = min(1.0, v + lift);
    }
  }
}

void _displace(int i, int n, Float64List shade, int width, int height) {
  if (i.isEven) return;
  const depth = 10;
  final row = Float64List(width);
  for (var band = 0; band < height; band += depth) {
    final h = hash2(band * 31 + i * 7717, i);
    if (h % 3 != 0) continue;
    final shift = (h >>> 8) % 13 - 6;
    if (shift == 0) continue;
    for (var y = band; y < min(band + depth, height); y++) {
      final base = y * width;
      for (var x = 0; x < width; x++) {
        final from = x - shift;
        row[x] = from < 0 || from >= width ? 0.0 : shade[base + from];
      }
      shade.setRange(base, base + width, row);
    }
  }
}

final _states = <_State>[
  _State(
    name: 'idle',
    frames: 4,
    fps: 2,
    loops: true,
    pose: (i, n) => KittenPose(yaw: 0.08 * sin(_turn(i, n)), scale: _scale),
  ),
  _State(
    name: 'looking',
    frames: 6,
    fps: 4,
    loops: true,
    pose: (i, n) =>
        KittenPose(yaw: 0.10 + 0.45 * sin(_turn(i, n)), scale: _scale),
  ),
  _State(
    name: 'working',
    frames: 8,
    fps: 8,
    loops: true,
    pose: (i, n) => KittenPose(yaw: 0.05 * sin(_turn(i, n)), scale: _scale),
    pass: _band,
  ),
  _State(
    name: 'success',
    frames: 5,
    fps: 6,
    loops: false,
    pose: (i, n) {
      final t = n < 2 ? 1.0 : i / (n - 1);
      return KittenPose(
        yaw: 0.18 * (1.0 - t),
        scale: _scale,
        light: 0.45 + 0.55 * t,
      );
    },
  ),
  _State(
    name: 'blocked',
    frames: 4,
    fps: 2,
    loops: true,
    pose: (i, n) => KittenPose(yaw: -0.06, scale: _scale, light: 0.6),
  ),
  _State(
    name: 'alert',
    frames: 4,
    fps: 4,
    loops: true,
    pose: (i, n) => KittenPose(scale: _scale),
    pass: _displace,
  ),
  _State(
    name: 'sleep',
    frames: 3,
    fps: 2,
    loops: true,
    pose: (i, n) => KittenPose(
      yaw: -0.05 + 0.05 * sin(_turn(i, n)),
      dy: -0.02,
      scale: _scale,
      light: 0.35,
    ),
    spark: false,
  ),
];

AsciiSheet _bake(_State state) {
  const width = _cols * brailleCols;
  const height = _rows * brailleRows;

  final frames = <AsciiFrame>[];
  for (var i = 0; i < state.frames; i++) {
    final rendered = renderKitten(
      width: width,
      height: height,
      rowPitch: _rowPitch,
      pose: state.pose(i, state.frames),
      samples: _samples,
    );
    state.pass?.call(i, state.frames, rendered.shade, width, height);

    final glyphs = Uint8List(_cols * _rows);
    for (var y = 0; y < _rows; y++) {
      for (var x = 0; x < _cols; x++) {
        glyphs[y * _cols + x] = brailleCell(rendered.shade, width, x, y);
      }
    }

    final spark = state.spark ? rendered.spark : null;
    frames.add(
      AsciiFrame(
        glyphs: glyphs,
        sparkX: spark == null ? -1 : spark.x ~/ brailleCols,
        sparkY: spark == null ? -1 : spark.y ~/ brailleRows,
      ),
    );
  }
  return AsciiSheet(
    cols: _cols,
    rows: _rows,
    fps: state.fps,
    loops: state.loops,
    frames: frames,
  );
}

void main() {
  final dir = Directory('assets/sprites/mascot')..createSync(recursive: true);
  final clock = Stopwatch()..start();

  for (final state in _states) {
    final sheet = _bake(state);
    File('${dir.path}/${state.name}.txt').writeAsStringSync(sheet.encode());
    stdout.writeln('${state.name}: ${state.frames} frames at ${_cols}x$_rows');
  }

  final idle = _states.firstWhere((s) => s.name == 'idle');
  final compact = _bake(
    _State(
      name: mascotCompact,
      frames: 1,
      fps: idle.fps,
      loops: false,
      pose: (i, n) => idle.pose(0, idle.frames),
    ),
  );
  File('${dir.path}/$mascotCompact.txt').writeAsStringSync(compact.encode());
  stdout.writeln('$mascotCompact: 1 frame');

  stdout.writeln('baked in ${clock.elapsed.inMilliseconds}ms');
}
