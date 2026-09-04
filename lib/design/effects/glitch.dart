import 'dart:async';
import 'dart:math';

import 'package:flutter/widgets.dart';

import '../motion.dart';

/// "glitch is an event, never a state". The controller therefore
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

/// One displaced rectangle of the glitch language. Both fields are
/// fractions of the box rather than pixels, so a single plan reads the same on a
/// 20px glyph and on a panel, and the block ranges the spec states as fractions
/// of the glyph need no conversion.
@immutable
class GlitchBlock {
  const GlitchBlock({
    required this.dest,
    required this.shift,
    required this.tone,
  });

  /// Where the block lands, in fractions of the box on both axes.
  final Rect dest;

  /// How far its pixels travelled to get here: what shows inside [dest] is what
  /// sat at `dest` moved back by [shift].
  final Offset shift;

  /// Luminance multiplier, 1 for an untouched block.
  final double tone;

  /// MOSH: the block reached into another band, so what lands here is a
  /// piece of the shape from somewhere it does not belong rather than the
  /// pixels immediately beside it.
  bool get isMosh => shift.dy != 0;

  double get area => dest.width * dest.height;
}

/// The ruling — "the un-glitched shape stays at least 70% intact" — as an
/// area budget the planner spends, rather than a property the block ranges are
/// merely expected to have. Overlapping blocks are charged twice, so the real
/// corruption is at most this.
const glitchCoverage = 0.3;

/// The text ramp steps by roughly this ratio between neighbouring levels
/// (E8 -> 9A -> 6F), which is what shifting the luminance one step means.
const glitchToneDown = 0.69;
const glitchToneUp = 1.45;

/// The block set for one frame. Pure and seeded: the same event always
/// tears the same way, and a test can assert the ruling on the plan itself
/// without rasterising anything.
List<GlitchBlock> planGlitchBlocks(
  int seed, {
  int blocks = 4,
  int fragments = 3,
  bool tone = true,
}) {
  final random = Random(seed);
  final planned = <GlitchBlock>[];
  var budget = glitchCoverage;

  double between(double low, double high) =>
      low + random.nextDouble() * (high - low);
  double sign() => random.nextBool() ? 1.0 : -1.0;
  double toneOf() =>
      tone ? (random.nextBool() ? glitchToneUp : glitchToneDown) : 1.0;

  // One or two of the displaced blocks are moshes.
  final moshes = 1 + random.nextInt(2);

  for (var i = 0; i < blocks; i++) {
    // Height 1/64 to 1/4 of the glyph, width 1/8 to 1/2 of it.
    final height = between(1 / 64, 1 / 4);
    final width = between(1 / 8, 1 / 2);
    if (width * height > budget) break;
    budget -= width * height;
    final left = between(0, 1 - width);
    final top = between(0, 1 - height);
    // Sideways by 1/32 to 1/6 of the glyph width. Nothing keeps that shift
    // inside the box: a block at the edge sampling past it tears off, which is
    // the same thing the cover does at its own frame edges.
    final dx = between(1 / 32, 1 / 6) * sign();
    // A mosh, on the other hand, is only a mosh if it lands on ink — a vertical
    // reach past the box would sample nothing and read as a hole.
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

  // FRAGMENTS: two or three small blocks detach fully and sit in empty
  // space. They stay inside the box — a glyph is mostly empty ground, so there
  // is room, and a crumb thrown past the edge would land on whatever shares the
  // row with the icon instead of on the icon's own emptiness.
  final crumbs = fragments == 0 ? 0 : fragments - random.nextInt(2);
  for (var i = 0; i < crumbs; i++) {
    final height = between(1 / 32, 1 / 10);
    final width = between(1 / 16, 1 / 6);
    if (width * height > budget) break;
    budget -= width * height;
    // Sampled from the middle, where a centred glyph keeps its ink, then thrown
    // far enough to clear the region it came from.
    final sourceLeft = between(0.2, 0.8 - width);
    final sourceTop = between(0.2, 0.8 - height);
    final left = _thrown(sourceLeft, width, between(1 / 4, 1 / 2));
    final top = _thrown(sourceTop, height, between(1 / 8, 1 / 3));
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

/// Clamps a mosh's vertical reach so its source stays on the glyph.
double _reachable(double top, double height, double dy) {
  final low = top - (1 - height);
  if (dy >= low && dy <= top) return dy;
  if (-dy >= low && -dy <= top) return -dy;
  return dy.clamp(low, top);
}

/// Moves a fragment by [delta] toward whichever side has room for it.
double _thrown(double source, double size, double delta) {
  if (source + delta <= 1 - size) return source + delta;
  return max(0.0, source - delta);
}

/// The block language: the child is painted once intact, then a small set
/// of displaced rectangles is painted over it. The blocks are overlays and never
/// holes — cutting a hole would need a ground colour to fill it with, and a flat
/// patch of ground is exactly what the grain behind everything is not.
class GlitchBlocks extends StatelessWidget {
  const GlitchBlocks({
    super.key,
    required this.child,
    required this.seed,
    this.blocks = 4,
    this.fragments = 3,
    this.tone = true,
  });

  final Widget child;
  final int seed;

  /// How many displaced blocks to attempt; [glitchCoverage] may cut the set
  /// short, so this is a ceiling rather than a count.
  final int blocks;

  /// Ceiling on the detached crumbs; 0 turns them off for a surface with no
  /// empty space of its own to drop them into.
  final int fragments;

  /// The accent frame is the app's single colour event, so that
  /// frame asks for no per-block luminance step.
  final bool tone;

  @override
  Widget build(BuildContext context) {
    final plan = planGlitchBlocks(
      seed,
      blocks: blocks,
      fragments: fragments,
      tone: tone,
    );
    return Stack(
      clipBehavior: Clip.none,
      children: [
        // The intact copy is two things at once: the layout size, so a displaced
        // block never changes the widget's extent, and the 70% that
        // has to survive underneath the corruption.
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
    // RGB scaled uniformly with alpha untouched: a tone step is a luminance
    // move, so a block is never a second colour on screen.
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
    // Block heights go down to 1/64 of the glyph, which on a 20px icon
    // rounds to nothing. A block thinner than a pixel is not a subtle block, it
    // is an absent one.
    return rect.height >= 1
        ? rect
        : Rect.fromLTWH(rect.left, rect.top, rect.width, 1);
  }

  @override
  bool shouldReclip(_BlockClip oldClipper) => oldClipper.dest != dest;
}

/// Screen-level events (boot, project detail entry) use the same
/// language at panel scale. A panel has no signal variant and no accent copy to
/// swap to the way an icon does, so its sequence is block sets alone — and like
/// the icon it ends on the clean shape rather than on a torn one.
class GlitchPanel extends StatelessWidget {
  const GlitchPanel({super.key, required this.controller, required this.child});

  final GlitchController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        if (controller.idle || controller.frame >= Effects.glitchFrames - 1) {
          return child!;
        }
        return GlitchBlocks(
          seed: controller.seed + controller.frame,
          // A panel is wide enough that a glyph's block count reads as three
          // stray lines across it; the area budget still caps the set.
          blocks: 6,
          child: child!,
        );
      },
      child: child,
    );
  }
}
