import 'dart:convert';

import '../herdr_client.dart';
import 'remote_shell.dart';

sealed class ShellLaunch {
  const ShellLaunch();

  static final _tmuxName = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

  static bool isTmuxName(String name) => _tmuxName.hasMatch(name);

  String get tag;

  String get command;

  static ShellLaunch? parse(String? tag) {
    if (tag == null) return null;
    final split = tag.indexOf(':');
    if (split < 0) return null;
    final name = tag.substring(split + 1);
    return switch (tag.substring(0, split)) {
      'tmux' when isTmuxName(name) => TmuxLaunch(name),
      'herdr' when HerdrCommands.isSessionName(name) => HerdrLaunch(name),
      _ => null,
    };
  }
}

final class TmuxLaunch extends ShellLaunch {
  TmuxLaunch(this.session) {
    if (!ShellLaunch.isTmuxName(session)) throw ArgumentError.value(session);
  }

  final String session;

  @override
  String get tag => 'tmux:$session';

  @override
  String get command => 'exec tmux new-session -A -s ${shellQuote(session)}';

  @override
  bool operator ==(Object other) =>
      other is TmuxLaunch && other.session == session;

  @override
  int get hashCode => session.hashCode;
}

final class HerdrLaunch extends ShellLaunch {
  HerdrLaunch(this.session, {this.workspace}) {
    if (!HerdrCommands.isSessionName(session)) {
      throw ArgumentError.value(session);
    }
    final workspace = this.workspace;
    if (workspace != null && !_workspace.hasMatch(workspace)) {
      throw ArgumentError.value(workspace);
    }
  }

  static final _workspace = RegExp(r'^[A-Za-z0-9]+$');

  final String session;
  final String? workspace;

  @override
  String get tag => 'herdr:$session';

  @override
  String get command {
    final quoted = shellQuote(session);
    // The roster names the unnamed session `default`, which is not a name `--session` takes.
    final attach = session == 'default'
        ? 'exec herdr'
        : 'exec herdr --session $quoted';
    final workspace = this.workspace;
    if (workspace == null) return attach;
    return 'HERDR_SESSION=$quoted herdr workspace focus '
        '${shellQuote(workspace)} >/dev/null 2>&1; $attach';
  }

  @override
  bool operator ==(Object other) =>
      other is HerdrLaunch &&
      other.session == session &&
      other.workspace == workspace;

  @override
  int get hashCode => Object.hash(session, workspace);
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
  });

  final String name;
  final int windows;
  final int attached;
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
  static const tmuxFormat =
      '#{session_name}\t#{session_windows}\t#{session_attached}';

  static String tmuxSessions() => underSh(
    'command -v tmux >/dev/null 2>&1 || exit 127; '
    'tmux list-sessions -F ${shellQuote(tmuxFormat)} 2>/dev/null; exit 0',
  );

  static String workspaces(String session) {
    if (!HerdrCommands.isSessionName(session)) {
      throw const HerdrProtocolMismatch();
    }
    return underSh(
      'exec env HERDR_SESSION=${shellQuote(session)} herdr workspace list',
    );
  }

  static List<TmuxSessionEntry> parseTmux(String source) => [
    for (final line in const LineSplitter().convert(source))
      if (line.split('\t') case [final name, final windows, final attached]
          when ShellLaunch.isTmuxName(name))
        TmuxSessionEntry(
          name: name,
          windows: int.tryParse(windows) ?? 0,
          attached: int.tryParse(attached) ?? 0,
        ),
  ];

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
            when HerdrLaunch._workspace.hasMatch(id))
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
