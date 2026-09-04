import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image_picker/image_picker.dart';

import '../../application/clips.dart';

/// The longest side a photo goes to a host at. A phone's camera is four
/// thousand pixels across and a PNG of that is most of a byte budget on its
/// own; the agents on the other end shrink anything past about half this
/// before they look at it.
const photoAttachEdge = 2048.0;

/// Gallery only, no camera, as many as the user picks, in the order picked.
/// The picker's own resize is used on the way in; what comes back is then
/// made a PNG here, because that is the one type the clipboard readers on
/// the host ask for. Nothing is held: a photo is attached and forgotten.
Future<List<Uint8List>> pickPhotos() async {
  final picked = await ImagePicker().pickMultiImage(
    maxWidth: photoAttachEdge,
    maxHeight: photoAttachEdge,
  );
  final photos = <Uint8List>[];
  for (final file in picked) {
    final bytes = await file.readAsBytes();
    photos.add(pngSize(bytes) != null ? bytes : await transcodeToPng(bytes));
  }
  return photos;
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
