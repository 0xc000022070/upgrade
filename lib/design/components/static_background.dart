import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../platform/device.dart';
import '../motion.dart';

class StaticBackground extends StatefulWidget {
  const StaticBackground({
    super.key,
    required this.child,
    required this.offset,
  });

  final Widget child;

  final ValueListenable<Offset> offset;

  /// The tile is authored at 512 logical pixels with mirrored edges, so a shift by a whole
  /// tile is invisible and any offset reduces into one tile.
  static const tile = 512.0;

  static const _asset = 'assets/textures/noise-fine.png';

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
        // The grain owns its own layer. Without the boundary its ten repaints a second are ten
        // repaints of every panel above it.
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

/// Decoded once per process rather than once per route.
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
    // One rect under a repeating shader: the tiling is the GPU's, so a jump costs a
    // translated matrix instead of a grid of blits and the layer has no edge to overdraw.
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = ui.ImageShader(
          image,
          TileMode.repeated,
          TileMode.repeated,
          Matrix4.translationValues(phase.dx, phase.dy, 0).storage,
        )
        // Only the alpha is read: a paint's alpha modulates its shader.
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

/// A timer and not a `Ticker`: a ticker asks for a frame on every vsync for as long as
/// it runs, so the pipeline never idles and the device never cools. The 100ms rate is
/// the effect.
class StaticBackgroundDriver extends StatefulWidget {
  const StaticBackgroundDriver({
    super.key,
    required this.child,
    this.enabled = true,
  });

  final Widget child;

  final bool enabled;

  @override
  State<StaticBackgroundDriver> createState() => _StaticBackgroundDriverState();
}

class _StaticBackgroundDriverState extends State<StaticBackgroundDriver>
    with WidgetsBindingObserver {
  // Fixed seed: the static plays the same sequence every launch.
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
    // A `Ticker` followed the ambient [TickerMode] for free; a timer has to be told. A
    // pushed opaque route switches it off for the screens behind it.
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
