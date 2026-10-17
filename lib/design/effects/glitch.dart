import 'dart:async';
import 'dart:math';

import 'package:flutter/widgets.dart';

import 'package:striked/design/motion.dart';

class GlitchController extends ChangeNotifier {
  GlitchController({this.frames = Effects.glitchFrames});

  final int frames;

  Timer? _timer;
  int _frame = -1;
  int _seed = 0;

  /// -1 while idle, otherwise 0..[frames] - 1.
  int get frame => _frame;

  bool get idle => _frame < 0;

  int get seed => _seed;

  /// Re-firing mid-sequence restarts it rather than queueing.
  void fire({int? seed}) {
    _timer?.cancel();
    _seed = seed ?? DateTime.now().microsecondsSinceEpoch;
    _frame = 0;
    notifyListeners();
    _timer = Timer.periodic(Effects.glitchStep, (timer) {
      _frame++;
      if (_frame >= frames) {
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

@immutable
class GlitchBlock {
  const GlitchBlock({
    required this.dest,
    required this.shift,
    required this.tone,
  });

  final Rect dest;

  /// What shows inside [dest] is what sat at `dest` moved back by [shift].
  final Offset shift;

  final double tone;

  bool get isMosh => shift.dy != 0;

  double get area => dest.width * dest.height;
}

/// An area budget the planner spends rather than a property the block ranges are merely
/// expected to have. Overlapping blocks are charged twice, so the real corruption is at
/// most this.
const glitchCoverage = 0.3;

/// The text ramp steps by roughly this ratio between neighbouring levels (E8 -> 9A ->
/// 6F), which is what shifting the luminance one step means.
const glitchToneDown = 0.69;
const glitchToneUp = 1.45;

List<GlitchBlock> planGlitchBlocks(
  int seed, {
  int blocks = 4,
  int fragments = 3,
  bool tone = true,
  double coverage = glitchCoverage,
  double reach = 1,
}) {
  final random = Random(seed);
  final planned = <GlitchBlock>[];
  var budget = coverage;

  double between(double low, double high) =>
      low + random.nextDouble() * (high - low);
  double sign() => random.nextBool() ? 1.0 : -1.0;
  double toneOf() =>
      tone ? (random.nextBool() ? glitchToneUp : glitchToneDown) : 1.0;

  final moshes = 1 + random.nextInt(2);

  for (var i = 0; i < blocks; i++) {
    final height = between(1 / 64, 1 / 4);
    final width = between(1 / 8, 1 / 2);
    if (width * height > budget) break;
    budget -= width * height;
    final left = between(0, 1 - width);
    final top = between(0, 1 - height);
    // Nothing keeps a sideways shift inside the box: a block at the edge samples past it
    // and tears off.
    final dx = between(1 / 32, 1 / 6) * reach * sign();
    // A mosh is only a mosh if it lands on ink — a vertical reach past the box would sample
    // nothing and read as a hole.
    final dy = i < moshes
        ? _reachable(top, height, between(1 / 8, 1 / 2) * sign())
        : 0.0;
    planned.add(
      GlitchBlock(
        dest: Rect.fromLTWH(left, top, width, height),
        shift: Offset(dx, dy),
        tone: toneOf(),
      ),
    );
  }

  // Fragments stay inside the box: a crumb thrown past the edge would land on whatever
  // shares the row with the icon instead of on the icon's own emptiness.
  final crumbs = fragments == 0 ? 0 : fragments - random.nextInt(2);
  for (var i = 0; i < crumbs; i++) {
    final height = between(1 / 32, 1 / 10);
    final width = between(1 / 16, 1 / 6);
    if (width * height > budget) break;
    budget -= width * height;
    final sourceLeft = between(0.2, 0.8 - width);
    final sourceTop = between(0.2, 0.8 - height);
    final left = _thrown(sourceLeft, width, between(1 / 4, 1 / 2) * reach);
    final top = _thrown(sourceTop, height, between(1 / 8, 1 / 3) * reach);
    planned.add(
      GlitchBlock(
        dest: Rect.fromLTWH(left, top, width, height),
        shift: Offset(left - sourceLeft, top - sourceTop),
        tone: toneOf(),
      ),
    );
  }

  return planned;
}

double _reachable(double top, double height, double dy) {
  final low = top - (1 - height);
  if (dy >= low && dy <= top) return dy;
  if (-dy >= low && -dy <= top) return -dy;
  return dy.clamp(low, top);
}

double _thrown(double source, double size, double delta) {
  if (source + delta <= 1 - size) return source + delta;
  return max(0.0, source - delta);
}

class GlitchBlocks extends StatelessWidget {
  const GlitchBlocks({
    super.key,
    required this.child,
    required this.seed,
    this.blocks = 4,
    this.fragments = 3,
    this.tone = true,
    this.coverage = glitchCoverage,
    this.reach = 1,
  });

  final Widget child;
  final int seed;

  final int blocks;

  final int fragments;

  final bool tone;

  final double coverage;

  final double reach;

  @override
  Widget build(BuildContext context) {
    final plan = planGlitchBlocks(
      seed,
      blocks: blocks,
      fragments: fragments,
      tone: tone,
      coverage: coverage,
      reach: reach,
    );
    return Stack(
      clipBehavior: Clip.none,
      children: [
        // The intact copy is the layout size, so a displaced block never changes the widget's
        // extent.
        child,
        for (final block in plan)
          Positioned.fill(
            child: ClipRect(
              clipper: _BlockClip(block.dest),
              child: FractionalTranslation(
                translation: block.shift,
                child: _toned(block.tone, child),
              ),
            ),
          ),
      ],
    );
  }

  static Widget _toned(double tone, Widget child) {
    if (tone == 1) return child;
    // RGB scaled uniformly with alpha untouched: a tone step is a luminance move, never a
    // second colour on screen.
    return ColorFiltered(
      colorFilter: ColorFilter.matrix([
        tone, 0, 0, 0, 0, //
        0, tone, 0, 0, 0, //
        0, 0, tone, 0, 0, //
        0, 0, 0, 1, 0, //
      ]),
      child: child,
    );
  }
}

class _BlockClip extends CustomClipper<Rect> {
  const _BlockClip(this.dest);

  final Rect dest;

  @override
  Rect getClip(Size size) {
    final rect = Rect.fromLTWH(
      dest.left * size.width,
      dest.top * size.height,
      dest.width * size.width,
      dest.height * size.height,
    );
    // Block heights go down to 1/64 of the glyph, which on a 20px icon rounds to nothing.
    return rect.height >= 1
        ? rect
        : Rect.fromLTWH(rect.left, rect.top, rect.width, 1);
  }

  @override
  bool shouldReclip(_BlockClip oldClipper) => oldClipper.dest != dest;
}

class GlitchPanel extends StatelessWidget {
  const GlitchPanel({
    super.key,
    required this.controller,
    required this.child,
    this.blocks = 6,
    this.fragments = 3,
  });

  final GlitchController controller;
  final Widget child;
  final int blocks;
  final int fragments;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        if (controller.idle || controller.frame >= controller.frames - 1) {
          return child!;
        }
        return GlitchBlocks(
          seed: controller.seed + controller.frame,
          blocks: blocks,
          fragments: fragments,
          child: child!,
        );
      },
      child: child,
    );
  }
}
