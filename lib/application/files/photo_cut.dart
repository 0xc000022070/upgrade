import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:upgrade/design/colors.dart';

enum MarkShape { box, ring, arrow }

typedef PhotoMark = ({MarkShape shape, Offset from, Offset to});

typedef ReviewedPhoto = ({String path, Rect? keep, List<PhotoMark> marks});

typedef PhotoReview = Future<List<ReviewedPhoto>?> Function(List<String> paths);

bool untouched(ReviewedPhoto photo) =>
    photo.keep == null && photo.marks.isEmpty;

void paintMarks(
  Canvas canvas,
  Size whole,
  List<PhotoMark> marks, {
  Color? color,
}) {
  if (marks.isEmpty) return;
  final weight = math.max(1.0, whole.shortestSide * 0.01);
  final paint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = weight
    ..strokeJoin = StrokeJoin.miter
    ..color = color ?? UpgradeColors.markInk;
  for (final mark in marks) {
    final from = Offset(
      mark.from.dx * whole.width,
      mark.from.dy * whole.height,
    );
    final to = Offset(mark.to.dx * whole.width, mark.to.dy * whole.height);
    switch (mark.shape) {
      case MarkShape.box:
        canvas.drawRect(Rect.fromPoints(from, to), paint);
      case MarkShape.ring:
        canvas.drawOval(Rect.fromPoints(from, to), paint);
      case MarkShape.arrow:
        final line = to - from;
        final length = line.distance;
        if (length == 0) continue;
        final back = line / -length * math.min(weight * 4, length / 2);
        Offset barb(double angle) =>
            to +
            Offset(
              back.dx * math.cos(angle) - back.dy * math.sin(angle),
              back.dx * math.sin(angle) + back.dy * math.cos(angle),
            );
        final left = barb(0.5);
        final right = barb(-0.5);
        canvas
          ..drawLine(from, to, paint)
          ..drawPath(
            Path()
              ..moveTo(left.dx, left.dy)
              ..lineTo(to.dx, to.dy)
              ..lineTo(right.dx, right.dy),
            paint,
          );
    }
  }
}

/// [keep] is in fractions: the review sees the decoded, EXIF-rotated size, which the raw
/// header does not report. Null when the result would be the photo as it came.
Future<Uint8List?> cutImage(
  Uint8List bytes,
  Rect? keep,
  List<PhotoMark> marks,
) async {
  final codec = await instantiateImageCodec(bytes);
  final image = (await codec.getNextFrame()).image;
  codec.dispose();
  try {
    final width = image.width.toDouble();
    final height = image.height.toDouble();
    final whole = Offset.zero & Size(width, height);
    final cut = keep == null
        ? whole
        : Rect.fromLTRB(
            (keep.left * width).roundToDouble(),
            (keep.top * height).roundToDouble(),
            (keep.right * width).roundToDouble(),
            (keep.bottom * height).roundToDouble(),
          ).intersect(whole);
    if (cut.width < 1 || cut.height < 1) return null;
    if (cut == whole && marks.isEmpty) return null;
    final recorder = PictureRecorder();
    final canvas = Canvas(recorder)
      ..drawImageRect(image, cut, Offset.zero & cut.size, Paint())
      ..translate(-cut.left, -cut.top);
    paintMarks(canvas, whole.size, marks);
    final picture = recorder.endRecording();
    final out = await picture.toImage(cut.width.toInt(), cut.height.toInt());
    picture.dispose();
    try {
      final png = await out.toByteData(format: ImageByteFormat.png);
      return png?.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
    } finally {
      out.dispose();
    }
  } finally {
    image.dispose();
  }
}
