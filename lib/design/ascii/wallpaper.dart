import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';

import 'package:upgrade/design/ascii/noise.dart';
import 'package:upgrade/design/ascii/ramp.dart';
import 'package:upgrade/design/tokens.dart';

abstract class Wallpaper {
  const Wallpaper();

  static const cell = 8.0;
  static const fontSize = 10.0;
  static const opacity = 0.85;
  static const bloom = 6.0;

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

typedef Glow = ({double x, double y, double radius, int argb});

/// A cell whose colour is fully opaque is a tile; any other alpha is a bare glyph.
class Field {
  Field(this.width, this.height, this.shade, this.colours);

  final int width;
  final int height;
  final Float64List shade;
  final Int32List colours;
  final glows = <Glow>[];

  static bool isTile(int argb) => (argb >> 24) & 0xFF == 0xFF;

  void put(int x, int y, double level, int argb) {
    if (x < 0 || y < 0 || x >= width || y >= height || level <= 0) return;
    final at = y * width + x;
    shade[at] = level;
    colours[at] = argb;
  }

  void glow(double x, double y, double radius, int argb) =>
      glows.add((x: x, y: y, radius: radius, argb: argb));
}

/// One lap carries a sprite [width] wide from fully off one edge of a field [columns]
/// wide to fully off the other.
int driftLap(int columns, int width) => columns + width + 1;

int driftLeft(int columns, int width, double along) =>
    (columns - along % driftLap(columns, width)).floor();

int driftRight(int columns, int width, double along) =>
    (along % driftLap(columns, width) - width).floor();

class Sprite {
  Sprite(List<String> rows, {this.paint = const []})
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
  final List<String> paint;

  void stamp(
    Field field,
    int left,
    int top,
    int argb, {
    bool flip = false,
    double gain = 1.0,
    Map<String, int> inks = const {},
  }) {
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final sx = flip ? width - 1 - x : x;
        final key = y < paint.length && sx < paint[y].length
            ? paint[y][sx]
            : ' ';
        field.put(
          left + x,
          top + y,
          _shade[y * width + sx] * gain,
          inks[key] ?? argb,
        );
      }
    }
  }
}

class Fireflies extends Wallpaper {
  const Fireflies();

  static const _count = 24;
  static const _glow = 0xFFE8FF6A;
  static const _halo = 0x00D9FF66;
  static const _grass = 0x8C4E8A4A;
  static const _grassTip = 0x5C4E8A4A;

  @override
  List<Color> get ground => const [Color(0xFF0C2016), Color(0xFF060F0A)];

  @override
  void render(double tick, Field field) {
    for (var i = 0; i < _count; i++) {
      final wander = tick * 0.008;
      final x =
          hash01(i, 1) * field.width +
          12 * (valueNoise(i * 5.3 + 0.5, wander) - 0.5);
      final y =
          hash01(i, 2) * field.height * 0.9 +
          8 * (valueNoise(i * 9.1 + 0.5, wander + 50) - 0.5);
      final rate = 0.04 + 0.05 * hash01(i, 3);
      final pulse = 0.5 + 0.5 * sin(tick * rate + hash01(i, 4) * 2 * pi);
      final glow = pulse * pulse * pulse;
      if (glow < 0.08) continue;
      final cx = x.round();
      final cy = y.round();
      field.put(cx, cy, 0.5 + 0.5 * glow, _glow);
      if (hash01(i, 5) > 0.6) field.put(cx + 1, cy, 0.4 + 0.5 * glow, _glow);
      field.glow(
        cx + 0.5,
        cy + 0.5,
        2.5 + 4 * glow,
        ((0x60 * glow).round() << 24) | _halo,
      );
    }
    for (var x = 0; x < field.width; x++) {
      final blades = 1 + (hash01(x, 77) * 4).floor();
      for (var k = 0; k < blades; k++) {
        field.put(x, field.height - 1 - k, 3 / (asciiLevels - 1), _grass);
      }
      field.put(x, field.height - 1 - blades, 1 / (asciiLevels - 1), _grassTip);
    }
  }
}

