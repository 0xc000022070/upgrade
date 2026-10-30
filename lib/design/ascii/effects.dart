import 'dart:math';
import 'dart:typed_data';

import 'package:upgrade/design/ascii/noise.dart';
import 'package:upgrade/design/ascii/surge.dart';

const _aspect = 2.0;

abstract class AsciiEffect {
  const AsciiEffect();

  String get name;

  void render(double tick, int width, int height, Float64List out);
}

class LatticeEffect extends AsciiEffect {
  const LatticeEffect();

  static const _surge = Surge(470.0);
  static const _wave = 0.32;
  static const _drift = 0.20;
  static const _driftSurge = 2.0;
  static const _blotchDrift = 0.004;
  static const _blotchSurge = 2.0;
  static const _gain = 1.15;
  static const _gainSurge = 0.55;

  static const _peak = 0.62;

  @override
  String get name => 'lattice';

  @override
  void render(double tick, int width, int height, Float64List out) {
    final drift = _surge.phase(_drift, _driftSurge, tick);
    final blotch = _surge.phase(_blotchDrift, _blotchSurge, tick);
    final gain = _gain + _gainSurge * _surge.level(tick);

    for (var y = 0; y < height; y++) {
      final fy = y * _aspect;
      for (var x = 0; x < width; x++) {
        final sweep = (x + 2.0 * fy) * _wave - drift;
        final band = 0.5 + 0.5 * sin(sweep);
        final b2 = band * band;
        final b8 = b2 * b2 * b2 * b2;
        final blot = 0.78 + 0.32 * valueNoise(x * 0.055, fy * 0.055 + blotch);
        out[y * width + x] = b8 * blot * gain * _peak;
      }
    }
  }
}

class FlowEffect extends AsciiEffect {
  const FlowEffect();

  static const _surge = Surge(550.0);
  static const _scale = 0.020;
  static const _driftX = 0.018;
  static const _driftY = 0.006;
  static const _driftSurge = 2.6;
  static const _contours = 4.0;
  static const _contourDrift = 0.05;
  static const _contourSurge = 3.4;
  static const _clumpDrift = 0.02;
  static const _clumpSurge = 2.6;
  static const _halfW = 1.25;
  static const _maxCover = 0.055;
  static const _widenSurge = 0.45;
  static const _octaves = 3;

  @override
  String get name => 'flow';

  double _field(double x, double y) => fbm(x, y, _octaves) * _contours;

  @override
  void render(double tick, int width, int height, Float64List out) {
    final driftX = _surge.phase(_driftX, _driftSurge, tick);
    final driftY = _surge.phase(_driftY, _driftSurge, tick);
    final slide = _surge.phase(_contourDrift, _contourSurge, tick);
    final clumpT = _surge.phase(_clumpDrift, _clumpSurge, tick);
    final widen = 1.0 + _widenSurge * _surge.level(tick);

    for (var y = 0; y < height; y++) {
      final fy = y * _aspect * _scale - driftY;
      for (var x = 0; x < width; x++) {
        final fx = x * _scale + driftX;

        final f = _field(fx, fy);
        final gx = _field(fx + _scale, fy) - f;
        final gy = _field(fx, fy + _scale) - f;
        final grad = max(sqrt(gx * gx + gy * gy), 1e-4);

        final phase = f - slide;
        final off = phase - phase.floorToDouble() - 0.5;
        final half = min(_halfW, _maxCover / grad) * widen;
        final t = (off / grad).abs() / half;
        if (t >= 1.0) continue;

        final ribbon = 1.0 - t * t * t * t;
        final clump =
            0.55 + 0.70 * valueNoise(x * 0.06, y * _aspect * 0.06 + clumpT);
        out[y * width + x] = ribbon * clump;
      }
    }
  }
}

class RingsEffect extends AsciiEffect {
  const RingsEffect();

  static const _surge = Surge(730.0);
  static const _depthK = 38.0;
  static const _halfW = 1.1;
  static const _halfWSurge = 0.8;
  static const _zoom = 0.030;
  static const _zoomSurge = 2.4;
  static const _spin = 0.035;
  static const _spinSurge = 1.6;
  static const _coreDepth = 6.6;

  @override
  String get name => 'rings';

  @override
  void render(double tick, int width, int height, Float64List out) {
    if (width == 0 || height == 0) return;
    final cx = (width - 1) * 0.5;
    final cy = (height - 1) * 0.5;
    final zoom = _surge.phase(_zoom, _zoomSurge, tick);
    final spin = _surge.phase(_spin, _spinSurge, tick);
    final halfW = _halfW + _halfWSurge * _surge.level(tick);

    for (var y = 0; y < height; y++) {
      final dy = (y - cy) * _aspect;
      for (var x = 0; x < width; x++) {
        final dx = x - cx;
        final r = max(sqrt(dx * dx + dy * dy), 0.75);
        final depth = _depthK / r;

        final phase = depth - zoom;
        final off = phase - phase.floorToDouble() - 0.5;
        final dr = off * r * r / _depthK;
        final t = dr.abs() / halfW;
        if (t >= 1.0) continue;

        final ring = 1.0 - t * t * t * t;
        final sweep = 0.93 + 0.07 * cos(atan2(dy, dx) * 2.0 - spin);
        final core = 1.0 / (1.0 + pow(depth / _coreDepth, 8));
        final grain = 0.86 + 0.14 * hash01(x, y);
        out[y * width + x] = ring * sweep * core * grain;
      }
    }
  }
}

const asciiEffects = <AsciiEffect>[
  LatticeEffect(),
  FlowEffect(),
  RingsEffect(),
];
