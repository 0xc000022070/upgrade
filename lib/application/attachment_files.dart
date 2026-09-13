import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/tasks/image_input.dart';
import '../platform/plugins/access.dart';
import 'providers.dart';

final attachmentFilesProvider = Provider<AttachmentFiles>((ref) {
  final owner = ref.watch(attachmentDataGateProvider);
  return AttachmentFiles(owner.lease('attachments'));
}, dependencies: [attachmentDataGateProvider]);

class AttachmentFiles {
  AttachmentFiles(this._lease);
  final PluginLease _lease;
  String? absolute(String relative) =>
      _lease.read(() => ImageAttachments.absolute(relative));
  Future<String?> pick() => _lease.call(ImageAttachments.pick);
  Future<void> remove(String relative) =>
      _lease.call(() => ImageAttachments.remove(relative));
}
