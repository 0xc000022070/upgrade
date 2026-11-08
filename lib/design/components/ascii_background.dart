import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'package:upgrade/design/ascii/atlas.dart';
import 'package:upgrade/design/ascii/effects.dart';
import 'package:upgrade/design/ascii/noise.dart';
import 'package:upgrade/design/ascii/ramp.dart';
import 'package:upgrade/design/ascii/wallpaper.dart';
import 'package:upgrade/design/motion.dart';
import 'package:upgrade/design/typography.dart';

class AsciiBackground extends StatefulWidget {
  const AsciiBackground({
    super.key,
    required this.child,
    required this.tick,
    required this.colour,
    this.wallpaper,
  });

  final Widget child;

  final ValueListenable<int> tick;

  final Color colour;

  final Wallpaper? wallpaper;

  static const fontSize = 11.0;

  static const opacity = 0.06;

  static const dwell = Duration(seconds: 40);

  static int get _dwellTicks =>
      (dwell.inMicroseconds / Effects.staticStep.inMicroseconds).round();

  static int effectAt(int tick, int epoch) =>
      (epoch + tick ~/ _dwellTicks) % asciiEffects.length;

  @override
  State<AsciiBackground> createState() => _AsciiBackgroundState();
}

final _epoch = DateTime.now().millisecondsSinceEpoch;

class _AsciiBackgroundState extends State<AsciiBackground> {
  GlyphAtlas? _atlas;
  (double, bool)? _builtFor;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    unawaited(_load(MediaQuery.devicePixelRatioOf(context)));
  }

  @override
  void didUpdateWidget(AsciiBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((oldWidget.wallpaper == null) != (widget.wallpaper == null)) {
      _atlas = null;
      unawaited(_load(MediaQuery.devicePixelRatioOf(context)));
    }
  }

  Future<void> _load(double pixelRatio) async {
    final square = widget.wallpaper != null;
    if (_builtFor == (pixelRatio, square)) return;
    _builtFor = (pixelRatio, square);
    final advance = monoAdvance(FontFamilies.mono, AsciiBackground.fontSize);
    final atlas = await GlyphAtlas.of(
      cellWidth: square ? Wallpaper.cell : advance,
      cellHeight: square ? Wallpaper.cell : advance * 2,
      fontSize: square ? Wallpaper.fontSize : AsciiBackground.fontSize,
      fontFamily: FontFamilies.mono,
      pixelRatio: pixelRatio,
    );
    if (!mounted || _builtFor != (pixelRatio, square)) return;
    setState(() => _atlas = atlas);
  }

  @override
  Widget build(BuildContext context) {
    final wallpaper = widget.wallpaper;
    return Stack(
      children: [
        if (wallpaper != null)
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: wallpaper.ground,
                ),
              ),
            ),
          ),
        Positioned.fill(
          child: RepaintBoundary(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _FieldPainter(
                  tick: widget.tick,
                  atlas: _atlas,
                  colour: widget.colour.withValues(
                    alpha: AsciiBackground.opacity,
                  ),
                  wallpaper: wallpaper,
                ),
              ),
            ),
          ),
        ),
        widget.child,
      ],
    );
  }
}

class _FieldPainter extends CustomPainter {
  _FieldPainter({
    required this.tick,
    required this.atlas,
    required this.colour,
    required this.wallpaper,
  }) : super(repaint: tick);

  final ValueListenable<int> tick;
  final GlyphAtlas? atlas;
  final Color colour;
  final Wallpaper? wallpaper;

  static Float64List? _shade;
  static Float32List? _transforms;
  static Float32List? _rects;
  static Int32List? _colours;
  static int _capacity = 0;

  @override
  void paint(Canvas canvas, Size size) {
    final glyphs = atlas;
    if (glyphs == null) return;

    final cols = (size.width / glyphs.cellWidth).ceil();
    final rows = (size.height / glyphs.cellHeight).ceil();
    if (cols <= 0 || rows <= 0) return;

    final cells = cols * rows;
    if (cells > _capacity) {
      _capacity = cells;
      _shade = Float64List(cells);
      _transforms = Float32List(cells * 4);
      _rects = Float32List(cells * 4);
      _colours = Int32List(cells);
    }
    final shade = _shade!;
    final transforms = _transforms!;
    final rects = _rects!;
    final colours = _colours!;

    final now = tick.value;
    shade.fillRange(0, cells, 0.0);
    final scene = wallpaper;
    var tileGlyph = 0;
    if (scene == null) {
      asciiEffects[AsciiBackground.effectAt(now, _epoch)].render(
        now.toDouble(),
        cols,
        rows,
        shade,
      );
    } else {
      final field = Field(cols, rows, shade, colours);
      scene.render(now.toDouble(), field);
      _paintScene(canvas, size, glyphs, field);
      tileGlyph = scene.ground.last.withValues(alpha: _punch).toARGB32();
    }

    final argb = colour.toARGB32();
    final scale = glyphs.scale;
    var drawn = 0;
    for (var y = 0; y < rows; y++) {
      for (var x = 0; x < cols; x++) {
        final cell = y * cols + x;
        // A sprite names its glyph exactly; dither is for shaded fields only.
        final glyph = asciiGlyph(
          shade[cell],
          scene == null ? bayer(x, y) : 0.5,
        );
        if (glyph == 0) continue;
        final at = drawn * 4;
        transforms[at] = scale;
        transforms[at + 1] = 0;
        transforms[at + 2] = x * glyphs.cellWidth;
        transforms[at + 3] = y * glyphs.cellHeight;
        glyphs.rectInto(rects, at, GlyphAtlas.slotOfGlyph(glyph));
        colours[drawn] = scene == null
            ? argb
            : Field.isTile(colours[cell])
            ? tileGlyph
            : colours[cell];
        drawn++;
      }
    }
    if (drawn == 0) return;

    canvas.drawRawAtlas(
      glyphs.image,
      Float32List.sublistView(transforms, 0, drawn * 4),
      Float32List.sublistView(rects, 0, drawn * 4),
      Int32List.sublistView(colours, 0, drawn),
      GlyphAtlas.tint,
      Offset.zero & size,
      Paint()..filterQuality = ui.FilterQuality.none,
    );
  }

