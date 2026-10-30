import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/features/photos/photo_cut.dart';
import 'package:upgrade/features/photos/photo_pick.dart';
import 'package:upgrade/features/tasks/image_input.dart';
import 'package:upgrade/platform/plugins/access.dart';
import 'package:upgrade/application/providers.dart';

final attachmentFilesProvider = Provider<AttachmentFiles>((ref) {
  final owner = ref.watch(attachmentDataGateProvider);
  return AttachmentFiles(owner.lease('attachments'));
}, dependencies: [attachmentDataGateProvider]);

class AttachmentFiles {
  AttachmentFiles(this._lease);
  final PluginLease _lease;
  String? absolute(String relative) =>
      _lease.read(() => ImageAttachments.absolute(relative));
  Future<List<String>> pick(PhotoReview review) async {
    final kept = await pickReviewed(review);
    if (kept.isEmpty) return const [];
    return _lease.call(() => ImageAttachments.store(kept));
  }

  Future<void> remove(String relative) =>
      _lease.call(() => ImageAttachments.remove(relative));
}
