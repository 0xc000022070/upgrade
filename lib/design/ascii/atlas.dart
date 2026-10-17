import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:striked/design/ascii/braille.dart';
import 'package:striked/design/ascii/ramp.dart';

const _ruler = '0123456789';

final _advances = <String, double>{};

double monoAdvance(String fontFamily, double fontSize) {
  return _advances['$fontFamily/$fontSize'] ??= () {
    final builder =
        ui.ParagraphBuilder(
            ui.ParagraphStyle(fontFamily: fontFamily, fontSize: fontSize),
          )
          ..pushStyle(ui.TextStyle(fontFamily: fontFamily, fontSize: fontSize))
          ..addText(_ruler);
    final paragraph = builder.build()
      ..layout(const ui.ParagraphConstraints(width: double.infinity));
    final advance = paragraph.maxIntrinsicWidth / _ruler.length;
    paragraph.dispose();
    return advance;
  }();
}

class GlyphAtlas {
  GlyphAtlas._(
    this._rects, {
    required this.image,
    required this.cellWidth,
    required this.cellHeight,
    required this.pixelRatio,
  });

  final ui.Image image;

  final double cellWidth;
  final double cellHeight;
  final double pixelRatio;

  final Float32List _rects;

  double get scale => 1.0 / pixelRatio;

  static const tint = ui.BlendMode.dstIn;

  static int slotOfGlyph(int glyph) => glyph - 1;

  static int slotOfExtra(int index) => asciiLevels - 1 + index;

  void rectInto(Float32List out, int at, int slot) {
    final src = slot * 4;
    if (src < 0 || src >= _rects.length) {
      out[at] = 0;
      out[at + 1] = 0;
      out[at + 2] = 0;
      out[at + 3] = 0;
      return;
    }
    out[at] = _rects[src];
    out[at + 1] = _rects[src + 1];
    out[at + 2] = _rects[src + 2];
    out[at + 3] = _rects[src + 3];
  }

  void dispose() => image.dispose();

  static final _cache = <String, Future<GlyphAtlas>>{};

  static Future<GlyphAtlas> of({
    required double cellWidth,
    required double cellHeight,
    required double fontSize,
    required String fontFamily,
    required double pixelRatio,
    String extra = '',
  }) {
    final key =
        '$fontFamily/$fontSize/$cellWidth/$cellHeight/'
        '${pixelRatio.toStringAsFixed(2)}/$extra';
    return _cache[key] ??= _build(
      cellWidth: cellWidth,
      cellHeight: cellHeight,
      fontSize: fontSize,
      fontFamily: fontFamily,
      pixelRatio: pixelRatio,
      extra: extra,
    );
  }

  static Future<GlyphAtlas> _build({
    required double cellWidth,
    required double cellHeight,
    required double fontSize,
    required String fontFamily,
    required double pixelRatio,
    required String extra,
  }) async {
    final cw = (cellWidth * pixelRatio).ceilToDouble();
    final ch = (cellHeight * pixelRatio).ceilToDouble();
    final sheet = asciiRamp.substring(1) + extra;
    final count = sheet.length;

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder, ui.Rect.fromLTWH(0, 0, cw * count, ch));
    final rects = Float32List(count * 4);

    for (var i = 0; i < count; i++) {
      final builder =
          ui.ParagraphBuilder(
              ui.ParagraphStyle(
                fontFamily: fontFamily,
                fontSize: fontSize * pixelRatio,
                textAlign: ui.TextAlign.center,
                maxLines: 1,
              ),
            )
            ..pushStyle(ui.TextStyle(color: const ui.Color(0xFFFFFFFF)))
            ..addText(sheet[i]);
      final paragraph = builder.build()
        ..layout(ui.ParagraphConstraints(width: cw));

      final x = i * cw;
      canvas.save();
      canvas.clipRect(ui.Rect.fromLTWH(x, 0, cw, ch));
      canvas.drawParagraph(
        paragraph,
        ui.Offset(x, (ch - paragraph.height) * 0.5),
      );
      canvas.restore();
      paragraph.dispose();

      rects[i * 4] = x;
      rects[i * 4 + 1] = 0;
      rects[i * 4 + 2] = x + cw;
      rects[i * 4 + 3] = ch;
    }

    final picture = recorder.endRecording();
    final image = await picture.toImage((cw * count).ceil(), ch.ceil());
    picture.dispose();

    return GlyphAtlas._(
      rects,
      image: image,
      cellWidth: cellWidth,
      cellHeight: cellHeight,
      pixelRatio: pixelRatio,
    );
  }

  static const _dotFill = 0.82;

  static const _brailleStride = 16;

  static Future<GlyphAtlas> braille({
    required double cellWidth,
    required double cellHeight,
    required double pixelRatio,
  }) {
    final key =
        'braille/$cellWidth/$cellHeight/${pixelRatio.toStringAsFixed(2)}';
    return _cache[key] ??= _buildBraille(
      cellWidth: cellWidth,
      cellHeight: cellHeight,
      pixelRatio: pixelRatio,
    );
  }

  static Future<GlyphAtlas> _buildBraille({
    required double cellWidth,
    required double cellHeight,
    required double pixelRatio,
  }) async {
    final cw = (cellWidth * pixelRatio).ceilToDouble();
    final ch = (cellHeight * pixelRatio).ceilToDouble();
    final count = brailleLevels - 1;
    final down = (count / _brailleStride).ceil();

    final pitchX = cw / brailleCols;
    final pitchY = ch / brailleRows;
    final radius = min(pitchX, pitchY) * 0.5 * _dotFill;

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(
      recorder,
      ui.Rect.fromLTWH(0, 0, cw * _brailleStride, ch * down),
    );
    final paint = ui.Paint()
      ..color = const ui.Color(0xFFFFFFFF)
      ..isAntiAlias = true;
    final rects = Float32List(count * 4);

    for (var i = 0; i < count; i++) {
      final bits = i + 1;
      final x = (i % _brailleStride) * cw;
      final y = (i ~/ _brailleStride) * ch;

      for (var row = 0; row < brailleRows; row++) {
        for (var col = 0; col < brailleCols; col++) {
          if (bits & (1 << brailleBit(col, row)) == 0) continue;
          canvas.drawCircle(
            ui.Offset(x + (col + 0.5) * pitchX, y + (row + 0.5) * pitchY),
            radius,
            paint,
          );
        }
      }

      rects[i * 4] = x;
      rects[i * 4 + 1] = y;
      rects[i * 4 + 2] = x + cw;
      rects[i * 4 + 3] = y + ch;
    }

    final picture = recorder.endRecording();
    final image = await picture.toImage(
      (cw * _brailleStride).ceil(),
      (ch * down).ceil(),
    );
    picture.dispose();

    return GlyphAtlas._(
      rects,
      image: image,
      cellWidth: cellWidth,
      cellHeight: cellHeight,
      pixelRatio: pixelRatio,
    );
  }
}
