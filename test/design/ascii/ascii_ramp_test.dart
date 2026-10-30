import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/design/ascii/ramp.dart';

Future<double> _coverage(String ch, double size) async {
  final builder = ui.ParagraphBuilder(
    ui.ParagraphStyle(fontFamily: 'IBM Plex Mono', fontSize: size),
  )..addText(ch);
  final paragraph = builder.build()
    ..layout(const ui.ParagraphConstraints(width: 512));
  final w = size * 2;
  final h = paragraph.height;
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder, ui.Rect.fromLTWH(0, 0, w, h))
    ..drawColor(const ui.Color(0xFF000000), ui.BlendMode.src)
    ..drawParagraph(paragraph, ui.Offset.zero);
  final image = await recorder.endRecording().toImage(w.ceil(), h.ceil());
  final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  var sum = 0;
  for (var i = 0; i < bytes!.lengthInBytes; i += 4) {
    sum += bytes.getUint8(i);
  }
  return sum / (255.0 * bytes.lengthInBytes / 4);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final font = await rootBundle.load(
      'assets/fonts/ibm_plex_mono/IBMPlexMono-Regular.ttf',
    );
    final loader = FontLoader('IBM Plex Mono')..addFont(Future.value(font));
    await loader.load();
  });

  test('the ramp climbs, measured and not guessed', () async {
    var previous = -1.0;
    for (final ch in asciiRamp.split('')) {
      final ink = await _coverage(ch, 48);
      expect(
        ink,
        greaterThan(previous),
        reason: '"$ch" inks no more than the character before it',
      );
      previous = ink;
    }
  });

  test('it opens on nothing and ends on the densest thing it has', () {
    expect(asciiRamp[0], ' ');
    expect(asciiRamp.length, asciiLevels);
  });

  group('the quantiser', () {
    test('clamps at both ends', () {
      expect(asciiGlyph(-1, 0.5), 0);
      expect(asciiGlyph(0, 0.5), 0);
      expect(asciiGlyph(2, 0.5), asciiLevels - 1);
      expect(asciiGlyph(1, 0.5), asciiLevels - 1);
    });

    test('the dither moves a level and not more', () {
      const shade = 0.5;
      final low = asciiGlyph(shade, 0.0);
      final high = asciiGlyph(shade, 1.0);
      expect(high - low, lessThanOrEqualTo(1));
      expect(high, greaterThanOrEqualTo(low));
    });

    test('a shade that is nearly nothing still reaches the first mark', () {
      expect(asciiGlyph(0.01, 0.99), greaterThan(0));
    });
  });
}
