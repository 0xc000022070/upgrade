import 'dart:typed_data';

import 'package:upgrade/design/ascii/noise.dart';

const brailleCols = 2;
const brailleRows = 4;

const brailleBase = 0x2800;

const brailleLevels = 256;

int brailleBit(int col, int row) =>
    row == brailleRows - 1 ? 6 + col : col * 3 + row;

const brailleSpark = 0x36;

String brailleChar(int bits) => String.fromCharCode(brailleBase + bits);

int brailleCell(Float64List shade, int width, int cx, int cy) {
  var bits = 0;
  for (var row = 0; row < brailleRows; row++) {
    final sy = cy * brailleRows + row;
    for (var col = 0; col < brailleCols; col++) {
      final sx = cx * brailleCols + col;
      if (shade[sy * width + sx] > bayer(sx, sy)) {
        bits |= 1 << brailleBit(col, row);
      }
    }
  }
  return bits;
}
