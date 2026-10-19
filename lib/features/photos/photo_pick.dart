import 'package:image_picker/image_picker.dart';

import 'package:striked/features/photos/photo_cut.dart';

/// A phone camera is four thousand pixels across; the agents downscale past about half
/// this before they look at it.
const photoAttachEdge = 2048.0;

Future<List<ReviewedPhoto>> pickReviewed(PhotoReview review) async {
  final picked = await ImagePicker().pickMultiImage(
    maxWidth: photoAttachEdge,
    maxHeight: photoAttachEdge,
  );
  if (picked.isEmpty) return const [];
  return await review([for (final file in picked) file.path]) ?? const [];
}
