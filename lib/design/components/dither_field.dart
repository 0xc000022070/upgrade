import 'dart:ui' show PointMode;

import 'package:flutter/widgets.dart';

import '../tokens.dart';

class DitherField extends StatelessWidget {
  const DitherField({super.key, this.level = 3, this.child});

  final int level;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _DitherPainter(level, context.tokens.textMuted),
      child: child,
    );
  }
}

class _DitherPainter extends CustomPainter {
  const _DitherPainter(this.level, this.dotColor);

  final int level;
  final Color dotColor;

  static const _bayer = [
    [0, 8, 2, 10],
    [12, 4, 14, 6],
    [3, 11, 1, 9],
    [15, 7, 13, 5],
  ];

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
        ..color = dotColor.withValues(alpha: 0.25)
        ..strokeWidth = _dot
        ..strokeCap = StrokeCap.square,
    );
  }

  @override
  bool shouldRepaint(_DitherPainter oldDelegate) =>
      oldDelegate.level != level || oldDelegate.dotColor != dotColor;
}
