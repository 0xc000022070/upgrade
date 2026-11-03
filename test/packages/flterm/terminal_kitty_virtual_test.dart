// ignore_for_file: implementation_imports
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flterm/src/foundation/cell_metrics.dart';
import 'package:flterm/src/foundation/terminal_theme.dart';
import 'package:flterm/src/rendering/atlas/atlas.dart';
import 'package:flterm/src/rendering/atlas/sprite_buffer.dart';
import 'package:flterm/src/rendering/frame_builder.dart';
import 'package:flterm/src/rendering/kitty_image_cache.dart';
import 'package:flterm/src/rendering/kitty_placement_cache.dart';
import 'package:flterm/src/rendering/kitty_virtual_placements.dart';
import 'package:flterm/src/rendering/paint_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libghostty/libghostty.dart';

const _cols = 8;
const _rows = 3;
const _cellWidth = 36;
const _cellHeight = 80;
const _metrics = CellMetrics(
  cellWidth: _cellWidth * 1.0,
  cellHeight: _cellHeight * 1.0,
  baseline: 60,
);

const _placeholder = '\u{10EEEE}';
const _diacritics = ['\u0305', '\u030D', '\u030E'];

Terminal _terminal() {
  final terminal = Terminal(cols: _cols, rows: _rows)
    ..kittyImageStorageLimit = 16 << 20;
  terminal.resize(
    cols: _cols,
    rows: _rows,
    cellWidthPx: _cellWidth,
    cellHeightPx: _cellHeight,
  );
  return terminal;
}

void _write(Terminal terminal, String text) =>
    terminal.write(Uint8List.fromList(utf8.encode(text)));

void _transmit(
  Terminal terminal, {
  required int id,
  required int columns,
  required int rows,
  int width = 500,
  int height = 306,
  int? placementId,
}) {
  final payload = base64Encode(Uint8List(width * height * 3));
  final pid = placementId == null ? '' : ',p=$placementId';
  const chunk = 4096;
  for (var start = 0; start < payload.length; start += chunk) {
    final end = start + chunk < payload.length ? start + chunk : payload.length;
    final more = end < payload.length ? 1 : 0;
    final control = start == 0
        ? 'a=T,U=1,f=24,s=$width,v=$height,i=$id$pid,c=$columns,r=$rows,'
              'q=2,m=$more'
        : 'm=$more';
    _write(terminal, '\x1b_G$control;${payload.substring(start, end)}\x1b\\');
  }
}

String _cell([List<int> marks = const []]) =>
    _placeholder + marks.map((mark) => _diacritics[mark]).join();

String _rgb(int id) =>
    '\x1b[38;2;${id >> 16 & 0xFF};${id >> 8 & 0xFF};${id & 0xFF}m';

({List<KittyPlacementSnapshot> snapshots, List<KittyVirtualRun> runs}) _render(
  Terminal terminal,
) {
  final state = PaintState(TerminalTheme.dark(), _metrics)
    ..cols = _cols
    ..rows = _rows;
  final cache = KittyPlacementCache(
    state: state,
    images: KittyImageCache(
      onImageReady: () {},
      decodeImage: (_, _, _, _, _) {},
    ),
  );
  final renderState = RenderState()..update(terminal);
  final scanner = KittyVirtualScanner();
  addTearDown(() {
    scanner.dispose();
    cache.dispose();
    renderState.dispose();
  });
  cache.sync(
    KittyGraphics.of(terminal),
    geometryDirty: true,
    cells: renderState,
  );
  final runs = <KittyVirtualRun>[];
  scanner.scan(renderState, _rows, runs);
  return (snapshots: cache.snapshots.toList(), runs: runs);
}

