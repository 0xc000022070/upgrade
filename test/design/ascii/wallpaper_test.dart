import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/design/ascii/ramp.dart';
import 'package:upgrade/design/ascii/wallpaper.dart';
import 'package:upgrade/design/theme.dart';
import 'package:upgrade/design/tokens.dart';

Field _field(int width, int height) => Field(
  width,
  height,
  Float64List(width * height),
  Int32List(width * height),
);

int _lit(Field field) => field.shade.where((s) => s > 0).length;

void main() {
  group('sprite', () {
    final sprite = Sprite([r'$.', ' o']);

    test('stamps the ramp level of each glyph and leaves spaces alone', () {
      final field = _field(4, 4);
      sprite.stamp(field, 1, 1, 0x7F112233);
      expect(field.shade[1 * 4 + 1], 1.0);
      expect(field.shade[1 * 4 + 2], 1 / (asciiLevels - 1));
      expect(field.shade[2 * 4 + 1], 0.0);
      expect(
        field.shade[2 * 4 + 2],
        asciiRamp.indexOf('o') / (asciiLevels - 1),
      );
      expect(field.colours[1 * 4 + 1], 0x7F112233);
      expect(_lit(field), 3);
    });

    test('flips across its own width', () {
      final field = _field(4, 4);
      sprite.stamp(field, 0, 0, 0xFF000001, flip: true);
      expect(field.shade[0], 1 / (asciiLevels - 1));
      expect(field.shade[1], 1.0);
      expect(field.shade[4], asciiRamp.indexOf('o') / (asciiLevels - 1));
    });

    test('clips at every edge', () {
      final field = _field(3, 3);
      sprite.stamp(field, -1, -1, 1);
      sprite.stamp(field, 2, 2, 1);
      expect(field.shade[0], asciiRamp.indexOf('o') / (asciiLevels - 1));
      expect(field.shade[8], 1.0);
      expect(_lit(field), 2);
    });
  });

  group('wallpapers', () {
    for (final choice in ThemeChoice.values) {
      final wallpaper = choice.wallpaper;
      if (wallpaper == null) continue;

      test(
        '${choice.name} draws something at any tick and colours every cell it lights',
        () {
          for (final tick in [0.0, 1.0, 97.0, 4000.5]) {
            final field = _field(63, 68);
            wallpaper.render(tick, field);
            expect(_lit(field), greaterThan(0), reason: 'tick $tick');
            for (var i = 0; i < field.shade.length; i++) {
              if (field.shade[i] > 0) expect(field.colours[i], isNot(0));
            }
          }
        },
      );

      test('${choice.name} tints the house palette and keeps its ink', () {
        final tokens = wallpaper.tokens;
        expect(tokens.backgroundPrimary, wallpaper.ground.last);
        expect(tokens.textPrimary, UpgradeTokens.house.textPrimary);
        expect(tokens.accent, UpgradeTokens.house.accent);
        expect(tokens.terminal, UpgradeTokens.house.terminal);
        expect(identical(wallpaper.tokens, tokens), isTrue);
      });
    }

    test('a wallpaper renders inside a one-cell field without throwing', () {
      for (final choice in ThemeChoice.values) {
        choice.wallpaper?.render(12, _field(1, 1));
      }
    });
  });

  group('drift', () {
    const columns = 20;
    const width = 5;
    final lap = driftLap(columns, width);

    test('a lap runs a sprite fully off one edge to fully off the other', () {
      for (final drift in [driftLeft, driftRight]) {
        final seen = <int>{};
        for (var along = 0.0; along < lap * 2; along += 0.5) {
          final x = drift(columns, width, along);
          expect(x, inInclusiveRange(-width - 1, columns));
          seen.add(x);
        }
        expect(seen, containsAll([-width, 0, columns - 1, columns]));
      }
    });

    test('left and right are each other mirrored', () {
      for (var along = 0.0; along < lap; along += 1) {
        expect(
          driftLeft(columns, width, along),
          columns - width - driftRight(columns, width, along),
        );
      }
    });
  });

  test('an unknown theme name reads as the house', () {
    expect(ThemeChoice.decode('moonlit'), ThemeChoice.moonlit);
    expect(ThemeChoice.decode('lava'), ThemeChoice.house);
    expect(ThemeChoice.decode(''), ThemeChoice.house);
  });
}
