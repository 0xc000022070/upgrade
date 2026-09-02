import 'dart:async';
import 'dart:math';

import 'package:flutter/widgets.dart';

import '../motion.dart';

/// SPEC.md §16b: "glitch is an event, never a state". The controller therefore
/// has no idle animation to speak of — it walks a fixed number of frames after
/// [fire] and returns to [idle], and the seed makes the frame offsets a pure
/// function of the trigger so the same event always looks the same.
class GlitchController extends ChangeNotifier {
  GlitchController();

  Timer? _timer;
  int _frame = -1;
  int _seed = 0;

  /// -1 while idle, otherwise 0..[Effects.glitchFrames] - 1.
  int get frame => _frame;

  bool get idle => _frame < 0;

  int get seed => _seed;

  /// Re-firing mid-sequence restarts it rather than queueing: two rapid state
  /// changes are one visual event, not two overlapping ones.
  void fire({int? seed}) {
    _timer?.cancel();
    _seed = seed ?? DateTime.now().microsecondsSinceEpoch;
    _frame = 0;
    notifyListeners();
    _timer = Timer.periodic(Effects.glitchStep, (timer) {
      _frame++;
      if (_frame >= Effects.glitchFrames) {
        _frame = -1;
        timer.cancel();
        _timer = null;
      }
      notifyListeners();
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    if (_frame < 0) return;
    _frame = -1;
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

/// Horizontal slice displacement: the one primitive shared by the icon glitch
/// (§16b) and the title smear (§16c.4). The child is painted [bands] times, each
/// copy clipped to its band and shifted, so nothing is redrawn at a new size and
/// no shader is involved.
class GlitchSlices extends StatelessWidget {
  const GlitchSlices({
    super.key,
    required this.child,
    required this.seed,
    this.bands = 3,
    this.magnitude = 3,
  });

  final Widget child;
  final int seed;
  final int bands;

  /// Maximum shift in logical pixels; each band draws 1..magnitude.
  final int magnitude;

  @override
  Widget build(BuildContext context) {
    final random = Random(seed);
    final offsets = [
      for (var i = 0; i < bands; i++)
        (random.nextInt(magnitude) + 1) * (random.nextBool() ? 1.0 : -1.0),
    ];
    return Stack(
      clipBehavior: Clip.none,
      children: [
        // The unshifted copy establishes the layout size; the bands are overlays
        // on top of it, so a displaced band never changes the widget's extent.
        Opacity(opacity: 0, child: child),
        for (var i = 0; i < bands; i++)
          Positioned.fill(
            child: ClipRect(
              clipper: _Band(i / bands, (i + 1) / bands),
              child: Transform.translate(
                offset: Offset(offsets[i], 0),
                child: child,
              ),
            ),
          ),
      ],
    );
  }
}

class _Band extends CustomClipper<Rect> {
  const _Band(this.top, this.bottom);

  final double top;
  final double bottom;

  @override
  Rect getClip(Size size) =>
      Rect.fromLTRB(0, size.height * top, size.width, size.height * bottom);

  @override
  bool shouldReclip(_Band oldClipper) =>
      oldClipper.top != top || oldClipper.bottom != bottom;
}
