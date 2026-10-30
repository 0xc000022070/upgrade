import 'dart:io';

import 'package:uuid/uuid.dart';

import 'package:upgrade/application/files/host_file_link.dart';
import 'package:upgrade/application/files/phone_inbox.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/features/files/transfer_queue.dart';
import 'package:upgrade/features/files/transfers.dart';
import 'package:upgrade/platform/shell/remote_shell.dart' show remotePathFor;

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

typedef AfterUpload = Future<String?> Function(
  HostFiles link,
  Map<String, String> sent,
  Set<String>? taken,
);

typedef UploadEnded = void Function(
  TransferJob? job,
  Map<String, String> sent,
  String? failure,
);

Future<void> uploadFiles({
  required Transfers transfers,
  required HostFilesOpener open,
  required Host host,
  required List<SharedFile> files,
  String? into,
  Map<String, String> sent = const {},
  AfterUpload? then,
  void Function(TransferJob job)? began,
  UploadEnded? ended,
  TransferJob? replacing,
}) async {
  final job = files.isEmpty
      ? null
      : transfers.begin(
          verb: 'UPLOADING',
          host: host.name,
          hostId: host.id,
          files: [
            for (final file in files)
              QueuedFile(name: file.name, bytes: file.size),
          ],
          replacing: replacing,
        );
  if (job != null) began?.call(job);
  final landed = {...sent};
  HostFiles? link;
  String? failure;
  var missed = const <SharedFile>[];
  try {
    try {
      link = await open(host);
    } catch (error) {
      failure = filesFailureLine(error);
    }
    Set<String>? taken;
    if (link != null && into != null) {
      final listed = await link.list(into);
      if (listed == null) {
        failure = 'FOLDER · $unreadFolder';
      } else {
        taken = {for (final entry in listed) entry.name};
      }
    }
    final paths = <String>[];
    if (failure == null) {
      for (final file in files) {
        if (taken == null) {
          paths.add(remotePathFor('${const Uuid().v4()}/${file.name}'));
          continue;
        }
        final name = freeName(file.name, taken);
        taken.add(name);
        paths.add(joinPath(into!, name));
      }
    }
    final List<String?> failures;
    if (job == null) {
      failures = const [];
    } else if (failure case final line?) {
      for (var i = 0; i < files.length; i++) {
        job.report(i, job.items[i].to(AttachStage.failed, detail: line));
      }
      failures = List.filled(files.length, line);
    } else {
      final sharing = uploadsSharing(files.length);
      failures = await runQueue(
        job.files,
        (i, report, stop) async {
          final copy = File(files[i].path);
          if (!await copy.exists()) return copyGone;
          return pushFile(
            link!,
            paths[i],
            copy,
            report,
            sharing: sharing,
            stop: stop,
          );
        },
        stop: job.stop,
        onItem: job.report,
      );
    }
    for (var i = 0; i < failures.length; i++) {
      if (failures[i] == null) landed[files[i].path] = paths[i];
    }
    missed = [
      for (var i = 0; i < failures.length; i++)
        if (failures[i] != null && failures[i] != copyGone) files[i],
    ];
    if (job != null && missed.isNotEmpty) {
      job.kept.addAll([...landed.keys, for (final file in missed) file.path]);
      job.retry = () => uploadFiles(
        transfers: transfers,
        open: open,
        host: host,
        files: missed,
        into: into,
        sent: landed,
        then: then,
        began: began,
        ended: ended,
        replacing: job,
      );
    } else if (failure == null && then != null) {
      failure = await then(link!, landed, taken);
      if (job != null && failure != null) {
        job.note = [failure, if (into == null) ...landed.values].join('\n');
      }
    }
  } finally {
    link?.close();
    job?.end();
  }
  if (missed.isEmpty && (failure == null || ended == null)) {
    await discardCopies(landed.keys);
  }
  ended?.call(job, landed, failure);
}
