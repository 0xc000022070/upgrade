import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';

import 'package:material_ui/material_ui.dart' show ColorScheme;

import 'package:upgrade/design/ascii/noise.dart';
import 'package:upgrade/design/ascii/ramp.dart';
import 'package:upgrade/design/dynamic_tokens.dart';
import 'package:upgrade/design/tokens.dart';

abstract class Wallpaper {
  const Wallpaper();

  static const cell = 8.0;
  static const fontSize = 10.0;
  static const opacity = 0.85;
  static const bloom = 6.0;

  List<Color> get ground;

  bool get light => false;

  void render(double tick, Field field);

  static final _tokensOf = <Wallpaper, UpgradeTokens>{};

  UpgradeTokens get tokens => _tokensOf[this] ??= light
      ? _lightTokensOn(ground.last)
      : _tokensOn(ground.last);
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

UpgradeTokens _lightTokensOn(Color ground) =>
    upgradeTokensFromScheme(
      ColorScheme.fromSeed(seedColor: ground, brightness: Brightness.light),
    ).copyWith(
      backgroundPrimary: ground,
      backgroundSecondary: _lift(ground, 0.25),
      surfacePrimary: _lift(ground, 0.55),
      surfaceSecondary: _lift(ground, 0.7),
      borderSubtle: Color.lerp(ground, const Color(0xFF000000), 0.14)!,
      borderNormal: Color.lerp(ground, const Color(0xFF000000), 0.25)!,
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

int drift(Field field, Sprite sprite, double along, {bool flip = false}) => flip
    ? driftLeft(field.width, sprite.width, along)
    : driftRight(field.width, sprite.width, along);

void trail(Field field, int x, int y, int argb, {bool flip = false}) {
  for (var k = 1; k <= 4; k++) {
    field.put(
      flip ? x + k * 2 : x - k * 2,
      y,
      1 / (asciiLevels - 1),
      ((0x70 - k * 0x14) << 24) | argb,
    );
  }
}

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
      final x = drift(field, _koi, along, flip: fish.flip);
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
      trail(
        field,
        fish.flip ? x + _koi.width : x - 1,
        y + 2,
        _ripple,
        flip: fish.flip,
      );
    }
  }
}

class Sunburst extends Wallpaper {
  const Sunburst();

  static const _ink = 0xFFE08A5C;
  static const _ember = 0x00E08A5C;
  static const _rays = 12;
  static const _core = 4.3;

  @override
  List<Color> get ground => const [Color(0xFF1E1410), Color(0xFF0D0806)];

  @override
  void render(double tick, Field field) {
    for (var y = 0; y < field.height; y++) {
      for (var x = 0; x < field.width; x++) {
        final seed = hash01(x, y + 500);
        if (seed < 0.994) continue;
        final glow = 0.5 + 0.5 * sin(tick * 0.07 + seed * 400);
        field.put(
          x,
          y,
          (seed > 0.998 ? 2 : 1) / (asciiLevels - 1),
          ((0x30 + 0x50 * glow).round() << 24) | _ember,
        );
      }
    }
    final cx = field.width - 13;
    const cy = 8;
    for (var dy = -4; dy <= 4; dy++) {
      for (var dx = -4; dx <= 4; dx++) {
        final d = sqrt(dx * dx + dy * dy);
        if (d > _core) continue;
        final grain = 0.15 * (hash01(dx + 9, dy + 9) - 0.5);
        field.put(cx + dx, cy + dy, 1 - 0.35 * d / _core + grain, _ink);
      }
    }
    for (var i = 0; i < _rays; i++) {
      final angle = i * 2 * pi / _rays + tick * 0.003;
      final reach = 5 + 4 * (0.5 + 0.5 * sin(tick * 0.06 + i * 1.7));
      for (var d = 5; d <= 5 + reach; d++) {
        field.put(
          (cx + cos(angle) * d).round(),
          (cy + sin(angle) * d).round(),
          0.9 - 0.5 * (d - 5) / reach,
          _ink,
        );
      }
      for (var k = 1; k <= 2; k++) {
        final d = 5 + reach + 2 * k;
        field.put(
          (cx + cos(angle) * d).round(),
          (cy + sin(angle) * d).round(),
          1 / (asciiLevels - 1),
          ((0xA0 - k * 0x30) << 24) | _ember,
        );
      }
    }
  }
}

class CloudDrift extends Wallpaper {
  const CloudDrift();

  static const _ink = 0xFFF7F8F5;
  static const _bird = 0x00566B80;

  static final _big = Sprite([
    '        .oXWWWWXo.      ',
    '    .oXWWWWWWWWWWWXo.   ',
    '  .oXWWWWWWWWWWWWWWWXo. ',
    ' oXWWWWWWWWWWWWWWWWWWWXo',
    ' :oXXWWWWWWWWWWWWWWXXo: ',
    '   .:ooXXXXXXXXXXoo:.   ',
  ]);

