// ignore_for_file: implementation_imports
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flterm/src/foundation/cell_metrics.dart';
import 'package:flterm/src/foundation/terminal_theme.dart';
import 'package:flterm/src/rendering/atlas/atlas.dart';
import 'package:flterm/src/rendering/atlas/sprite_buffer.dart';
import 'package:flterm/src/rendering/frame_builder.dart';
import 'package:flterm/src/rendering/paint_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libghostty/libghostty.dart';

const _metrics = CellMetrics(cellWidth: 8, cellHeight: 16, baseline: 12);

int _rowColour(int row) => 0xFF000001 | (row & 0xFF) << 16 | (row >> 8) << 8;

void main() {
  test('every row paints the colour its own cells carry', () {
    const cols = 215;
    const rows = 600;
    final terminal = Terminal(cols: cols, rows: rows);
    final atlas = Atlas(
      AtlasConfig(
        fontSize: 14,
        fontWeight: FontWeight.normal,
        fontFamily: 'monospace',
        fontFamilyFallback: const [],
        metrics: _metrics,
        devicePixelRatio: 1.0,
      ),
    );
    final sprites = SpriteBuffer();
    final state = PaintState(TerminalTheme.dark(), _metrics)
      ..cols = cols
      ..rows = rows;
    final builder = FrameBuilder(atlas, sprites, state)..configure(rows, cols);
    addTearDown(() {
      builder.dispose();
      sprites.dispose();
      atlas.dispose();
      terminal.dispose();
    });

    final screen = StringBuffer();
    for (var row = 0; row < rows; row++) {
      final argb = _rowColour(row);
      final r = argb >> 16 & 0xFF, g = argb >> 8 & 0xFF, b = argb & 0xFF;
      screen.write('\x1b[${row + 1};1H\x1b[38;2;$r;$g;${b}mrow\x1b[0m');
    }
    terminal.write(Uint8List.fromList(utf8.encode(screen.toString())));

    builder.sync(terminal, terminalDirty: true);

    const glyphs = 3;
    final colours = sprites.regular.sealedColors;
    expect(colours, hasLength(rows * glyphs));
    final wrong = [
      for (var row = 0; row < rows; row++)
        if (colours[row * glyphs].toUnsigned(32) != _rowColour(row)) row,
    ];
    expect(wrong, isEmpty);
  });

  test('a shaped operator run is laid out once and outlives a sibling row', () {
    const cols = 20;
    const rows = 3;
    final terminal = Terminal(cols: cols, rows: rows);
    final atlas = Atlas(
      AtlasConfig(
        fontSize: 14,
        fontWeight: FontWeight.normal,
        fontFamily: 'monospace',
        fontFamilyFallback: const [],
        metrics: _metrics,
        devicePixelRatio: 1.0,
      ),
    );
    final sprites = SpriteBuffer();
    final state = PaintState(TerminalTheme.dark(), _metrics)
      ..cols = cols
      ..rows = rows;
    final builder = FrameBuilder(atlas, sprites, state)..configure(rows, cols);
    addTearDown(() {
      builder.dispose();
      sprites.dispose();
      atlas.dispose();
      terminal.dispose();
    });
    void show(String screen) {
      terminal.write(Uint8List.fromList(utf8.encode(screen)));
      builder.sync(terminal, terminalDirty: true);
    }

    show('\x1b[1;1Ha => b\x1b[2;1Hc => d');
    final runs = sprites.shaped.rows;
    final shared = runs[1].single.paragraph;
    expect(runs[0].single.paragraph, same(shared));

    show('\x1b[1;1Ha != b');
    expect(runs[1].single.paragraph, same(shared));
    expect(shared.debugDisposed, isFalse);
    expect(runs[0].single.paragraph, isNot(same(shared)));
  });
}
