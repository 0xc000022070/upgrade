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

/// The variable every tab's shell carries, so a host can be asked which of its
/// processes is that tab. Exported before the `exec`, which is what carries it
/// into the login shell that replaces it.
const shellMarkVariable = 'DAZZLE_TAB';

/// What a mark may be, which is the one thing here that reaches a command the
/// host runs: letters and digits, and nothing a shell or a `grep` reads as
/// anything but itself.
final shellMark = RegExp(r'^[a-z0-9]{6,32}$');

/// What a tab actually runs: its mark, then whatever the tab was opened for —
/// a directory to come up in, a pane to attach to, or the login shell itself.
String shellMarked(String mark, {String? command}) {
  assert(shellMark.hasMatch(mark));
  return 'export $shellMarkVariable=$mark; ${command ?? 'exec \$SHELL -l'}';
}

const durableShellSocket = 'dazzle';

final durableShellSession = shellMark;

const moshTabVariable = 'DAZZLE_MOSH_TAB';

String durableShellProbeCommand(String session) {
  assert(durableShellSession.hasMatch(session));
  final target = shellQuote(session);
  final script =
      'p=\$(command -v tmux) || exit 127; '
      'printf "DAZZLE_TMUX=%s\\n" "\$p"; '
      'if "\$p" -L $durableShellSocket has-session -t $target 2>/dev/null; '
      'then printf "DAZZLE_RESUME=1\\n"; '
      'else printf "DAZZLE_RESUME=0\\n"; fi';
  return 'exec "\$SHELL" -lc ${shellQuote(script)}';
}

String durableShellCommand(String tmux, String session, String command) {
  assert(tmux.startsWith('/'));
  assert(durableShellSession.hasMatch(session));
  return 'exec ${shellQuote(tmux)} -L $durableShellSocket '
      'new-session -A -s ${shellQuote(session)} ${shellQuote(command)}';
}

String durableShellTerminateCommand(String tmux, String session) {
  assert(tmux.startsWith('/'));
  assert(durableShellSession.hasMatch(session));
  final client = '${shellQuote(tmux)} -L $durableShellSocket';
  return underSh(
    'if $client has-session -t ${shellQuote(session)} 2>/dev/null; '
    'then $client kill-session -t ${shellQuote(session)}; fi',
  );
}

String durableShellDirectoryCommand(String tmux, String session) {
  assert(tmux.startsWith('/'));
  assert(durableShellSession.hasMatch(session));
  return '${shellQuote(tmux)} -L $durableShellSocket display-message -p '
      '-t ${shellQuote('$session:')} ${shellQuote('#{pane_current_path}')}';
}

String moshServerProbeCommand() {
  const script =
      'p=\$(command -v mosh-server) || exit 127; '
      'printf "DAZZLE_MOSH=%s\\n" "\$p"';
  return 'exec "\$SHELL" -lc ${shellQuote(script)}';
}

String moshServerCleanupCommand(String session) {
  assert(durableShellSession.hasMatch(session));
  const marked =
      'tr "\\000" "\\n" < "\$p/environ" | grep -qx "'
      '$moshTabVariable=';
  return underSh(
    'exec 2>/dev/null; ok=1; '
    'for p in /proc/[0-9]*; do '
    '$marked$session" 2>/dev/null || continue; '
    'a=\$(tr "\\000" " " < "\$p/cmdline" 2>/dev/null); '
    'case "\${a%% *}" in mosh-server|*/mosh-server) '
    'kill "\${p##*/}" 2>/dev/null || ok=0;; esac; '
    'done; [ "\$ok" -eq 1 ]',
  );
}

/// Where the shell marked [mark] is standing, read off the host's own process
/// table rather than waited for from the shell.
///
/// The topmost marked process is the tab's shell: everything it starts
/// inherits the mark, and a child's directory is not the shell's. `/proc` and
/// nothing else — a host that keeps its processes elsewhere answers nothing,
/// which is what puts the tab back on what it was told.
///
/// `environ` is read a line at a time rather than with `grep -z`, which is
/// GNU's and not every host's; stderr is closed at the top because a process
/// list walked by a user is mostly other people's.
String shellCwdProbe(String mark) {
  assert(shellMark.hasMatch(mark));
  const marked =
      'tr "\\000" "\\n" < "\$1/environ" | grep -qx "$shellMarkVariable=';
  return underSh(
    'exec 2>/dev/null; '
    'm() { $marked\$2"; }; '
    'c=; s=; '
    'for p in /proc/[0-9]*; do '
    'm "\$p" $mark || continue; '
    // The multiplexer is looked for on every marked process and the shell only
    // on the topmost, so a client started deep in the tab is still found.
    'a=\$(tr "\\000" " " < "\$p/cmdline"); '
    'case "\${a%% *}" in herdr|*/herdr) '
    's=\$(tr "\\000" "\\n" < "\$p/environ" | sed -n "s/^HERDR_SESSION=//p"); '
    '[ -n "\$s" ] || case " \$a" in *" --session "*) '
    's=\${a#* --session }; s=\${s%% *};; esac; '
    '[ -n "\$s" ] || s=default;; esac; '
    '[ -n "\$c" ] && continue; '
    'q=\$(sed -n "s/^PPid:[[:space:]]*//p" "\$p/status"); '
    'm "/proc/\$q" $mark && continue; '
    'c=\$(readlink "\$p/cwd"); '
    'done; '
    'printf "%s\\n%s\\n" "\$c" "\$s"; '
    '[ -n "\$c" ] || [ -n "\$s" ]',
  );
}

/// Where a tab is standing, out of what [shellCwdProbe] answers: the directory
/// of the tab's own shell, and the multiplexer session a client running in the
/// tab is on. Both can be missing, and the session being there is what makes
/// the directory a fallback rather than the answer.
typedef ShellPlace = ({String? cwd, String? herdrSession});

ShellPlace parseShellPlace(String source) {
  final lines = source.split('\n');
  String? line(int index) {
    if (index >= lines.length) return null;
    final value = lines[index].trim();
    return value.isEmpty ? null : value;
  }

  final cwd = line(0);
  return (
    cwd: cwd != null && cwd.startsWith('/') ? cwd : null,
    herdrSession: line(1),
  );
}

/// Where a file the app pushes lands on a host. World-writable and cleared by
/// the host's own reboot, which is the right lifetime for a file nothing ever
/// comes back for. Shared by the shell's paste and by a send's images, so the
/// directory and the command that fills it are written once.
const remoteUploadDirectory = '/tmp/dazzle';

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