  static final _mid = Sprite([
    '     .oXWWWXo.   ',
    '  .oXWWWWWWWWXo. ',
    ' oXWWWWWWWWWWWWXo',
    ' :ooXXXXXXXXXXoo:',
  ]);

  static final _small = Sprite(['   .oXWXo.', ' .oXWWWWWXo.', '  :oXXXXXo:']);

  static const _clouds = [
    (size: 0, y: 0.06, speed: 0.05, phase: 0.0),
    (size: 1, y: 0.18, speed: 0.08, phase: 0.45),
    (size: 2, y: 0.3, speed: 0.11, phase: 0.2),
    (size: 0, y: 0.5, speed: 0.04, phase: 0.7),
    (size: 1, y: 0.66, speed: 0.07, phase: 0.1),
    (size: 2, y: 0.84, speed: 0.1, phase: 0.55),
  ];

  @override
  bool get light => true;

  @override
  List<Color> get ground => const [Color(0xFFDDEFFB), Color(0xFF8CC4EE)];

  @override
  void render(double tick, Field field) {
    final sizes = [_big, _mid, _small];
    for (final cloud in _clouds) {
      final sprite = sizes[cloud.size];
      final lap = driftLap(field.width, sprite.width);
      final x = drift(field, sprite, tick * cloud.speed + cloud.phase * lap);
      sprite.stamp(field, x, (cloud.y * field.height).round(), _ink);
    }
    for (var i = 0; i < 3; i++) {
      final x = ((tick * 0.15 + i * 17) % (field.width + 4)).floor() - 2;
      final y = (field.height * (0.4 + 0.1 * i) + 2 * sin(tick * 0.1 + i))
          .round();
      final wing = sin(tick * 0.3 + i) > 0 ? 0 : -1;
      field.put(x, y, 2 / (asciiLevels - 1), (0x90 << 24) | _bird);
      field.put(x - 1, y + wing, 1 / (asciiLevels - 1), (0x70 << 24) | _bird);
      field.put(x + 1, y + wing, 1 / (asciiLevels - 1), (0x70 << 24) | _bird);
    }
  }
}

class HonuLagoon extends Wallpaper {
  const HonuLagoon();

  static const _turtleInk = 0xFF9BE070;
  static const _shell = 0xFFD2D45E;
  static const _bubble = 0x00D8F4EE;

  static const _turtleRows = [
    r'   XXo    .oXWXo.      ',
    r'    XXo .oXW$$$WXo.    ',
    r'     XXoXW$$$$$$$WX    ',
    r'      XW$$$$$$$$$WXoXXo',
    r'     XXoXW$$$$$$$WX    ',
    r'    XXo .oXW$$$WXo.    ',
    r'   XXo    .oXWXo.      ',
  ];

  static final _turtle = Sprite(
    _turtleRows,
    paint: [
      for (final row in _turtleRows)
        row.replaceAll(RegExp(r'[^$]'), ' ').replaceAll(r'$', 's'),
    ],
  );

  static final _fish = Sprite([r'X. .oXo.', r'XXoXW$WXo', r'X. .oXo.']);

  static const _turtles = [
    (y: 0.12, speed: 0.045, phase: 0.0, flip: false),
    (y: 0.5, speed: 0.035, phase: 0.5, flip: true),
    (y: 0.68, speed: 0.05, phase: 0.3, flip: false),
  ];

  static const _fishes = [
    (ink: 0xFFEE9AB4, y: 0.36, speed: 0.12, phase: 0.2, flip: false),
    (ink: 0xFFF3E7C9, y: 0.64, speed: 0.09, phase: 0.7, flip: true),
  ];

  @override
  List<Color> get ground => const [Color(0xFF4BAA9C), Color(0xFF1C6A68)];

  @override
  void render(double tick, Field field) {
    final turtleLap = driftLap(field.width, _turtle.width);
    for (final turtle in _turtles) {
      final along = tick * turtle.speed + turtle.phase * turtleLap;
      final x = drift(field, _turtle, along, flip: turtle.flip);
      final y =
          (turtle.y * field.height +
                  2 * sin(tick * 0.04 + turtle.phase * 2 * pi))
              .round();
      _turtle.stamp(
        field,
        x,
        y,
        _turtleInk,
        flip: turtle.flip,
        inks: const {'s': _shell},
      );
    }
    final fishLap = driftLap(field.width, _fish.width);
    for (final fish in _fishes) {
      final along = tick * fish.speed + fish.phase * fishLap;
      final x = drift(field, _fish, along, flip: fish.flip);
      final y = (fish.y * field.height + sin(tick * 0.08 + fish.phase * 2 * pi))
          .round();
      _fish.stamp(field, x, y, fish.ink, flip: fish.flip);
    }
    for (var i = 0; i < 14; i++) {
      final rise =
          tick * (0.15 + 0.1 * hash01(i, 12)) + hash01(i, 13) * field.height;
      field.put(
        (hash01(i, 11) * field.width).floor(),
        field.height - 1 - (rise % field.height).floor(),
        (hash01(i, 14) > 0.5 ? 2 : 1) / (asciiLevels - 1),
        (0x70 << 24) | _bubble,
      );
    }
  }
}

