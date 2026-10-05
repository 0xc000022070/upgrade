import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../design/tokens.dart';
import '../../design/spacing.dart';
import '../../platform/workspace/workspace_model.dart';
import 'diff_jump.dart';

typedef DiffStreak = ({int start, int end, DiffLineKind kind});

/// Neighbours of one kind are one streak: a block of forty removed lines is one place in
/// the file, not forty, and the strip that draws this is too narrow to tell them apart
/// anyway.
List<DiffStreak> diffStreaks(List<DiffLine> lines) {
  final streaks = <DiffStreak>[];
  for (var at = 0; at < lines.length; at++) {
    final kind = lines[at].kind;
    if (kind != DiffLineKind.added && kind != DiffLineKind.removed) continue;
    var end = at + 1;
    while (end < lines.length && lines[end].kind == kind) {
      end++;
    }
    streaks.add((start: at, end: end, kind: kind));
    at = end - 1;
  }
  return streaks;
}

class DiffMap extends StatelessWidget {
  const DiffMap({
    super.key,
    required this.streaks,
    required this.rows,
    required this.jumps,
  });

  final List<DiffStreak> streaks;

  final int rows;

  final DiffJumps jumps;

  static const width = Spacing.xl;

  void _jump(double at, double height) {
    if (!jumps.scroll.hasClients || height <= 0) return;
    final position = jumps.scroll.position;
    final content = position.maxScrollExtent + position.viewportDimension;
    // The touch names the middle of what the reader wants to see, not its top: a mark tapped
    // at the very bottom of the strip is still a place to read around rather than a place to
    // start.
    final want = at / height * content - position.viewportDimension / 2;
    jumps.to(want);
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: LayoutBuilder(
      builder: (context, constraints) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (tap) => _jump(tap.localPosition.dy, constraints.maxHeight),
        // Taken at the touch and not at the start of the drag: a thumb that rests before it
        // moves has already jumped once by then, and the way back would be owed to where that
        // jump landed.
        onVerticalDragDown: (drag) => jumps.hold(),
        onVerticalDragUpdate: (drag) =>
            _jump(drag.localPosition.dy, constraints.maxHeight),
        onVerticalDragEnd: (drag) => jumps.release(),
        onVerticalDragCancel: jumps.release,
        child: CustomPaint(
          size: Size.infinite,
          painter: _MapPainter(
            streaks: streaks,
            rows: rows,
            scroll: jumps.scroll,
            tokens: context.tokens,
          ),
        ),
      ),
    ),
  );
}

class _MapPainter extends CustomPainter {
  _MapPainter({
    required this.streaks,
    required this.rows,
    required this.scroll,
    required this.tokens,
  }) : super(repaint: scroll);

  final List<DiffStreak> streaks;
  final int rows;
  final ScrollController scroll;
  final UpgradeTokens tokens;

  /// A single changed line in a file of thousands is a fraction of a pixel tall. It is
  /// drawn at the smallest height a thumb can be aimed at instead.
  static const _leastMark = 3.0;

  static const _markInset = Spacing.md;

  @override
  void paint(Canvas canvas, Size size) {
    if (rows == 0 || size.height <= 0) return;
    final edge = Paint()..color = tokens.borderSubtle;
    canvas.drawRect(Rect.fromLTWH(0, 0, Borders.hairline, size.height), edge);

    final mark = Paint();
    for (final streak in streaks) {
      mark.color = streak.kind == DiffLineKind.added
          ? tokens.accent
          : tokens.danger;
      final top = streak.start / rows * size.height;
      final height = math.max(
        (streak.end - streak.start) / rows * size.height,
        _leastMark,
      );
      canvas.drawRect(
        Rect.fromLTWH(
          _markInset,
          math.min(top, size.height - height),
          size.width - _markInset - Spacing.xs,
          height,
        ),
        mark,
      );
    }

    if (!scroll.hasClients) return;
    final position = scroll.position;
    final content = position.maxScrollExtent + position.viewportDimension;
    if (content <= 0) return;
    final height = math.min(
      position.viewportDimension / content * size.height,
      size.height,
    );
    final top = math.max(
      0.0,
      math.min(position.pixels / content * size.height, size.height - height),
    );
    final window = Rect.fromLTWH(
      Borders.hairline,
      top,
      size.width - Borders.hairline,
      height,
    );
    canvas.drawRect(window, Paint()..color = tokens.diffMapWindow);
    // A fill alone is legible against the ground and not against a run of marks, which is
    // exactly where knowing what is on screen matters most.
    final bracket = Paint()..color = tokens.textDisabled;
    canvas.drawRect(
      Rect.fromLTWH(window.left, window.top, window.width, Borders.hairline),
      bracket,
    );
    canvas.drawRect(
      Rect.fromLTWH(
        window.left,
        window.bottom - Borders.hairline,
        window.width,
        Borders.hairline,
      ),
      bracket,
    );
  }

  @override
  bool shouldRepaint(_MapPainter old) =>
      !identical(old.streaks, streaks) ||
      old.rows != rows ||
      !identical(old.scroll, scroll) ||
      old.tokens != tokens;
}
