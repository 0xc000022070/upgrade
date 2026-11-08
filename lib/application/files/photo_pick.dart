import 'package:upgrade/application/files/photo_cut.dart';
import 'package:upgrade/platform/files/photo_picker.dart';

Future<List<ReviewedPhoto>> pickReviewed(PhotoReview review) async {
  final paths = await pickPhotoPaths();
  if (paths.isEmpty) return const [];
  return await review(paths) ?? const [];
}
