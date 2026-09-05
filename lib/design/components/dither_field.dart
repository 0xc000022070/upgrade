import 'dart:ui' show PointMode;

import 'package:flutter/widgets.dart';

import '../colors.dart';

/// Empty space is filled with an ordered-dither dot field, not
/// left blank. Bayer thresholds give a fixed, non-random pattern, which is what
/// separates this from noise — it never animates and never needs a seed.
class DitherField extends StatelessWidget {
  const DitherField({super.key, this.level = 3, this.child});

  /// 0-16. Higher lights more of the 4x4 cell; 3 is a sparse technical field.
  final int level;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _DitherPainter(level), child: child);
  }
}

class _DitherPainter extends CustomPainter {
  const _DitherPainter(this.level);

  final int level;

  static const _bayer = [
    [0, 8, 2, 10],
    [12, 4, 14, 6],
    [3, 11, 1, 9],
    [15, 7, 13, 5],
  ];

  /// Dots sit on a 3px lattice with a 2px square: at 1px on a 3x density
  /// screen they disappear under the StaticBackground grain instead of reading
  /// as a deliberate field.
  static const _lattice = 3.0;
  static const _dot = 2.0;

  @override
  void paint(Canvas canvas, Size size) {
    final points = <Offset>[];
    for (var y = 0; y * _lattice < size.height; y++) {
      for (var x = 0; x * _lattice < size.width; x++) {
        if (_bayer[y % 4][x % 4] >= level) continue;
        points.add(Offset(x * _lattice, y * _lattice));
      }
    }
    canvas.drawPoints(
      PointMode.points,
      points,
      Paint()
        ..color = SpectacleColors.textMuted.withValues(alpha: 0.25)
        ..strokeWidth = _dot
        ..strokeCap = StrokeCap.square,
    );
  }

  @override
  bool shouldRepaint(_DitherPainter oldDelegate) => oldDelegate.level != level;
}
