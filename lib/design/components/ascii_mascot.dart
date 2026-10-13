import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'package:upgrade/design/ascii/atlas.dart';
import 'package:upgrade/design/ascii/grid.dart';

class AsciiMascot extends StatefulWidget {
  const AsciiMascot({
    super.key,
    this.state = 'idle',
    this.cellWidth = sheetCell,
    required this.colour,
    required this.accent,
    this.animated = true,
  });

  const AsciiMascot.compact({
    super.key,
    required this.colour,
    required this.accent,
  }) : state = mascotCompact,
       cellWidth = compactCell,
       animated = false;

  final String state;

  final double cellWidth;
  final Color colour;
  final Color accent;

  final bool animated;

  static const sheetCell = 7.0;
  static const compactCell = 4.0;

  static Future<void> preload() => Future.wait([
    for (final state in mascotStates) sheet(state),
    sheet(mascotCompact),
  ]);

  static final _sheets = <String, Future<AsciiSheet>>{};
  static final _ready = <String, AsciiSheet>{};

  /// A load first started inside a widget test is bound to its fake clock and never
  /// completes under a real one, so a later suite in the same isolate must start over.
  @visibleForTesting
  static void forget() {
    rootBundle.clear();
    _sheets.clear();
    _ready.clear();
  }

  static Future<AsciiSheet> sheet(String state) => _sheets[state] ??= rootBundle
      .loadString(mascotAsset(state))
      .then((source) {
        final parsed = AsciiSheet.parse(source);
        _ready[state] = parsed;
        return parsed;
      });

  @override
  State<AsciiMascot> createState() => _AsciiMascotState();
}

class _AsciiMascotState extends State<AsciiMascot> with WidgetsBindingObserver {
  AsciiSheet? _sheet;
  GlyphAtlas? _atlas;
  double? _builtFor;
  Timer? _timer;
  final _frame = ValueNotifier(0);
  bool _foreground = true;
  bool _visible = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _adopt(AsciiMascot._ready[widget.state]);
    if (_sheet == null) unawaited(_loadSheet());
  }

  @override
  void didUpdateWidget(AsciiMascot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.state != oldWidget.state) {
      _sheet = null;
      _frame.value = 0;
      _adopt(AsciiMascot._ready[widget.state]);
      if (_sheet == null) unawaited(_loadSheet());
    }
    if (widget.animated != oldWidget.animated) _run();
    if (widget.cellWidth != oldWidget.cellWidth) {
      unawaited(_loadAtlas(MediaQuery.devicePixelRatioOf(context)));
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    unawaited(_loadAtlas(MediaQuery.devicePixelRatioOf(context)));
    final visible = TickerMode.valuesOf(context).enabled;
    if (visible != _visible) {
      _visible = visible;
      _run();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (foreground == _foreground) return;
    _foreground = foreground;
    _run();
  }

  Future<void> _loadSheet() async {
    final wanted = widget.state;
    final loaded = await AsciiMascot.sheet(wanted);
    if (!mounted || widget.state != wanted) return;
    setState(() => _adopt(loaded));
  }

  void _adopt(AsciiSheet? sheet) {
    if (sheet == null) return;
    _sheet = sheet;
    _run();
  }

  Future<void> _loadAtlas(double pixelRatio) async {
    final key = pixelRatio * widget.cellWidth;
    if (_builtFor == key) return;
    _builtFor = key;
    final atlas = await GlyphAtlas.braille(
      cellWidth: widget.cellWidth,
      cellHeight: widget.cellWidth * 2,
      pixelRatio: pixelRatio,
    );
    if (!mounted) return;
    setState(() => _atlas = atlas);
  }

  void _run() {
    _timer?.cancel();
    _timer = null;
    final sheet = _sheet;
    if (sheet == null) return;
    if (!widget.animated || sheet.frames.length < 2) return;
    if (!_foreground || !_visible) return;
    _timer = Timer.periodic(sheet.step, (timer) {
      final next = _frame.value + 1;
      if (next >= sheet.frames.length) {
        if (!sheet.loops) {
          timer.cancel();
          _timer = null;
          return;
        }
        _frame.value = 0;
        return;
      }
      _frame.value = next;
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _frame.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sheet = _sheet;
    if (sheet == null) return const SizedBox.shrink();
    return _grid(sheet);
  }

  Widget _grid(AsciiSheet sheet) {
    final atlas = _atlas;
    if (atlas == null) return const SizedBox.shrink();
    return RepaintBoundary(
      child: CustomPaint(
        size: Size(sheet.cols * atlas.cellWidth, sheet.rows * atlas.cellHeight),
        painter: _MascotPainter(
          sheet: sheet,
          atlas: atlas,
          frame: _frame,
          colour: widget.colour,
          accent: widget.accent,
        ),
      ),
    );
  }
}

class _MascotPainter extends CustomPainter {
  _MascotPainter({
    required this.sheet,
    required this.atlas,
    required this.frame,
    required this.colour,
    required this.accent,
  }) : super(repaint: frame);

  final AsciiSheet sheet;
  final GlyphAtlas atlas;
  final ValueListenable<int> frame;
  final Color colour;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final at = frame.value.clamp(0, sheet.frames.length - 1);
    final current = sheet.frames[at];
    final cells = sheet.cols * sheet.rows;

    final transforms = Float32List(cells * 4);
    final rects = Float32List(cells * 4);
    final colours = Int32List(cells);

    final argb = colour.toARGB32();
    final scale = atlas.scale;
    var drawn = 0;

    void put(int x, int y, int slot, int tint) {
      final i = drawn * 4;
      transforms[i] = scale;
      transforms[i + 1] = 0;
      transforms[i + 2] = x * atlas.cellWidth;
      transforms[i + 3] = y * atlas.cellHeight;
      atlas.rectInto(rects, i, slot);
      colours[drawn] = tint;
      drawn++;
    }

    for (var y = 0; y < sheet.rows; y++) {
      for (var x = 0; x < sheet.cols; x++) {
        if (current.sparkX == x && current.sparkY == y) continue;
        final glyph = current.glyphs[y * sheet.cols + x];
        if (glyph == 0) continue;
        put(x, y, GlyphAtlas.slotOfGlyph(glyph), argb);
      }
    }
    if (current.hasSpark) {
      put(
        current.sparkX,
        current.sparkY,
        GlyphAtlas.slotOfGlyph(AsciiSheet.spark),
        accent.toARGB32(),
      );
    }
    if (drawn == 0) return;

    canvas.drawRawAtlas(
      atlas.image,
      Float32List.sublistView(transforms, 0, drawn * 4),
      Float32List.sublistView(rects, 0, drawn * 4),
      Int32List.sublistView(colours, 0, drawn),
      GlyphAtlas.tint,
      Offset.zero & size,
      Paint()..filterQuality = ui.FilterQuality.none,
    );
  }

  @override
  bool shouldRepaint(_MascotPainter oldDelegate) =>
      oldDelegate.sheet != sheet ||
      oldDelegate.atlas != atlas ||
      oldDelegate.frame != frame ||
      oldDelegate.colour != colour ||
      oldDelegate.accent != accent;
}
