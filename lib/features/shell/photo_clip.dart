import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image_picker/image_picker.dart';

import '../../application/clips.dart';

/// The longest side a photo is let into the tray at. A phone's camera is
/// four thousand pixels across and a PNG of that is most of the byte budget
/// on its own; the agents on the other end shrink anything past about half
/// this before they look at it.
const photoClipEdge = 2048.0;

/// Gallery only, no camera. The picker's own resize is used on the way in;
/// what comes back is then made a PNG here, because that is the one type the
/// clipboard readers on the host ask for.
Future<Clip?> pickPhotoClip(ClipStore clips) async {
  final picked = await ImagePicker().pickImage(
    source: ImageSource.gallery,
    maxWidth: photoClipEdge,
    maxHeight: photoClipEdge,
  );
  if (picked == null) return null;
  final bytes = await picked.readAsBytes();
  final png = pngSize(bytes) != null ? bytes : await transcodeToPng(bytes);
  return clips.add(png, source: ClipSource.photo);
}

/// Through the engine's own codecs: the picker hands back a JPEG on Android
/// whenever it resized, and nothing else in the app decodes one.
Future<Uint8List> transcodeToPng(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  try {
    final frame = await codec.getNextFrame();
    try {
      final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw StateError('png encode failed');
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } finally {
      frame.image.dispose();
    }
  } finally {
    codec.dispose();
  }
}
