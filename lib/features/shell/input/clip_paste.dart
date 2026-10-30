import 'dart:async';
import 'dart:typed_data';

import 'package:upgrade/application/drops/clips.dart';
import 'package:upgrade/platform/shell/host_clipboard.dart';
import 'package:upgrade/platform/shell/shell_connection.dart';
import 'package:upgrade/platform/ssh/host_files.dart'
    show FileBody, atMost, uploadWidth, uploadsSharing;
import 'package:upgrade/features/shell/session/shell_sessions.dart';

/// Two of the three are fine: a host with no clipboard gets the path, which is what a
/// headless box is meant to get.
enum PasteOutcome { pasted, path, failed }

class PasteResult {
  const PasteResult(this.outcome, {this.detail});

  final PasteOutcome outcome;
  final String? detail;

  String get label => switch (outcome) {
    PasteOutcome.pasted => 'PASTED',
    PasteOutcome.path => 'PATH',
    PasteOutcome.failed => 'FAILED',
  };

  String get line => detail == null ? label : '$label · $detail';
}

/// Ctrl+V, the one byte a terminal sends for it. The agent under the pty reads the host's
/// clipboard itself on seeing it — the image never crosses the pty, and the byte goes
/// only once the clipboard is known to hold it, because to a shell it is `lnext` and not
/// a paste at all.
final pasteKey = Uint8List.fromList(const [0x16]);

Duration _uploadDeadline(int bytes, int sharing) =>
    remoteCommandDeadline + Duration(milliseconds: bytes * sharing ~/ 64);

Future<PasteResult> pasteClip({
  required ShellSessions store,
  required ShellSession session,
  required Clip clip,
  required UserAction action,
}) async => pasteImage(
  store: store,
  session: session,
  fileName: clip.fileName,
  bytes: await clip.file.readAsBytes(),
  action: action,
);

/// The probe goes first so the clipboard backend is known before upload. The bytes go
/// every time rather than being remembered per host: `/tmp` is cleared by a reboot the
/// app never hears about, and a path the agent is then told to read would be a lie. A
/// host with no clipboard command, or one whose tool failed, gets the path typed where
/// the cursor is. The paste is the user's, so a host the tab does not hold is opened for
/// it.
Future<PasteResult> pasteImage({
  required ShellSessions store,
  required ShellSession session,
  required String fileName,
  required Uint8List bytes,
  required UserAction action,
}) => pasteImages(
  store: store,
  session: session,
  images: [(fileName: fileName, bytes: bytes)],
  action: action,
);

typedef PasteImage = ({String fileName, Uint8List bytes});

typedef PasteFile = ({String fileName, FileBody body, bool image});

enum AttachStage {
  queued,
  sending,
  landed,
  pasting,
  pasted,
  copied,
  path,
  failed,
  stopped,
}

final class AttachItem {
  const AttachItem({
    required this.bytes,
    this.stage = AttachStage.queued,
    this.sent = 0,
    this.detail,
    this.down = false,
  });

  final int bytes;
  final AttachStage stage;

  final int sent;
  final String? detail;

  final bool down;

  double get fraction => bytes == 0 ? 1 : sent / bytes;

  bool get settled => !const {
    AttachStage.queued,
    AttachStage.sending,
    AttachStage.landed,
    AttachStage.pasting,
  }.contains(stage);

  AttachItem to(AttachStage stage, {int? sent, String? detail, bool? down}) =>
      AttachItem(
        bytes: bytes,
        stage: stage,
        sent: sent ?? this.sent,
        detail: detail ?? this.detail,
        down: down ?? this.down,
      );
}

Future<PasteResult> pasteImages({
  required ShellSessions store,
  required ShellSession session,
  required List<PasteImage> images,
  required UserAction action,
  Future<bool> Function(int pasted)? before,
  void Function(int index, AttachItem item)? onItem,
}) => pasteFiles(
  store: store,
  session: session,
  files: [
    for (final image in images)
      (
        fileName: image.fileName,
        body: FileBody.bytes(image.bytes),
        image: true,
      ),
  ],
  action: action,
  before: before,
  onItem: onItem,
);

Future<PasteResult> pasteFiles({
  required ShellSessions store,
  required ShellSession session,
  required List<PasteFile> files,
  required UserAction action,
  Future<bool> Function(int pasted)? before,
  void Function(int index, AttachItem item)? onItem,
}) async {
  assert(files.isNotEmpty);
  final items = [for (final file in files) AttachItem(bytes: file.body.length)];
  var stopped = false;
  void report(int index, AttachItem item) {
    if (stopped) return;
    items[index] = item;
    onItem?.call(index, item);
  }

  try {
    return await _run(
      store,
      session,
      files,
      action,
      items,
      report,
      before,
      () => stopped,
    );
  } finally {
    for (var i = 0; i < items.length; i++) {
      if (const {
        AttachStage.queued,
        AttachStage.sending,
        AttachStage.landed,
      }.contains(items[i].stage)) {
        report(i, items[i].to(AttachStage.stopped));
      }
    }
    stopped = true;
  }
}