void main() {
  test('each grid row draws its slice of the image', () {
    final terminal = _terminal();
    _transmit(terminal, id: 42, columns: 4, rows: 2);
    _write(
      terminal,
      '\x1b[1;3H${_rgb(42)}${_cell([0, 0])}${_placeholder * 3}'
      '\x1b[2;3H${_cell([1])}${_placeholder * 3}\x1b[m',
    );

    final (:snapshots, :runs) = _render(terminal);

    expect(runs, const [
      KittyVirtualRun(
        viewportRow: 0,
        viewportCol: 2,
        width: 4,
        imageId: 42,
        placementId: 0,
        imageRow: 0,
        imageCol: 0,
      ),
      KittyVirtualRun(
        viewportRow: 1,
        viewportCol: 2,
        width: 4,
        imageId: 42,
        placementId: 0,
        imageRow: 1,
        imageCol: 0,
      ),
    ]);
    expect(snapshots.map((s) => (s.imageId, s.z, s.dst, s.src)), [
      (
        42,
        -1,
        const Rect.fromLTWH(72, 36, 144, 44),
        const Rect.fromLTWH(0, 0, 500, 153),
      ),
      (
        42,
        -1,
        const Rect.fromLTWH(72, 80, 144, 44),
        const Rect.fromLTWH(0, 153, 500, 153),
      ),
    ]);
  });

  test('a missing column diacritic continues the run to the left', () {
    final terminal = _terminal();
    _transmit(terminal, id: 42, columns: 4, rows: 1);
    _write(
      terminal,
      '\x1b[1;1H${_rgb(42)}${_cell([0, 0])}$_placeholder'
      '${_cell([0, 2])}${_cell([0, 0])}$_placeholder\x1b[m',
    );

    final (:snapshots, :runs) = _render(terminal);

    expect(runs.map((run) => (run.viewportCol, run.width, run.imageCol)), [
      (0, 3, 0),
      (3, 2, 0),
    ]);
    expect(snapshots, hasLength(2));
  });

  test('a 256-colour foreground names the image, the underline the '
      'placement', () {
    final terminal = _terminal();
    const id = 2 << 24 | 42;
    _transmit(terminal, id: id, columns: 1, rows: 1, placementId: 21);
    _write(terminal, '\x1b[1;1H\x1b[38;5;42;58;5;21m${_cell([0, 0, 2])}\x1b[m');

    final (:snapshots, :runs) = _render(terminal);

    expect(runs.single.imageId, id);
    expect(runs.single.placementId, 21);
    expect(snapshots.single.imageId, id);
  });

  test('a placeholder for an unknown image draws nothing', () {
    final terminal = _terminal();
    _transmit(terminal, id: 42, columns: 1, rows: 1);
    _write(terminal, '\x1b[1;1H${_rgb(99)}${_cell([0, 0])}\x1b[m');

    final (:snapshots, :runs) = _render(terminal);

    expect(runs.single.imageId, 99);
    expect(snapshots, isEmpty);
  });

  test('the image is fitted and centred inside its grid', () {
    final terminal = _terminal();
    _transmit(terminal, id: 1, columns: 1, rows: 1);
    _transmit(terminal, id: 2, columns: 2, rows: 2);
    _transmit(terminal, id: 3, columns: 4, rows: 1);
    _write(
      terminal,
      '\x1b[1;1H${_rgb(1)}${_cell([0, 0])}'
      '\x1b[1;2H${_rgb(2)}${_cell([0, 0])}$_placeholder'
      '\x1b[2;1H${_rgb(3)}${_cell([0, 0])}${_placeholder * 3}\x1b[m',
    );

    final (:snapshots, runs: _) = _render(terminal);
    final byId = {for (final s in snapshots) s.imageId: s};

    expect(byId[1]!.dst, const Rect.fromLTWH(0, 29, 36, 22));
    expect(byId[1]!.src, const Rect.fromLTWH(0, 0, 500, 306));
    expect(byId[2]!.dst, const Rect.fromLTWH(36, 58, 72, 22));
    expect(byId[3]!.dst, const Rect.fromLTWH(7, 80, 131, 80));
    expect(byId[3]!.src, const Rect.fromLTWH(0, 0, 500, 306));
  });

  test('placeholder cells paint their background but no glyph', () {
    final terminal = _terminal();
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
      ..cols = _cols
      ..rows = _rows;
    final builder = FrameBuilder(atlas, sprites, state)
      ..configure(_rows, _cols);
    addTearDown(() {
      builder.dispose();
      sprites.dispose();
      atlas.dispose();
    });
    _transmit(terminal, id: 42, columns: 2, rows: 1);
    _write(
      terminal,
      '\x1b[1;1HAB\x1b[48;2;10;20;30m${_rgb(42)}'
      '${_cell([0, 0])}$_placeholder\x1b[m',
    );

    builder.sync(terminal, terminalDirty: true);

    final glyphs =
        sprites.regular.count +
        sprites.wide.count +
        sprites.sprite.count +
        sprites.emoji.count +
        sprites.shaped.count;
    expect(glyphs, 2);
    expect(
      sprites.regular.sealedColors.map((argb) => argb.toUnsigned(24)),
      isNot(contains(42)),
    );
    expect(sprites.background.count, 1);

    _write(terminal, '\x1b[1;3H');
    builder.sync(terminal, terminalDirty: true);
    expect(state.cursorGlyph, isNull);

    _write(terminal, '\x1b[1;1H');
    builder.sync(terminal, terminalDirty: true);
    expect(state.cursorGlyph, isNotNull);
  });
}
