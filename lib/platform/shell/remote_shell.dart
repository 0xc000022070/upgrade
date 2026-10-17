import 'dart:typed_data';

String shellQuote(String value) => "'${value.replaceAll("'", "'\\''")}'";

String underSh(String script) => 'sh -c ${shellQuote(script)}';

const remoteCommandDeadline = Duration(seconds: 10);

/// A registered directory is stored as the user typed it, `~` and all, and quoting the
/// path is the one thing that stops the shell expanding it. The tilde and its slash are
/// the only characters held out of the quotes.
String shellCd(String directory) {
  if (directory == '~') return 'cd ~';
  if (directory.startsWith('~/')) {
    return 'cd ~/${shellQuote(directory.substring(2))}';
  }
  return 'cd ${shellQuote(directory)}';
}

/// The shell is exec'd rather than typed at: a line written at a login shell races
/// everything that shell reads before its prompt. `$SHELL` is left for the host to
/// expand, and a `cd` that fails ends the tab where it stands.
String shellIn(String directory) => '${shellCd(directory)} && exec \$SHELL -l';

/// Exported before the `exec`, which is what carries it into the login shell that
/// replaces it.
const shellMarkVariable = 'UPGRADE_TAB';

/// Letters and digits, and nothing a shell or a `grep` reads as anything but itself.
final shellMark = RegExp(r'^[a-z0-9]{6,32}$');

String shellMarked(String mark, {String? command}) {
  assert(shellMark.hasMatch(mark));
  return 'export $shellMarkVariable=$mark; '
      'if [ "\$(uname -s)" = Darwin ]; then '
      '(d="/tmp/upgrade-\$(id -u)"; umask 077; '
      'mkdir -p "\$d" && [ -O "\$d" ] && '
      'tty > "\$d/$mark") 2>/dev/null; fi; '
      '${command ?? 'exec \$SHELL -l'}';
}

const durableShellSocket = 'upgrade';

final durableShellSession = shellMark;

const moshTabVariable = 'UPGRADE_MOSH_TAB';

String durableShellProbeCommand(String session) {
  assert(durableShellSession.hasMatch(session));
  final target = shellQuote(session);
  final script =
      'p=\$(command -v tmux) || exit 127; '
      'printf "UPGRADE_TMUX=%s\\n" "\$p"; '
      'if "\$p" -L $durableShellSocket has-session -t $target 2>/dev/null; '
      'then printf "UPGRADE_RESUME=1\\n"; '
      'else printf "UPGRADE_RESUME=0\\n"; fi';
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
      'printf "UPGRADE_MOSH=%s\\n" "\$p"';
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
    'case "\${a%% *}" in mosh-server|*/mosh-server|strikedddd|*/strikedddd) '
    'kill "\${p##*/}" 2>/dev/null || ok=0;; esac; '
    'done; [ "\$ok" -eq 1 ]',
  );
}

/// The topmost marked process is the tab's shell: everything it starts inherits the mark,
/// and a child's directory is not the shell's. `environ` is read a line at a time rather
/// than with `grep -z`, which is GNU's and not every host's; stderr is closed at the top
/// because a process list walked by a user is mostly other people's.
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
    // The multiplexer is looked for on every marked process and the shell only on the
    // topmost, so a client started deep in the tab is still found.
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

String shellForegroundProcessProbe(String mark) {
  assert(shellMark.hasMatch(mark));
  final linux =
      r'exec 2>/dev/null; '
      r'for p in /proc/[0-9]*; do '
      r's=$(cat "$p/stat") || continue; '
      r's=${s##*) }; set -- $s; '
      r'parent=$2; group=$3; '
      r'[ "$group" = "$6" ] && [ "$group" -gt 0 ] || continue; '
      r's=$(cat "/proc/$parent/stat") || continue; '
      r's=${s##*) }; set -- $s; '
      r'[ "$3" = "$group" ] && continue; '
      r'tr "\000" "\n" < "$p/environ" | grep -qx "UPGRADE_TAB='
      '$mark'
      r'" || continue; '
      r'a=$(tr "\000" "\n" < "$p/cmdline" | sed -n "1p"); '
      r'b=$(tr "\000" "\n" < "$p/cmdline" | sed -n "2p"); '
      r'e=$(readlink "$p/exe") || continue; '
      r'printf "%s\t%s\t%s\n" "$a" "$e" "$b"; '
      r'done';
  final darwin =
      r'exec 2>/dev/null; '
      r'd="/tmp/upgrade-$(id -u)"; [ -O "$d" ] || exit 1; '
      't=\$(cat "\$d/$mark") || exit 1; '
      r'case "$t" in /dev/*) ;; *) exit 1;; esac; '
      r'ps -ww -t "$t" -o pid=,ppid=,pgid=,tpgid=,comm=,command= | '
      "awk 'NF >= 6 && \$3 == \$4 && \$3 > 0 { "
      'p[\$1]=\$2; c[\$1]=\$5; a[\$1]=\$6; b[\$1]=\$7 } '
      'END { for (i in p) if (!(p[i] in p)) { n++; root=i } '
      "if (n == 1) printf \"%s\\t%s\\t%s\\n\", a[root], c[root], b[root] }'";
  return underSh(
    'case "\$(uname -s)" in Darwin) $darwin ;; Linux) $linux ;; esac',
  );
}

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

