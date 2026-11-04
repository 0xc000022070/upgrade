import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/design/ascii/braille.dart';
import 'package:upgrade/design/ascii/grid.dart';
import 'package:upgrade/design/ascii/mark.dart';

List<int> _litPerDotRow(int cols, int rows) {
  final grid = markGrid(cols, rows);
  return [
    for (var sy = 0; sy < rows * brailleRows; sy++)
      [
        for (var sx = 0; sx < cols * brailleCols; sx++)
          grid[(sy ~/ brailleRows) * cols + sx ~/ brailleCols] &
              (1 << brailleBit(sx % brailleCols, sy % brailleRows)),
      ].where((bit) => bit != 0).length,
  ];
}

void main() {
  test('the block is solid at the top and the trail thins below it', () {
    final lit = _litPerDotRow(18, 9);
    final block = lit.indexWhere((n) => n > 0);
    final bottom = lit.lastIndexWhere((n) => n > 0);
    expect(block, greaterThan(0));
    expect(lit[block], greaterThan(12));
    expect(lit.sublist(block, block + 4).toSet(), {lit[block]});
    expect(lit[bottom], lessThan(lit[block] ~/ 2));
    expect(lit[bottom], greaterThan(0));
  });

  test('the compact sprite on disk is the formula, not a hand edit', () {
    final sheet = AsciiSheet.parse(
      File(mascotAsset(mascotCompact)).readAsStringSync(),
    );
    expect(sheet.frames.single.hasSpark, isFalse);
    expect(sheet.frames.single.glyphs, markGrid(sheet.cols, sheet.rows));
  });
}
