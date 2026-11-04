import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';

import 'package:upgrade/design/ascii/noise.dart';
import 'package:upgrade/design/ascii/ramp.dart';
import 'package:upgrade/design/tokens.dart';

abstract class Wallpaper {
  const Wallpaper();

  static const opacity = 0.32;

  List<Color> get ground;

  void render(double tick, Field field);

  static final _tokensOf = <Wallpaper, UpgradeTokens>{};

  UpgradeTokens get tokens => _tokensOf[this] ??= _tokensOn(ground.last);
}

Color _lift(Color ground, double by) => Color.lerp(ground, _white, by)!;

const _white = Color(0xFFFFFFFF);

UpgradeTokens _tokensOn(Color ground) => UpgradeTokens.house.copyWith(
  backgroundPrimary: ground,
  backgroundSecondary: _lift(ground, 0.02),
  surfacePrimary: _lift(ground, 0.05),
  surfaceSecondary: _lift(ground, 0.08),
  borderSubtle: _lift(ground, 0.14),
  borderNormal: _lift(ground, 0.19),
);

class Field {
  Field(this.width, this.height, this.shade, this.colours);

  final int width;
  final int height;
  final Float64List shade;
  final Int32List colours;

  void put(int x, int y, double level, int argb) {
    if (x < 0 || y < 0 || x >= width || y >= height || level <= 0) return;
    final at = y * width + x;
    shade[at] = level;
    colours[at] = argb;
  }
}

/// One lap carries a sprite [width] wide from fully off one edge of a field [columns]
/// wide to fully off the other.
int driftLap(int columns, int width) => columns + width + 1;

int driftLeft(int columns, int width, double along) =>
    (columns - along % driftLap(columns, width)).floor();

int driftRight(int columns, int width, double along) =>
    (along % driftLap(columns, width) - width).floor();

class Sprite {
  Sprite(List<String> rows)
    : width = rows.fold(0, (w, row) => max(w, row.length)),
      height = rows.length,
      _shade = Float64List(
        rows.fold(0, (w, row) => max(w, row.length)) * rows.length,
      ) {
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < rows[y].length; x++) {
        final level = asciiRamp.indexOf(rows[y][x]);
        assert(level >= 0, 'sprite glyph outside the ramp: "${rows[y][x]}"');
        _shade[y * width + x] = level / (asciiLevels - 1);
      }
    }
  }

  final int width;
  final int height;
  final Float64List _shade;

  void stamp(
    Field field,
    int left,
    int top,
    int argb, {
    bool flip = false,
    double gain = 1.0,
  }) {
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final sx = flip ? width - 1 - x : x;
        field.put(left + x, top + y, _shade[y * width + sx] * gain, argb);
      }
    }
  }
}

class Fireflies extends Wallpaper {
  const Fireflies();

  static const _count = 28;
  static const _glow = 0xFFD9FF66;
  static const _grass = 0xFF4E8A4A;

  @override
  List<Color> get ground => const [Color(0xFF0C2016), Color(0xFF060F0A)];

  @override
  void render(double tick, Field field) {
    for (var i = 0; i < _count; i++) {
      final wander = tick * 0.012;
      final x =
          hash01(i, 1) * field.width +
          10 * (valueNoise(i * 5.3 + 0.5, wander) - 0.5);
      final y =
          hash01(i, 2) * field.height * 0.85 +
          5 * (valueNoise(i * 9.1 + 0.5, wander + 50) - 0.5);
      final rate = 0.05 + 0.05 * hash01(i, 3);
      final pulse = 0.5 + 0.5 * sin(tick * rate + hash01(i, 4) * 2 * pi);
      final glow = pulse * pulse * pulse;
      if (glow < 0.08) continue;
      final cx = x.round();
      final cy = y.round();
      field.put(cx, cy, glow, _glow);
      if (glow > 0.7) {
        field.put(cx - 1, cy, glow * 0.2, _glow);
        field.put(cx + 1, cy, glow * 0.2, _glow);
      }
    }
    for (var x = 0; x < field.width; x++) {
      if (hash01(x, 77) > 0.55) field.put(x, field.height - 1, 0.22, _grass);
      if (hash01(x, 78) > 0.8) field.put(x, field.height - 2, 0.15, _grass);
    }
  }
}

