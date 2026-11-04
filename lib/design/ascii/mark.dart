import 'dart:math';
import 'dart:typed_data';

import 'package:upgrade/design/ascii/braille.dart';

/// A block cursor lifting off, its trail thinning from mesh to loose dots.
/// Units are half the grid's width, y down, origin at the centre.
double markDistance(double x, double y) {
  final block = max(x.abs() - 0.46, (y + 0.67).abs() - 0.26);
  final trail = max(
    x.abs() - 0.46 + (y + 0.41) * 0.22,
    (y - 0.33).abs() - 0.60,
  );
  return min(block, trail);
}

double markShade(double y) => y < -0.33
    ? 1.0
    : y < 0.15
    ? 0.55
    : 0.25;

/// The figure is sampled once per dot; the thinner bands are left to the dither.
Uint8List markGrid(int cols, int rows) {
  final width = cols * brailleCols;
  final height = rows * brailleRows;
  final unit = width / 2;
  final shade = Float64List(width * height);
  for (var sy = 0; sy < height; sy++) {
    for (var sx = 0; sx < width; sx++) {
      final x = (sx + 0.5 - width / 2) / unit;
      final y = (sy + 0.5 - height / 2) / unit;
      if (markDistance(x, y) <= 0) shade[sy * width + sx] = markShade(y);
    }
  }
  final out = Uint8List(cols * rows);
  for (var cy = 0; cy < rows; cy++) {
    for (var cx = 0; cx < cols; cx++) {
      out[cy * cols + cx] = brailleCell(shade, width, cx, cy);
    }
  }
  return out;
}