/// World-writable and cleared by the host's own reboot, which is the right lifetime for
/// a file nothing ever comes back for.
const remoteUploadDirectory = '/tmp/upgrade';

String remotePathFor(String fileName) => '$remoteUploadDirectory/$fileName';

class RemoteFile {
  const RemoteFile(this.name, this.bytes);

  /// The path is the app's own and its names are uuids, but a name is about to be
  /// interpolated into a remote path, and one that could climb out of
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

/// The pinentry's own runtime directory; the shell expands it on the host, never the
/// phone.
const pinentryGateDirectory =
    r'${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/pinentry-gate';

/// What holds the pty is either this connection's own sshd session or the Mosh server
/// the tab was started under, found by the tab's mark: a Mosh shell hangs off a server
/// that let go of the ssh session that started it, so the channel's parent owns no pty
/// then. The mark is the holder's pid.
String pinentryMarkCommand(String tab) {
  assert(durableShellSession.hasMatch(tab));
  return underSh(
    'exec 2>/dev/null; '
    'd="$pinentryGateDirectory" && mkdir -p "\$d/tty" && chmod 700 "\$d" '
    '|| exit 1; '
    'h=\$PPID; '
    'for p in /proc/[0-9]*; do '
    'tr "\\000" "\\n" < "\$p/environ" | grep -qx "$moshTabVariable=$tab" '
    '|| continue; '
    'a=\$(tr "\\000" " " < "\$p/cmdline"); '
    'case "\${a%% *}" in mosh-server|*/mosh-server|strikedddd|*/strikedddd) h="\$h \${p##*/}";; esac; '
    'done; '
    'ps -eo ppid=,tty= | awk -v h="\$h" '
    "'BEGIN { n = split(h, k, \" \"); for (i = 1; i <= n; i++) w[k[i]] = 1 } "
    "(\$1 in w) && \$2 ~ /^pts\\// { print \$1, \$2 }' | "
    'while read -r q t; do printf %s "\$q" > "\$d/tty/pts-\${t#pts/}"; done',
  );
}

/// The OSC reaches a tab whole over ssh, but a Mosh shell's pty ends at a server that
/// ships a screen and not a byte stream, and an OSC it does not know never leaves the
/// host — the bell the pinentry rings after it does. So the bell is the signal and the
/// host is the source, on both transports. A host without the pinentry exits 0 saying
/// nothing.
String pinentryOpenCommand() => underSh(
  'exec 2>/dev/null; d="$pinentryGateDirectory"; '
  'for f in "\$d"/*.json; do '
  'i=\${f##*/}; i=\${i%.json}; [ -p "\$d/\$i" ] || continue; '
  'printf "%s %s\\n" "\$i" "\$(base64 < "\$f" | tr -d "\\n")"; '
  'done; exit 0',
);

/// What a request's id looks like; anything else is not one and is never put in a
/// command.
final pinentryRequestId = RegExp(r'^[a-f0-9]{16,32}$');

/// A shell opening the fifo itself waits forever on one whose reader is gone, so the
/// host's own pinentry takes the decision. A settled request exits non-zero.
String pinentryAnswerCommand(String id) {
  assert(pinentryRequestId.hasMatch(id));
  return underSh(
    'exec 2>/dev/null; '
    'PATH="\$PATH:/run/current-system/sw/bin:\$HOME/.nix-profile/bin"; '
    'exec pinentry-gate answer $id',
  );
}