class Jellyfish extends Wallpaper {
  const Jellyfish();

  static const _mote = 0x00A8C8F0;
  static const _tentacles = [1, 4, 7, 10, 13];
  static const _hang = 12;

  static final _bell = Sprite([
    r'   .oXWWWXo.   ',
    r' .oXWW$$$WWXo. ',
    r' oXW$$$$$$$WXo ',
    r'oXW$$$$$$$$$WXo',
    r'X:X:X:X:X:X:X:X',
  ]);

  static const _jellies = [
    (ink: 0xFFF2A2C8, x: 0.18, speed: 0.06, phase: 0.0),
    (ink: 0xFFC4A8EC, x: 0.55, speed: 0.045, phase: 0.4),
    (ink: 0xFFF4B494, x: 0.8, speed: 0.07, phase: 0.75),
  ];

  @override
  List<Color> get ground => const [Color(0xFF143B6A), Color(0xFF071A35)];

  @override
  void render(double tick, Field field) {
    final span = field.height + _bell.height + _hang;
    for (final jelly in _jellies) {
      final turn = jelly.phase * 2 * pi;
      final top =
          (field.height - (tick * jelly.speed + jelly.phase * span) % span)
              .round();
      final x =
          (jelly.x * field.width -
                  _bell.width / 2 +
                  3 * sin(tick * 0.02 + turn))
              .round();
      _bell.stamp(
        field,
        x,
        top,
        jelly.ink,
        gain: 0.8 + 0.2 * sin(tick * 0.12 + turn),
      );
      for (final offset in _tentacles) {
        for (var k = 0; k < _hang; k++) {
          final sway = (1.5 * sin(tick * 0.09 + k * 0.35 + offset + turn))
              .round();
          final tx = x + offset + sway;
          final ty = top + _bell.height + k;
          if (k.isEven) {
            field.put(tx, ty, 0.55 - 0.02 * k, jelly.ink);
          } else {
            field.put(
              tx,
              ty,
              2 / (asciiLevels - 1),
              (0xB0 << 24) | (jelly.ink & 0x00FFFFFF),
            );
          }
        }
      }
    }
    for (var i = 0; i < 10; i++) {
      final rise =
          tick * (0.1 + 0.08 * hash01(i, 32)) + hash01(i, 33) * field.height;
      field.put(
        (hash01(i, 31) * field.width).floor(),
        field.height - 1 - (rise % field.height).floor(),
        1 / (asciiLevels - 1),
        (0x60 << 24) | _mote,
      );
    }
  }
}

class PaperBoats extends Wallpaper {
  const PaperBoats();

  static const _ink = 0xFFF5F3EC;
  static const _wake = 0x00E0F0EC;
  static const _speck = 0xFFF0A050;

  static final _boat = Sprite([
    r'       .X.       ',
    r'      .XWX.      ',
    r'     oXWWWXo     ',
    r'    oXWWWWWXo    ',
    r'   .oXXXXXXXo.   ',
    r' XW$$$$$$$$$$$WX ',
    r'  oXWWWWWWWWWXo  ',
  ]);

  static const _boats = [
    (y: 0.1, speed: 0.07, phase: 0.0, flip: false),
    (y: 0.28, speed: 0.05, phase: 0.55, flip: true),
    (y: 0.47, speed: 0.09, phase: 0.3, flip: false),
    (y: 0.66, speed: 0.06, phase: 0.8, flip: true),
    (y: 0.85, speed: 0.08, phase: 0.15, flip: false),
  ];

  @override
  List<Color> get ground => const [Color(0xFF3F9391), Color(0xFF1B5A60)];

  @override
  void render(double tick, Field field) {
    final lap = driftLap(field.width, _boat.width);
    for (final boat in _boats) {
      final along = tick * boat.speed + boat.phase * lap;
      final x = drift(field, _boat, along, flip: boat.flip);
      final y =
          (boat.y * field.height + 1.5 * sin(tick * 0.06 + boat.phase * 2 * pi))
              .round();
      _boat.stamp(field, x, y, _ink, flip: boat.flip);
      trail(
        field,
        boat.flip ? x + _boat.width : x - 1,
        y + 5,
        _wake,
        flip: boat.flip,
      );
    }
    for (var i = 0; i < 6; i++) {
      final x = (hash01(i, 21) * field.width + 6 * sin(tick * 0.01 + i))
          .round();
      final y = (hash01(i, 22) * field.height + 3 * sin(tick * 0.03 + i * 2))
          .round();
      field.put(x, y, 0.5, _speck);
      field.put(x + 1, y, 0.4, _speck);
    }
  }
}
