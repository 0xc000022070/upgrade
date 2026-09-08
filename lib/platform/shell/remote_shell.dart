import 'dart:typed_data';

String shellQuote(String value) => "'${value.replaceAll("'", "'\\''")}'";

String underSh(String script) => 'sh -c ${shellQuote(script)}';

/// `cd` to [directory], with a leading `~` left outside the quotes.
///
/// A registered directory is stored as the user typed it, `~` and all, because
/// expanding it on the phone would put this machine's home directory in a
/// command the host runs. So the expansion belongs to the host — and quoting
/// the path, which is what makes a space or a `$` in it safe, is the one thing
/// that stops the shell from doing it. The tilde and its slash are the only
/// characters held out of the quotes; everything after them is still quoted,
/// and a path that does not start with one is quoted whole.
String shellCd(String directory) {
  if (directory == '~') return 'cd ~';
  if (directory.startsWith('~/')) {
    return 'cd ~/${shellQuote(directory.substring(2))}';
  }
  return 'cd ${shellQuote(directory)}';
}

/// The command a tab runs to come up in [directory] rather than in `$HOME`:
/// the `cd`, then a login shell in its place, which is what `ssh -t host 'cd
/// dir && exec $SHELL -l'` asks for.
///
/// The shell is exec'd rather than typed at. A line written at a login shell
/// races everything that shell reads before its prompt, and a host whose rc
/// asks which session to open takes the line's first character as its answer.
/// `$SHELL` is left for the host to expand, because whose shell it is belongs
/// to the host; and a `cd` that fails ends the tab where it stands rather than
/// opening a shell somewhere nobody asked for.
String shellIn(String directory) => '${shellCd(directory)} && exec \$SHELL -l';

/// Where a file the app pushes lands on a host. World-writable and cleared by
/// the host's own reboot, which is the right lifetime for a file nothing ever
/// comes back for. Shared by the shell's paste and by a send's images, so the
/// directory and the command that fills it are written once.
const remoteUploadDirectory = '/tmp/spectacle';

String remotePathFor(String fileName) => '$remoteUploadDirectory/$fileName';

/// The command a file's bytes are written into: the directory made if it is
/// not, the file taken whole from stdin.
String uploadCommand(String fileName) => underSh(
  'mkdir -p ${shellQuote(remoteUploadDirectory)} && '
  'cat > ${shellQuote(remotePathFor(fileName))}',
);

/// A file on its way to a host: the name it lands under and the bytes that go
/// on the exec channel's stdin.
class RemoteFile {
  const RemoteFile(this.name, this.bytes);

  /// The base name of a local path, held to the characters a name may carry.
  /// The path is the app's own and its names are uuids, but a name is about to
  /// be interpolated into a remote path, and one that could climb out of
  /// [remoteUploadDirectory] must not be able to.
  factory RemoteFile.fromPath(String path, Uint8List bytes) {
    final base = path.split('/').last;
    final safe = base.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return RemoteFile(
      safe.isEmpty || safe.startsWith('.') ? 'file$safe' : safe,
      bytes,
    );
  }

  final String name;
  final Uint8List bytes;

  String get remotePath => remotePathFor(name);
}

/// Where a host's `pinentry-gate` looks for terminals that want to be asked,
/// and where it puts the fifo an answer goes into. The pinentry's own runtime
/// directory; the shell expands it on the host, never the phone.
const pinentryGateDirectory =
    r'${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/pinentry-gate';

/// Marks this connection's shell as a place to ask. Run on an exec channel of
/// the same connection: the channel's parent is the sshd session that also
/// holds the shell, so `$PPID` names it, and the pty under that session is
/// the shell's. The mark is the pid, which is what lets the pinentry tell a
/// live mark from one whose session ended.
final pinentryMarkCommand = underSh(
  'd="$pinentryGateDirectory" && mkdir -p "\$d/tty" && chmod 700 "\$d" && '
  't=\$(ps -eo ppid=,tty= | awk -v p="\$PPID" '
  "'\$1 == p && \$2 ~ /^pts\\// { print \$2; exit }') && "
  '[ -n "\$t" ] && printf %s "\$PPID" > "\$d/tty/pts-\${t#pts/}"',
);

/// What a request's id looks like; anything else is not one and is never put
/// in a command.
final pinentryRequestId = RegExp(r'^[a-f0-9]{16,32}$');

/// Answers a request: the passphrase and its newline on stdin, a bare newline
/// for a cancel. The fifo is written as it is and never created — once the
/// pinentry has taken it down the request is settled, and a passphrase must
/// not end up in a regular file in its place.
String pinentryAnswerCommand(String id) {
  assert(pinentryRequestId.hasMatch(id));
  return underSh(
    'f="$pinentryGateDirectory/$id" && [ -p "\$f" ] && cat > "\$f"',
  );
}
