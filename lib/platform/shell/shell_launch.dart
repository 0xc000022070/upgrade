import 'dart:convert';

import 'package:upgrade/platform/herdr_client.dart';
import 'package:upgrade/platform/shell/remote_shell.dart';

sealed class ShellLaunch {
  const ShellLaunch();

  static final _tmuxName = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

  static bool isTmuxName(String name) => _tmuxName.hasMatch(name);

  static final _tmuxSocket = RegExp(r'^/[A-Za-z0-9_./-]{1,256}$');

  static bool isTmuxSocket(String path) => _tmuxSocket.hasMatch(path);

  String get tag;

  String get command;

  static ShellLaunch? parse(String? tag) {
    if (tag == null) return null;
    final split = tag.indexOf(':');
    if (split < 0) return null;
    final name = tag.substring(split + 1);
    return switch (tag.substring(0, split)) {
      'tmux' => _tmux(name),
      'herdr' when HerdrCommands.isSessionName(name) => HerdrLaunch(name),
      _ => null,
    };
  }

  static TmuxLaunch? _tmux(String value) {
    final at = value.indexOf('@');
    final name = at < 0 ? value : value.substring(0, at);
    final socket = at < 0 ? null : value.substring(at + 1);
    if (!isTmuxName(name)) return null;
    if (socket != null && !isTmuxSocket(socket)) return null;
    return TmuxLaunch(name, socket: socket);
  }
}

final class TmuxLaunch extends ShellLaunch {
  TmuxLaunch(this.session, {this.socket}) {
    if (!ShellLaunch.isTmuxName(session)) throw ArgumentError.value(session);
    final path = socket;
    if (path != null && !ShellLaunch.isTmuxSocket(path)) {
      throw ArgumentError.value(path);
    }
  }

  final String session;

  final String? socket;

  @override
  String get tag => socket == null ? 'tmux:$session' : 'tmux:$session@$socket';

  @override
  // tmux makes its socket directory only for a socket it chose itself, and a reboot
  // empties the one a picked socket lives in.
  String get command => switch (socket) {
    null => 'exec tmux new-session -A -s ${shellQuote(session)}',
    final path =>
      'mkdir -p -m 700 ${shellQuote(path.substring(0, path.lastIndexOf('/').clamp(1, path.length)))}; '
          'exec tmux -S ${shellQuote(path)} '
          'new-session -A -s ${shellQuote(session)}',
  };

  @override
  bool operator ==(Object other) =>
      other is TmuxLaunch && other.session == session && other.socket == socket;

  @override
  int get hashCode => Object.hash(session, socket);
}

final class HerdrLaunch extends ShellLaunch {
  HerdrLaunch(this.session) {
    if (!HerdrCommands.isSessionName(session)) {
      throw ArgumentError.value(session);
    }
  }

  final String session;

  @override
  String get tag => 'herdr:$session';

  @override
  String get command => session == 'default'
      // The roster names the unnamed session `default`, which is not a name `--session` takes.
      ? 'exec herdr'
      : 'exec herdr --session ${shellQuote(session)}';

  @override
  bool operator ==(Object other) =>
      other is HerdrLaunch && other.session == session;

  @override
  int get hashCode => session.hashCode;
}

class HerdrWorkspaceEntry {
  const HerdrWorkspaceEntry({
    required this.session,
    required this.id,
    required this.label,
    required this.status,
    required this.focused,
  });

  final String session;
  final String id;
  final String label;
  final String? status;
  final bool focused;
}

class TmuxSessionEntry {
  const TmuxSessionEntry({
    required this.name,
    required this.windows,
    required this.attached,
    this.socket,
  });

  final String name;
  final int windows;
  final int attached;
  final String? socket;

  TmuxLaunch get launch => TmuxLaunch(name, socket: socket);

  String? get socketDir {
    final path = socket;
    if (path == null) return null;
    final cut = path.lastIndexOf('/tmux-');
    return cut > 0 ? path.substring(0, cut) : path;
  }
}

class LaunchTargets {
  const LaunchTargets({
    required this.herdrSessions,
    required this.workspaces,
    required this.tmux,
    required this.hasHerdr,
    required this.hasTmux,
  });

  final List<SessionEntry> herdrSessions;
  final List<HerdrWorkspaceEntry> workspaces;
  final List<TmuxSessionEntry> tmux;
  final bool hasHerdr;
  final bool hasTmux;

  String get nextTmuxName {
    final taken = {for (final entry in tmux) entry.name};
    var n = 0;
    while (taken.contains('$n')) {
      n++;
    }
    return '$n';
  }
}

abstract final class LaunchCommands {
  static final _workspace = RegExp(r'^[A-Za-z0-9]+$');

  static const tmuxFormat =
      '#{session_name}\t#{session_windows}\t#{session_attached}';

  /// Presence is read off stdout: Tailscale SSH on a Mac reports every exit as 0, so a
  /// missing binary's 127 never reaches the phone.
  static String present() => underSh(
    'for c in herdr tmux; do command -v "\$c" >/dev/null 2>&1 && echo "\$c"; done; exit 0',
  );

  static Set<String> parsePresent(String source) =>
      const LineSplitter().convert(source).map((line) => line.trim()).toSet();

  static String tmuxSessions() => underSh(
    'tmux list-sessions -F ${shellQuote('\t$tmuxFormat')} 2>/dev/null; '
    'u=\$(id -u); own="\${TMUX_TMPDIR:-/tmp}/tmux-\$u/default"; '
    'for s in "/tmp/tmux-\$u/default" '
    '"\${XDG_RUNTIME_DIR:-/run/user/\$u}/tmux-\$u/default"; do '
    '[ -S "\$s" ] && ! [ "\$s" -ef "\$own" ] && '
    'tmux -S "\$s" list-sessions '
    '-F ${shellQuote('#{socket_path}\t$tmuxFormat')} 2>/dev/null; '
    'done; exit 0',
  );

  static String workspaces(String session) {
    if (!HerdrCommands.isSessionName(session)) {
      throw const HerdrProtocolMismatch();
    }
    return underSh(
      'exec env HERDR_SESSION=${shellQuote(session)} herdr workspace list',
    );
  }

  static List<TmuxSessionEntry> parseTmux(String source) {
    final seen = <String>{};
    return [
      for (final line in const LineSplitter().convert(source))
        if (line.split('\t')
            case [final socket, final name, final windows, final attached]
            when ShellLaunch.isTmuxName(name) &&
                (socket.isEmpty || ShellLaunch.isTmuxSocket(socket)) &&
                seen.add('$name@$socket'))
          TmuxSessionEntry(
            name: name,
            windows: int.tryParse(windows) ?? 0,
            attached: int.tryParse(attached) ?? 0,
            socket: socket.isEmpty ? null : socket,
          ),
    ];
  }

  static List<HerdrWorkspaceEntry> parseWorkspaces(
    String session,
    String source,
  ) {
    Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      return const [];
    }
    final result = decoded is Map<String, Object?> ? decoded['result'] : null;
    final list = result is Map<String, Object?> ? result['workspaces'] : null;
    if (list is! List<Object?>) return const [];
    return [
      for (final entry in list)
        if (entry
            case {'workspace_id': final String id, 'label': final String label}
            when _workspace.hasMatch(id))
          HerdrWorkspaceEntry(
            session: session,
            id: id,
            label: label,
            status: switch (entry['agent_status']) {
              final String status => status,
              _ => null,
            },
            focused: entry['focused'] == true,
          ),
    ];
  }
}
