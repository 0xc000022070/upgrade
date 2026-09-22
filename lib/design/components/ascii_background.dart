import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../platform/device.dart';
import '../ascii/atlas.dart';
import '../ascii/effects.dart';
import '../ascii/noise.dart';
import '../ascii/ramp.dart';
import '../motion.dart';
import '../typography.dart';

class AsciiBackground extends StatefulWidget {
  const AsciiBackground({
    super.key,
    required this.child,
    required this.tick,
    required this.colour,
  });

  final Widget child;

  final ValueListenable<int> tick;

  final Color colour;

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
  double? _builtFor;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    unawaited(_load(MediaQuery.devicePixelRatioOf(context)));
  }

  Future<void> _load(double pixelRatio) async {
    if (_builtFor == pixelRatio) return;
    _builtFor = pixelRatio;
    final advance = monoAdvance(FontFamilies.mono, AsciiBackground.fontSize);
    final atlas = await GlyphAtlas.of(
      cellWidth: advance,
      cellHeight: advance * 2,
      fontSize: AsciiBackground.fontSize,
      fontFamily: FontFamilies.mono,
      pixelRatio: pixelRatio,
    );
    if (!mounted) return;
    setState(() => _atlas = atlas);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
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
  _FieldPainter({required this.tick, required this.atlas, required this.colour})
    : super(repaint: tick);

  final ValueListenable<int> tick;
  final GlyphAtlas? atlas;
  final Color colour;

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
    asciiEffects[AsciiBackground.effectAt(now, _epoch)].render(
      now.toDouble(),
      cols,
      rows,
      shade,
    );

    final argb = colour.toARGB32();
    final scale = glyphs.scale;
    var drawn = 0;
    for (var y = 0; y < rows; y++) {
      for (var x = 0; x < cols; x++) {
        final glyph = asciiGlyph(shade[y * cols + x], bayer(x, y));
        if (glyph == 0) continue;
        final at = drawn * 4;
        transforms[at] = scale;
        transforms[at + 1] = 0;
        transforms[at + 2] = x * glyphs.cellWidth;
        transforms[at + 3] = y * glyphs.cellHeight;
        glyphs.rectInto(rects, at, GlyphAtlas.slotOfGlyph(glyph));
        colours[drawn] = argb;
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

  @override
  bool shouldRepaint(_FieldPainter oldDelegate) =>
      oldDelegate.atlas != atlas ||
      oldDelegate.colour != colour ||
      oldDelegate.tick != tick;
}

class AsciiBackgroundDriver extends StatefulWidget {
  const AsciiBackgroundDriver({
    super.key,
    required this.child,
    required this.colour,
    this.enabled = true,
  });

  final Widget child;
  final Color colour;
  final bool enabled;

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
    _throttleSub = Device.throttleChanges().listen((value) {
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
      child: widget.child,
    );
  }
}
