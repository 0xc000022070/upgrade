import 'dart:typed_data';

import '../../application/clips.dart';
import '../../platform/shell/host_clipboard.dart';
import '../../platform/shell/shell_connection.dart';
import 'shell_sessions.dart';

/// What a paste came to. Two of the three are fine: a host with no clipboard
/// gets the path, which is what a headless box is meant to get.
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

/// Ctrl+V, the one byte a terminal sends for it. The agent under the pty
/// reads the host's clipboard itself on seeing it — the image never crosses
/// the pty, and the byte goes only once the clipboard is known to hold it,
/// because to a shell it is `lnext` and not a paste at all.
final pasteKey = Uint8List.fromList(const [0x16]);

/// Lands a held clip on the host and pastes it into the session.
Future<PasteResult> pasteClip({
  required ShellSessions store,
  required ShellSession session,
  required Clip clip,
}) async => pasteImage(
  store: store,
  session: session,
  fileName: clip.fileName,
  bytes: await clip.file.readAsBytes(),
);

/// Lands one PNG on the host under [fileName] and pastes it into the session.
///
/// The probe goes first, because the route it settles is the route the
/// upload takes. The bytes go every time rather than being remembered per
/// host: `/tmp` is cleared by a reboot the app never hears about, and a path
/// the agent is then told to read would be a lie. The clipboard command runs
/// when the host has one; a host that does not, or one whose tool failed,
/// gets the path typed where the cursor is.
Future<PasteResult> pasteImage({
  required ShellSessions store,
  required ShellSession session,
  required String fileName,
  required Uint8List bytes,
}) async {
  final connection = session.connection;
  if (connection == null || session.state is! ShellLive) {
    return const PasteResult(PasteOutcome.failed, detail: 'no shell');
  }
  final clipboard = await store.clipboardFor(session);
  final remote = remotePathFor(fileName);
  final ExecResult landed;
  try {
    landed = await connection.exec(
      uploadCommand(clipboard.route, fileName),
      stdin: bytes,
    );
  } catch (error) {
    return PasteResult(PasteOutcome.failed, detail: '$error');
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
      final set = await connection.exec(command);
      if (set.ok) {
        store.send(session, pasteKey);
        return const PasteResult(PasteOutcome.pasted);
      }
      reason = '${clipboard.label.toLowerCase()} exit ${set.exitCode}';
    } catch (error) {
      reason = '$error';
    }
  }
  session.terminal.paste('$remote ');
  return PasteResult(PasteOutcome.path, detail: reason);
}
