import 'dart:io';

import 'package:upgrade/application/files/host_file_link.dart';
import 'package:upgrade/features/files/transfer_queue.dart';

String joinPath(String directory, String name) =>
    directory == '/' ? '/$name' : '$directory/$name';

Future<String?> pullFile(
  HostFiles from,
  String path,
  File into,
  int size,
  void Function(AttachItem item) report, {
  int sharing = 1,
  TransferStop? stop,
}) async {
  var item = AttachItem(bytes: size, down: true).to(AttachStage.sending);
  report(item);
  final write = await from.get(
    path,
    into,
    size: size,
    sharing: sharing,
    stop: stop,
    onProgress: (sent) =>
        report(item = item.to(AttachStage.sending, sent: sent)),
  );
  if (write.failure != null) return write.failure;
  report(item.to(AttachStage.landed, sent: size));
  return null;
}

Future<String?> pushFile(
  HostFiles to,
  String path,
  File file,
  void Function(AttachItem item) report, {
  int sharing = 1,
  AttachStage done = AttachStage.landed,
  TransferStop? stop,
}) async {
  final size = await file.length();
  var item = AttachItem(bytes: size).to(AttachStage.sending);
  report(item);
  final write = await to.put(
    path,
    FileBody.file(file, size, stop: stop),
    sharing: sharing,
    onProgress: (sent) =>
        report(item = item.to(AttachStage.sending, sent: sent)),
  );
  if (write.failure != null) return write.failure;
  report(item.to(done, sent: size));
  return null;
}

const unreadFolder = 'could not read the folder';
const copyGone = 'the phone copy is gone';