class Moonlit extends Wallpaper {
  const Moonlit();

  static const _moonInk = 0xFFE9E4C8;
  static const _cloudInk = 0xFF8E9AD0;
  static const _star = 0x00E8E6D8;

  static final _moon = Sprite([
    r'     $WXo.',
    r'   $$WXo.',
    r'  $$WXo.',
    r' $$WXo',
    r' $WXo',
    r' $WXo',
    r' $WXo',
    r' $$WXo',
    r'  $$WXo.',
    r'   $$WXo.',
    r'     $WXo.',
  ]);

  static final _cloud = Sprite([
    '      .oXWWWXo.',
    '   .oXWWWWWWWWXo.',
    '  oXWWWWWWWWWWWWXo',
    '  :ooXXXXXXXXXXoo:',
  ]);

  static final _puff = Sprite(['   .oXWXo.', ' .oXWWWWWXo.', '  :oXXXXXo:']);

  @override
  List<Color> get ground => const [Color(0xFF0C1434), Color(0xFF070B1E)];

  @override
  void render(double tick, Field field) {
    final skyline = (field.height * 0.65).floor();
    for (var y = 0; y < skyline; y++) {
      for (var x = 0; x < field.width; x++) {
        final seed = hash01(x, y);
        if (seed < 0.985) continue;
        final twinkle =
            0.5 + 0.35 * sin(tick * 0.2 + hash01(x, y + 1000) * 2 * pi);
        field.put(
          x,
          y,
          (seed > 0.995 ? 2 : 1) / (asciiLevels - 1),
          ((twinkle * 255).round() << 24) | _star,
        );
      }
    }
    _moon.stamp(field, field.width - _moon.width - 4, 7, _moonInk);

    _drift(field, tick, _cloud, 0.2, 0.05, 0.0);
    _drift(field, tick, _puff, 0.36, 0.08, 0.4);
    _drift(field, tick, _cloud, 0.55, 0.035, 0.75);
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
  static const _patch = 0xFFE86AA0;
  static const _ripple = 0x00DDEEEE;

  static final _koi = Sprite(
    [
      r'X.     .oXWWXo.',
      r'XXo. oXW$$$$WWXo',
      r' XXXXW$$$$$$$$WXo',
      r'XXo. oXW$$$$WWXo',
      r'X.     .oXWWXo.',
    ],
    paint: ['', '          pp  ', '         ppp   ', '          pp  '],
  );

  static final _pad = Sprite([
    '  .oXXo.',
    ' oXWWWWXo',
    ' XWWW WWX',
    ' oXWWWWXo',
    '  .oXXo.',
  ]);

  static const _fish = [
    (ink: 0xFFF08A3C, y: 0.12, speed: 0.11, phase: 0.1, flip: false),
    (ink: 0xFFF2EEE4, y: 0.3, speed: 0.08, phase: 0.6, flip: true),
    (ink: 0xFFD9513A, y: 0.5, speed: 0.13, phase: 0.35, flip: false),
    (ink: 0xFFE8B84A, y: 0.68, speed: 0.07, phase: 0.85, flip: true),
    (ink: 0xFFF08A3C, y: 0.86, speed: 0.1, phase: 0.5, flip: false),
  ];

  static const _pads = [
    (x: 0.08, y: 0.2),
    (x: 0.72, y: 0.58),
    (x: 0.28, y: 0.8),
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
          (fish.y * field.height + 2 * sin(tick * 0.05 + fish.phase * 2 * pi))
              .round();
      _koi.stamp(
        field,
        x,
        y,
        fish.ink,
        flip: fish.flip,
        inks: const {'p': _patch},
      );
      final tail = fish.flip ? x + _koi.width : x - 1;
      for (var k = 1; k <= 4; k++) {
        field.put(
          fish.flip ? tail + k * 2 : tail - k * 2,
          y + 2,
          1 / (asciiLevels - 1),
          ((0x70 - k * 0x14) << 24) | _ripple,
        );
      }
    }
  }
}
