import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:upgrade/design/ascii/atlas.dart';
import 'package:upgrade/design/ascii/braille.dart';
import 'package:upgrade/design/ascii/ramp.dart';
import 'package:upgrade/design/typography.dart';

void main() {
  const shade = 0xFFE8E8E3;
  const accent = 0xFFB7FF2A;

  late GlyphAtlas atlas;
  late GlyphAtlas dots;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final advance = monoAdvance(FontFamilies.mono, 11);
    atlas = await GlyphAtlas.of(
      cellWidth: advance,
      cellHeight: advance * 2,
      fontSize: 11,
      fontFamily: FontFamilies.mono,
      pixelRatio: 3,
      extra: '*',
    );
    dots = await GlyphAtlas.braille(
      cellWidth: 7,
      cellHeight: 14,
      pixelRatio: 3,
    );
  });

  Future<Map<int, int>> draw(GlyphAtlas atlas, List<(int, int)> slots) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);

    final transforms = Float32List(slots.length * 4);
    final rects = Float32List(slots.length * 4);
    final colours = Int32List(slots.length);
    for (var i = 0; i < slots.length; i++) {
      final (slot, colour) = slots[i];
      transforms[i * 4] = atlas.scale;
      transforms[i * 4 + 1] = 0;
      transforms[i * 4 + 2] = i * atlas.cellWidth;
      transforms[i * 4 + 3] = 0;
      atlas.rectInto(rects, i * 4, slot);
      colours[i] = colour;
    }

    final size = ui.Size(atlas.cellWidth * slots.length, atlas.cellHeight);
    canvas.drawRawAtlas(
      atlas.image,
      transforms,
      rects,
      colours,
      GlyphAtlas.tint,
      ui.Offset.zero & size,
      Paint()..filterQuality = ui.FilterQuality.none,
    );

    final picture = recorder.endRecording();
    final image = await picture.toImage(
      (size.width * 3).ceil(),
      (size.height * 3).ceil(),
    );
    picture.dispose();
    final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    image.dispose();

    final tally = <int, int>{};
    for (var i = 0; i < data.lengthInBytes; i += 4) {
      if (data.getUint8(i + 3) < 250) continue;
      final rgb =
          0xFF000000 |
          (data.getUint8(i) << 16) |
          (data.getUint8(i + 1) << 8) |
          data.getUint8(i + 2);
      tally[rgb] = (tally[rgb] ?? 0) + 1;
    }
    return tally;
  }

  group('the glyph atlas', () {
    test('rasterises the ramp as a mask and not as ink', () async {
      final data = (await atlas.image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      for (var i = 0; i < data.lengthInBytes; i += 4) {
        final alpha = data.getUint8(i + 3);
        if (alpha < 250) continue;
        expect(
          [data.getUint8(i), data.getUint8(i + 1), data.getUint8(i + 2)],
          [alpha, alpha, alpha],
          reason: 'a glyph carries a colour of its own',
        );
      }
    });

    test('carries a colour per sprite onto the glyphs', () async {
      final tally = await draw(atlas, [
        (GlyphAtlas.slotOfGlyph(asciiLevels - 1), shade),
        (GlyphAtlas.slotOfExtra(0), accent),
      ]);

      expect(tally[accent], isNotNull, reason: 'the accent did not land');
      expect(tally[shade], isNotNull, reason: 'the shade did not land');
      expect(
        tally[0xFFFFFFFF],
        isNull,
        reason: 'a glyph kept the atlas colour instead of taking the tint',
      );
    });

    test('takes the alpha of the colour it is given', () async {
      final tally = await draw(atlas, [
        (GlyphAtlas.slotOfGlyph(asciiLevels - 1), 0x10E8E8E3),
      ]);

      expect(tally, isEmpty, reason: 'a faint field came out opaque');
    });
  });

  group('the braille atlas', () {
    test('draws every pattern out of arithmetic and no font', () async {
      final one = await draw(dots, [(GlyphAtlas.slotOfGlyph(1), shade)]);
      final all = await draw(dots, [
        (GlyphAtlas.slotOfGlyph(brailleLevels - 1), shade),
      ]);

      expect(one[shade], isNotNull, reason: 'a single dot drew nothing');
      expect(
        all[shade],
        greaterThan(one[shade]! * 6),
        reason: 'eight dots are not eight times one dot',
      );
    });

    test('leaves the ground between the dots', () async {
      final all = await draw(dots, [
        (GlyphAtlas.slotOfGlyph(brailleLevels - 1), shade),
      ]);
      final cell = (dots.cellWidth * 3).ceil() * (dots.cellHeight * 3).ceil();

      expect(all[shade], lessThan(cell * 3 ~/ 4));
    });

    test('carries the accent cell in its own colour', () async {
      final tally = await draw(dots, [
        (GlyphAtlas.slotOfGlyph(brailleLevels - 1), shade),
        (GlyphAtlas.slotOfGlyph(brailleSpark), accent),
      ]);

      expect(tally[accent], isNotNull, reason: 'the accent did not land');
      expect(tally[shade], isNotNull, reason: 'the shade did not land');
      expect(
        tally[0xFFFFFFFF],
        isNull,
        reason: 'a dot kept the atlas colour instead of taking the tint',
      );
    });
  });
}
