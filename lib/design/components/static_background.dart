import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../platform/device.dart';
import '../motion.dart';

/// SPEC.md §16b.1: the scaffold grain is one alpha-only tile, never regenerated
/// and never a shader. Motion comes from jumping the tile's phase, so the only
/// input is an offset; [StaticBackgroundDriver] decides when it moves.
class StaticBackground extends StatefulWidget {
  const StaticBackground({
    super.key,
    required this.child,
    required this.offset,
  });

  final Widget child;

  /// The phase arrives as a listenable rather than a value so a jump repaints
  /// the grain and nothing else: the driver's `build` never runs on a tick, no
  /// element rebuilds and no box is laid out again.
  final ValueListenable<Offset> offset;

  /// The tile is authored at 512 logical pixels with mirrored edges, so a shift
  /// by a whole tile is invisible and any offset can be reduced into one tile.
  static const tile = 512.0;

  static const _asset = 'assets/textures/noise-fine.png';

  /// §16b.1 keeps the grain at the edge of visibility: it is texture, not a
  /// layer anyone should be able to point at.
  static const _opacity = 0.04;

  @override
  State<StaticBackground> createState() => _StaticBackgroundState();
}

class _StaticBackgroundState extends State<StaticBackground> {
  ui.Image? _tile;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final image = await _tileImage();
    if (!mounted) return;
    setState(() => _tile = image);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // The grain owns its own layer. Without the boundary the ten repaints a
        // second it asks for are ten repaints of every panel above it, which is
        // what pinned the device warm.
        Positioned.fill(
          child: RepaintBoundary(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _GrainPainter(offset: widget.offset, tile: _tile),
              ),
            ),
          ),
        ),
        widget.child,
      ],
    );
  }
}

/// Decoded once per process rather than once per route: every driver paints the
/// same tile, and the decode is the only expensive thing about it.
Future<ui.Image>? _pendingTile;

Future<ui.Image> _tileImage() => _pendingTile ??= () async {
  final data = await rootBundle.load(StaticBackground._asset);
  final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
  final frame = await codec.getNextFrame();
  return frame.image;
}();

class _GrainPainter extends CustomPainter {
  _GrainPainter({required this.offset, required this.tile})
    : super(repaint: offset);

  final ValueListenable<Offset> offset;
  final ui.Image? tile;

  @override
  void paint(Canvas canvas, Size size) {
    final image = tile;
    if (image == null) return;
    final phase = Offset(
      offset.value.dx % StaticBackground.tile,
      offset.value.dy % StaticBackground.tile,
    );
    // One rect under a repeating shader. The tiling is the GPU's, so a jump
    // costs a translated matrix instead of a grid of image blits, and the layer
    // no longer has to overdraw by a tile on every edge — a repeated shader has
    // no edge to expose.
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = ui.ImageShader(
          image,
          TileMode.repeated,
          TileMode.repeated,
          Matrix4.translationValues(phase.dx, phase.dy, 0).storage,
        )
        // Only the alpha is read here: a paint's alpha modulates its shader,
        // which is the job the DecorationImage opacity used to do.
        ..color = const Color.fromRGBO(
          255,
          255,
          255,
          StaticBackground._opacity,
        ),
    );
  }

  @override
  bool shouldRepaint(_GrainPainter oldDelegate) =>
      oldDelegate.tile != tile || oldDelegate.offset != offset;
}

/// The TV-static half of §16b.1. The offset is advanced on a timer, once every
/// 100ms: a `Ticker` would land the jumps on real frames, but it also asks for
/// a frame on every vsync for as long as it runs, so the pipeline never idles
/// and the device never cools. The rate is the effect — driving this at 60fps
/// would read as smooth drift rather than static — so the frames the app costs
/// should be the ten a second that change something, and no others.
class StaticBackgroundDriver extends StatefulWidget {
  const StaticBackgroundDriver({
    super.key,
    required this.child,
    this.enabled = true,
  });

  final Widget child;

  /// SPEC.md §39.16's `[ STATIC ] OFF`. False takes the same path a thermal
  /// throttle does: the timer stops and the tile stays where it last landed, so
  /// the grain is still painted and only its motion is gone. The preference
  /// arrives from the database, which this layer must not know about, so it
  /// comes in as a flag and the app layer reads it.
  final bool enabled;

  @override
  State<StaticBackgroundDriver> createState() => _StaticBackgroundDriverState();
}

class _StaticBackgroundDriverState extends State<StaticBackgroundDriver>
    with WidgetsBindingObserver {
  // Fixed seed: SPEC.md §16 wants effects deterministic, so the static plays the
  // same sequence every launch rather than being a source of real randomness.
  final _random = Random(0xB7FF2A);
  final _offset = ValueNotifier(Offset.zero);

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
    // The stream replays the current value on subscribe, so no separate read is
    // needed; on desktop and in tests the channel is absent and it stays false.
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
    // A `Ticker` followed the ambient [TickerMode] for free; a timer has to be
    // told. A pushed opaque route switches it off for the screens behind it,
    // and a covered driver must keep costing nothing.
    _visible = TickerMode.valuesOf(context).enabled;
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _sync();
  }

  @override
  void didUpdateWidget(StaticBackgroundDriver oldWidget) {
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
    _timer = Timer.periodic(Effects.staticStep, (_) {
      _offset.value = Offset(
        _random.nextDouble() * StaticBackground.tile,
        _random.nextDouble() * StaticBackground.tile,
      );
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _throttleSub?.cancel();
    _timer?.cancel();
    _offset.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StaticBackground(offset: _offset, child: widget.child);
  }
}
