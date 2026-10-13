import 'dart:convert';

export 'package:upgrade/platform/shell/remote_shell.dart'
    show
        RemoteFile,
        remoteCommandDeadline,
        remotePathFor,
        remoteUploadDirectory,
        shellQuote,
        underSh,
        uploadCommand;

import 'package:upgrade/platform/shell/remote_shell.dart';
import 'package:upgrade/platform/shell/shell_connection.dart';

enum ClipboardBackend { wayland, x11, macos, none }

/// The environment every command on that backend has to carry, because an exec channel
/// starts with none of the desktop's.
class HostClipboard {
  const HostClipboard(this.backend, {this.reason, this.environment = const {}});

  final ClipboardBackend backend;

  final String? reason;

  final Map<String, String> environment;

  bool get usable => backend != ClipboardBackend.none;

  String get label => backend.name.toUpperCase();

  String get line => reason == null ? label : '$label · $reason';

  @override
  bool operator ==(Object other) =>
      other is HostClipboard &&
      other.backend == backend &&
      other.reason == reason &&
      _sameEnvironment(other.environment);

  bool _sameEnvironment(Map<String, String> other) {
    if (other.length != environment.length) return false;
    for (final entry in environment.entries) {
      if (other[entry.key] != entry.value) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(backend, reason, environment.length);

  @override
  String toString() => 'HostClipboard($line $environment)';
}

/// The part that matters is the last test: whether the compositor speaks data-control,
/// asked with the consumer's own requirement rather than inferred from its name.
/// `wl-paste --watch` refuses outright without the protocol and otherwise sits and
/// waits, so a one-second `timeout` answers 1 on the first and 124 on the second.
const probeScript = r'''
printf 'os=%s\n' "$(uname -s)"
r="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
printf 'runtime=%s\n' "$r"
w="${WAYLAND_DISPLAY:-}"
if [ -z "$w" ]; then
  for s in "$r"/wayland-*; do
    case "$s" in *.lock) continue;; esac
    [ -S "$s" ] && w="${s##*/}" && break
  done
fi
printf 'wayland=%s\n' "$w"
d="${DISPLAY:-}"
if [ -z "$d" ]; then
  for s in /tmp/.X11-unix/X*; do
    [ -S "$s" ] && d=":${s##*/X}" && break
  done
fi
printf 'display=%s\n' "$d"
printf 'xauthority=%s\n' "${XAUTHORITY:-}"
for t in wl-copy wl-paste xclip osascript timeout; do
  command -v "$t" >/dev/null 2>&1 && printf 'has=%s\n' "$t"
done
if [ -n "$w" ] && command -v wl-paste >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then
  e=$(XDG_RUNTIME_DIR="$r" WAYLAND_DISPLAY="$w" timeout 1 wl-paste --watch true 2>&1 >/dev/null)
  printf 'watch=%s\n' "$?"
  printf 'watcherror=%s\n' "$e"
fi
exit 0
''';

/// The exit `timeout` reports when the command it wrapped was still running.
const _timedOut = '124';

/// Wayland before X11: a wayland session sets `DISPLAY` too, for XWayland, and the
/// agent's terminal is on the compositor's clipboard.
HostClipboard parseProbe(ExecResult result) {
  HostClipboard answer(
    ClipboardBackend backend, {
    String? reason,
    Map<String, String> environment = const {},
  }) => HostClipboard(backend, reason: reason, environment: environment);
  if (!result.ok) {
    // The script ends in `exit 0`, so a bad exit is the host refusing to run it at all: a
    // key without exec or a missing `sh`.
    final code = result.exitCode?.toString() ?? '?';
    final said = (result.err.trim().isEmpty ? result.out : result.err)
        .trim()
        .split('\n')
        .first
        .trim();
    return answer(
      ClipboardBackend.none,
      reason: said.isEmpty ? 'probe exit $code' : 'probe exit $code · $said',
    );
  }
  final fields = <String, String>{};
  final has = <String>{};
  final lines = const LineSplitter().convert(result.out);
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final at = line.indexOf('=');
    if (at < 0) continue;
    final key = line.substring(0, at);
    final value = line.substring(at + 1);
    if (key == 'has') {
      has.add(value);
    } else if (key == 'watcherror') {
      // Last on purpose, and possibly more than one line: the rest is it.
      fields[key] = [value, ...lines.skip(i + 1)].join('\n').trim();
      break;
    } else {
      fields.putIfAbsent(key, () => value);
    }
  }
  if (fields['os'] == 'Darwin') {
    return has.contains('osascript')
        ? answer(ClipboardBackend.macos)
        : answer(ClipboardBackend.none, reason: 'no osascript');
  }
  final wayland = fields['wayland'] ?? '';
  final display = fields['display'] ?? '';
  if (wayland.isNotEmpty) {
    if (!has.contains('wl-copy')) {
      return answer(ClipboardBackend.none, reason: 'no wl-copy');
    }
    final watch = fields['watch'];
    if (watch != null && watch != _timedOut) {
      final error = fields['watcherror'] ?? '';
      return answer(
        ClipboardBackend.none,
        reason: error.contains('data-control')
            ? 'compositor without data-control'
            : error.isEmpty
            ? 'wl-paste failed'
            : error.split('\n').first.toLowerCase(),
      );
    }
    return answer(
      ClipboardBackend.wayland,
      environment: {
        'XDG_RUNTIME_DIR': fields['runtime'] ?? '',
        'WAYLAND_DISPLAY': wayland,
      },
    );
  }
  if (display.isNotEmpty) {
    if (!has.contains('xclip')) {
      return answer(ClipboardBackend.none, reason: 'no xclip');
    }
    final xauthority = fields['xauthority'] ?? '';
    return answer(
      ClipboardBackend.x11,
      environment: {
        'DISPLAY': display,
        if (xauthority.isNotEmpty) 'XAUTHORITY': xauthority,
      },
    );
  }
  return answer(ClipboardBackend.none, reason: 'no display server');
}

/// Every backend's tool forks to go on serving the selection after the command returns,
/// so both of its outputs go to `/dev/null`: a child still holding the channel's pipes
/// would keep the channel from closing, and the paste is waiting on that close.
String? clipboardCommand(HostClipboard clipboard, String fileName) {
  if (!clipboard.usable) return null;
  final remotePath = remotePathFor(fileName);
  final path = shellQuote(remotePath);
  final environment = clipboard.environment.entries
      .map((entry) => '${entry.key}=${shellQuote(entry.value)}')
      .join(' ');
  final script = switch (clipboard.backend) {
    ClipboardBackend.wayland =>
      '$environment wl-copy --type image/png < $path >/dev/null 2>&1',
    ClipboardBackend.x11 =>
      '$environment xclip -selection clipboard -t image/png -i $path '
          '>/dev/null 2>&1',
    ClipboardBackend.macos =>
      'osascript -e "set the clipboard to (read (POSIX file \\"$remotePath\\") '
          'as «class PNGf»)" >/dev/null 2>&1',
    ClipboardBackend.none => null,
  };
  return script == null ? null : underSh(script);
}

/// Null when no host is held, which is no answer at all.
Future<HostClipboard?> probeClipboard(HostChannels channels) async {
  final result = await channels.exec(
    underSh(probeScript),
    timeout: remoteCommandDeadline,
  );
  return result == null ? null : parseProbe(result);
}