class Moonlit extends Wallpaper {
  const Moonlit();

  static const _moonInk = 0xFFE9E4C8;
  static const _cloudInk = 0xFF9AA4D6;
  static const _starInk = 0xFFE8E6D8;

  static final _moon = Sprite([
    r'  .cXWW',
    r' oW$$',
    r' W$$',
    r' oW$$',
    r'  .cXWW',
  ]);

  static final _cloud = Sprite([
    '   .oXXo.',
    ' .oXWWWWXo.',
    'oXWWWWWWWWXo',
    ' :ooXXXXoo:',
  ]);

  static final _puff = Sprite(['  .oXo.', 'oXWWWWXo', ' :oooo:']);

  @override
  List<Color> get ground => const [Color(0xFF0C1434), Color(0xFF070B1E)];

  @override
  void render(double tick, Field field) {
    final skyline = (field.height * 0.6).floor();
    for (var y = 0; y < skyline; y++) {
      for (var x = 0; x < field.width; x++) {
        if (hash01(x, y) < 0.988) continue;
        final twinkle =
            0.35 + 0.35 * sin(tick * 0.25 + hash01(x, y + 1000) * 2 * pi);
        field.put(x, y, twinkle, _starInk);
      }
    }
    _moon.stamp(field, field.width - _moon.width - 5, 2, _moonInk);

    _drift(field, tick, _cloud, 0.18, 0.05, 0.0);
    _drift(field, tick, _puff, 0.36, 0.08, 0.4);
    _drift(field, tick, _cloud, 0.52, 0.035, 0.75);
  }

  static void _drift(
    Field field,
    double tick,
    Sprite sprite,
    double y,
    double speed,
    double phase,
  ) {
    final lap = driftLap(field.width, sprite.width);
    final x = driftLeft(field.width, sprite.width, tick * speed + phase * lap);
    sprite.stamp(field, x, (y * field.height).round(), _cloudInk);
  }
}

class KoiPond extends Wallpaper {
  const KoiPond();

  static const _padInk = 0xFF5FA86A;

  static final _koi = Sprite(['  .cXWMo.', r':oWW$$WMXc.', '  .cXWMo.']);

  static final _pad = Sprite([' oXXo ', 'XWWWWX', ' oXXo ']);

  static const _fish = [
    (ink: 0xFFF08A3C, y: 0.14, speed: 0.11, phase: 0.1, flip: false),
    (ink: 0xFFF2EEE4, y: 0.32, speed: 0.08, phase: 0.6, flip: true),
    (ink: 0xFFD9513A, y: 0.5, speed: 0.13, phase: 0.35, flip: false),
    (ink: 0xFFE8B84A, y: 0.68, speed: 0.07, phase: 0.85, flip: true),
    (ink: 0xFFF08A3C, y: 0.86, speed: 0.1, phase: 0.5, flip: false),
  ];

  static const _pads = [
    (x: 0.12, y: 0.22),
    (x: 0.7, y: 0.58),
    (x: 0.3, y: 0.78),
  ];

  @override
  List<Color> get ground => const [Color(0xFF0F3D3B), Color(0xFF092A29)];

  @override
  void render(double tick, Field field) {
    for (final pad in _pads) {
      _pad.stamp(
        field,
        (pad.x * field.width).round(),
        (pad.y * field.height).round(),
        _padInk,
      );
    }
    final lap = driftLap(field.width, _koi.width);
    for (final fish in _fish) {
      final along = tick * fish.speed + fish.phase * lap;
      final x = fish.flip
          ? driftLeft(field.width, _koi.width, along)
          : driftRight(field.width, _koi.width, along);
      final y =
          fish.y * field.height + 1.5 * sin(tick * 0.06 + fish.phase * 2 * pi);
      _koi.stamp(field, x, y.round(), fish.ink, flip: fish.flip);
    }
  }
}
