import 'package:image_picker/image_picker.dart';

/// A phone camera is four thousand pixels across; the agents downscale past about half
/// this before they look at it.
const photoAttachEdge = 2048.0;

Future<List<String>> pickPhotoPaths() async {
  final picked = await ImagePicker().pickMultiImage(
    maxWidth: photoAttachEdge,
    maxHeight: photoAttachEdge,
  );
  return [for (final file in picked) file.path];
}