Future<PasteResult> _run(
  ShellSessions store,
  ShellSession session,
  List<PasteFile> images,
  UserAction action,
  List<AttachItem> items,
  void Function(int index, AttachItem item) report,
  Future<bool> Function(int pasted)? before,
  bool Function() stopped,
) async {
  final connection = session.connection;
  if (connection == null || !session.state.holdsSession) {
    return const PasteResult(PasteOutcome.failed, detail: 'no shell');
  }
  final HostChannels? channels;
  try {
    channels = await connection.channelsFor(action);
  } catch (error) {
    return PasteResult(PasteOutcome.failed, detail: '$error');
  }
  if (channels == null) {
    return const PasteResult(PasteOutcome.failed, detail: 'no host');
  }
  final clipboard = await store.clipboardFor(session);
  final landings = StreamController<(int, PasteResult?)>();
  atMost(
    uploadWidth,
    [
      for (var i = 0; i < images.length; i++)
        () async {
          if (stopped()) return;
          report(i, items[i].to(AttachStage.sending));
          final failed = await _upload(
            channels!,
            images[i],
            (sent) => report(i, items[i].to(AttachStage.sending, sent: sent)),
            uploadsSharing(images.length),
          );
          report(
            i,
            failed == null
                ? items[i].to(AttachStage.landed, sent: items[i].bytes)
                : items[i].to(AttachStage.failed, detail: failed.detail),
          );
          landings.add((i, failed));
        },
    ],
    sizes: [for (final item in items) item.bytes],
  );
  final landed = StreamIterator(landings.stream);
  PasteResult? last;
  try {
    for (var pasted = 0; pasted < images.length; pasted++) {
      await landed.moveNext();
      final (index, failed) = landed.current;
      if (failed != null) return failed;
      if (before != null && !await before(pasted)) break;
      report(index, items[index].to(AttachStage.pasting));
      last = images[index].image
          ? await _paste(
              store,
              session,
              channels,
              clipboard,
              images[index].fileName,
            )
          : _typePath(session, images[index].fileName);
      report(
        index,
        items[index].to(
          last.outcome == PasteOutcome.pasted
              ? AttachStage.pasted
              : AttachStage.path,
          detail: last.detail,
        ),
      );
    }
  } finally {
    unawaited(landed.cancel());
  }
  return last ?? const PasteResult(PasteOutcome.failed, detail: 'stopped');
}

Future<PasteResult?> _upload(
  HostChannels channels,
  PasteFile image,
  PutProgress onProgress,
  int sharing,
) async {
  final FileWrite? landed;
  try {
    landed = await channels.put(
      remotePathFor(image.fileName),
      image.body,
      timeout: _uploadDeadline(image.body.length, sharing),
      onProgress: onProgress,
    );
  } catch (error) {
    return PasteResult(PasteOutcome.failed, detail: '$error');
  }
  if (landed == null) {
    return const PasteResult(PasteOutcome.failed, detail: 'no host');
  }
  final failure = landed.failure;
  return failure == null
      ? null
      : PasteResult(PasteOutcome.failed, detail: failure);
}

PasteResult _typePath(ShellSession session, String fileName) {
  session.terminal.paste('${shellQuote(remotePathFor(fileName))} ');
  return const PasteResult(PasteOutcome.path);
}

Future<PasteResult> _paste(
  ShellSessions store,
  ShellSession session,
  HostChannels channels,
  HostClipboard clipboard,
  String fileName,
) async {
  final command = clipboardCommand(clipboard, fileName);
  String? reason = clipboard.reason;
  if (command != null) {
    try {
      final set = await channels.exec(command, timeout: remoteCommandDeadline);
      final tool = clipboard.label.toLowerCase();
      if (set == null) {
        reason = 'no host';
      } else if (!set.ok) {
        reason = '$tool exit ${set.exitCode}';
      } else if (!set.out.contains(clipboardSetMarker)) {
        reason = '$tool failed';
      } else {
        store.send(session, pasteKey);
        return const PasteResult(PasteOutcome.pasted);
      }
    } catch (error) {
      reason = '$error';
    }
  }
  session.terminal.paste('${remotePathFor(fileName)} ');
  return PasteResult(PasteOutcome.path, detail: reason);
}
