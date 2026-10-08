import 'dart:typed_data';

import '../../application/clips.dart';
import '../../platform/shell/host_clipboard.dart';
import '../../platform/shell/shell_connection.dart';
import 'shell_sessions.dart';

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

Duration _uploadDeadline(int bytes) =>
    remoteCommandDeadline + Duration(milliseconds: bytes ~/ 64);

Future<PasteResult> pasteClip({
  required ShellSessions store,
  required ShellSession session,
  required Clip clip,
  required UserIntent intent,
}) async => pasteImage(
  store: store,
  session: session,
  fileName: clip.fileName,
  bytes: await clip.file.readAsBytes(),
  intent: intent,
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
  required UserIntent intent,
}) async {
  final connection = session.connection;
  if (connection == null || !session.state.holdsSession) {
    return const PasteResult(PasteOutcome.failed, detail: 'no shell');
  }
  final HostChannels? channels;
  try {
    channels = await connection.channelsFor(UserAction(intent));
  } catch (error) {
    return PasteResult(PasteOutcome.failed, detail: '$error');
  }
  if (channels == null) {
    return const PasteResult(PasteOutcome.failed, detail: 'no host');
  }
  final clipboard = await store.clipboardFor(session);
  final remote = remotePathFor(fileName);
  final ExecResult? landed;
  try {
    landed = await channels.exec(
      uploadCommand(fileName),
      stdin: bytes,
      timeout: _uploadDeadline(bytes.length),
    );
  } catch (error) {
    return PasteResult(PasteOutcome.failed, detail: '$error');
  }
  if (landed == null) {
    return const PasteResult(PasteOutcome.failed, detail: 'no host');
  }
  if (!landed.ok) {
    final said = landed.err.trim();
    return PasteResult(
      PasteOutcome.failed,
      detail: said.isEmpty ? 'upload exit ${landed.exitCode}' : said,
    );
  }
  final command = clipboardCommand(clipboard, fileName);
  String? reason = clipboard.reason;
  if (command != null) {
    try {
      final set = await channels.exec(command, timeout: remoteCommandDeadline);
      if (set != null && set.ok) {
        store.send(session, pasteKey);
        return const PasteResult(PasteOutcome.pasted);
      }
      reason = set == null
          ? 'no host'
          : '${clipboard.label.toLowerCase()} exit ${set.exitCode}';
    } catch (error) {
      reason = '$error';
    }
  }
  session.terminal.paste('$remote ');
  return PasteResult(PasteOutcome.path, detail: reason);
}
