import 'dart:typed_data';
import 'dart:ui';

typedef ReviewedPhoto = ({String path, Rect? keep});

typedef PhotoReview = Future<List<ReviewedPhoto>?> Function(List<String> paths);

/// [keep] is in fractions: the review sees the decoded, EXIF-rotated size, which the raw
/// header does not report. Null when [keep] rounds to the whole image.
Future<Uint8List?> cutImage(Uint8List bytes, Rect keep) async {
  final codec = await instantiateImageCodec(bytes);
  final image = (await codec.getNextFrame()).image;
  codec.dispose();
  try {
    final width = image.width.toDouble();
    final height = image.height.toDouble();
    final whole = Offset.zero & Size(width, height);
    final cut = Rect.fromLTRB(
      (keep.left * width).roundToDouble(),
      (keep.top * height).roundToDouble(),
      (keep.right * width).roundToDouble(),
      (keep.bottom * height).roundToDouble(),
    ).intersect(whole);
    if (cut == whole || cut.width < 1 || cut.height < 1) return null;
    final recorder = PictureRecorder();
    Canvas(recorder).drawImageRect(image, cut, Offset.zero & cut.size, Paint());
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