  static const _punch = 0.7;

  void _paintScene(Canvas canvas, Size size, GlyphAtlas glyphs, Field field) {
    final cw = glyphs.cellWidth;
    final ch = glyphs.cellHeight;
    for (final glow in field.glows) {
      final centre = Offset(glow.x * cw, glow.y * ch);
      final radius = glow.radius * cw;
      canvas.drawCircle(
        centre,
        radius,
        Paint()
          ..shader = ui.Gradient.radial(centre, radius, [
            Color(glow.argb),
            Color(glow.argb & 0x00FFFFFF),
          ]),
      );
    }
    canvas.saveLayer(
      Offset.zero & size,
      Paint()
        ..imageFilter = ui.ImageFilter.blur(
          sigmaX: Wallpaper.bloom,
          sigmaY: Wallpaper.bloom,
        ),
    );
    _tiles(canvas, field, cw, ch, 0.7);
    canvas.restore();
    _tiles(canvas, field, cw, ch, Wallpaper.opacity);
  }

  void _tiles(Canvas canvas, Field field, double cw, double ch, double alpha) {
    final paint = Paint();
    for (var y = 0; y < field.height; y++) {
      for (var x = 0; x < field.width; x++) {
        final cell = y * field.width + x;
        final level = field.shade[cell];
        final argb = field.colours[cell];
        if (level <= 0 || !Field.isTile(argb)) continue;
        paint.color = Color(argb & 0xFFFFFFFF)
            .withValues(alpha: alpha * (0.55 + 0.45 * level));
        canvas.drawRect(
          Rect.fromLTWH(x * cw + 0.5, y * ch + 0.5, cw - 1, ch - 1),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_FieldPainter oldDelegate) =>
      oldDelegate.atlas != atlas ||
      oldDelegate.colour != colour ||
      oldDelegate.wallpaper != wallpaper ||
      oldDelegate.tick != tick;
}

class AsciiBackgroundDriver extends StatefulWidget {
  const AsciiBackgroundDriver({
    super.key,
    required this.child,
    required this.colour,
    this.enabled = true,
    this.wallpaper,
    this.throttled = const Stream.empty(),
  });

  final Widget child;
  final Color colour;
  final bool enabled;
  final Wallpaper? wallpaper;

  /// Pauses the static while it emits true.
  final Stream<bool> throttled;

  @override
  State<AsciiBackgroundDriver> createState() => _AsciiBackgroundDriverState();
}

class _AsciiBackgroundDriverState extends State<AsciiBackgroundDriver>
    with WidgetsBindingObserver {
  final _tick = ValueNotifier(0);

  Timer? _timer;
  StreamSubscription<bool>? _throttleSub;

  bool _foreground = true;
  bool _visible = true;
  bool _reduceMotion = false;
  bool _throttled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _throttleSub = widget.throttled.listen((value) {
      if (!mounted || value == _throttled) return;
      _throttled = value;
      _sync();
    });
    _sync();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    _visible = TickerMode.valuesOf(context).enabled;
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _sync();
  }

  @override
  void didUpdateWidget(AsciiBackgroundDriver oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enabled != oldWidget.enabled) _sync();
  }

  void _sync() {
    final run =
        widget.enabled &&
        _foreground &&
        _visible &&
        !_reduceMotion &&
        !_throttled;
    if (run == (_timer != null)) return;
    if (!run) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    _timer = Timer.periodic(Effects.staticStep, (_) => _tick.value++);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _throttleSub?.cancel();
    _timer?.cancel();
    _tick.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AsciiBackground(
      tick: _tick,
      colour: widget.colour,
      wallpaper: widget.wallpaper,
      child: widget.child,
    );
  }
}
