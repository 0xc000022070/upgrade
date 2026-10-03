import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import '../application/agent_kind.dart';
import '../application/agent_state.dart';
import '../application/pin_alerts.dart';
import '../application/reason_lines.dart';
import 'herdr_socket.dart';
import 'host_keys.dart';
import 'shell/remote_shell.dart';
import 'shell/shell_launch.dart';
import 'ssh_settle.dart';

enum AgentSource { herdr, engine }

class AgentApproval {
  const AgentApproval({
    required this.id,
    required this.tool,
    required this.summary,
  });

  final String id;
  final String tool;
  final String summary;

  String get line => summary.isEmpty ? tool : '$tool · $summary';

  Map<String, Object?> toJson() => {'id': id, 'tool': tool, 'summary': summary};

  static AgentApproval? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final id = json['id'];
    final tool = json['tool'];
    final summary = json['summary'];
    if (id is! String || tool is! String || summary is! String) return null;
    return AgentApproval(id: id, tool: tool, summary: summary);
  }
}

class AgentSnapshot {
  const AgentSnapshot({
    required this.session,
    required this.paneId,
    required this.agent,
    required this.state,
    required this.terminalTitleStripped,
    required this.workspaceId,
    required this.cwd,
    required this.stateChangeSeq,
    this.workspaceLabel,
    this.source = AgentSource.herdr,
    this.approval,
    this.question,
    this.message,
    this.herdrPane,
    this.link,
  });

  /// Not in herdr's own document, which one server answers without saying which; stamped
  /// by the reader, because no command reaches a pane without it.
  final String session;
  final String paneId;
  final String agent;

  final AgentState state;

  final String terminalTitleStripped;
  final String workspaceId;
  final String cwd;
  final int stateChangeSeq;

  /// Read off `workspace.list` and stamped by the reader, since the agent document carries
  /// only the id. A refused or unreadable list leaves it null rather than failing the round.
  final String? workspaceLabel;

  final AgentSource source;

  final AgentApproval? approval;
  final String? question;
  final String? message;

  final String? herdrPane;

  final PaneRef? link;

  bool get engine => source == AgentSource.engine;

  String get edgeId =>
      approval == null ? paneId : '$paneId$edgeSeparator${approval!.id}';

  static const edgeSeparator = '#';

  static String paneOfEdge(String edge) => edge.split(edgeSeparator).first;

  AgentSnapshot linkedTo(PaneRef? pane) => AgentSnapshot(
    session: session,
    paneId: paneId,
    agent: agent,
    state: state,
    terminalTitleStripped: terminalTitleStripped,
    workspaceId: workspaceId,
    cwd: cwd,
    stateChangeSeq: stateChangeSeq,
    workspaceLabel: workspaceLabel,
    source: source,
    approval: approval,
    question: question,
    message: message,
    herdrPane: herdrPane,
    link: pane,
  );

  bool get blocked => state.blocked;

  bool get done => state.done;

  PaneRef get pane => (session: session, pane: paneId);

  Map<String, Object?> toJson() => {
    'session': session,
    'pane_id': paneId,
    'agent': agent,
    'agent_status': state.word,
    'terminal_title_stripped': terminalTitleStripped,
    'workspace_id': workspaceId,
    'cwd': cwd,
    'state_change_seq': stateChangeSeq,
    if (workspaceLabel != null) 'workspace_label': workspaceLabel,
    if (source != AgentSource.herdr) 'source': source.name,
    if (approval != null) 'approval': approval!.toJson(),
    if (question != null) 'question': question,
    if (message != null) 'message': message,
    if (herdrPane != null) 'herdr_pane': herdrPane,
  };

  factory AgentSnapshot.fromJson(Map<String, Object?> json) {
    T field<T>(String name) {
      final value = json[name];
      if (value is! T) throw const HerdrProtocolMismatch();
      return value;
    }

    final label = json['workspace_label'];
    if (label != null && label is! String) throw const HerdrProtocolMismatch();
    String? optional(String name) =>
        json[name] is String ? json[name]! as String : null;
    return AgentSnapshot(
      session: field<String>('session'),
      paneId: field<String>('pane_id'),
      agent: field<String>('agent'),
      state: AgentState.of(field<String>('agent_status')),
      terminalTitleStripped: field<String>('terminal_title_stripped'),
      workspaceId: field<String>('workspace_id'),
      cwd: field<String>('cwd'),
      stateChangeSeq: field<int>('state_change_seq'),
      workspaceLabel: label as String?,
      source:
          AgentSource.values
              .where((value) => value.name == json['source'])
              .firstOrNull ??
          AgentSource.herdr,
      approval: AgentApproval.fromJson(json['approval']),
      question: optional('question'),
      message: optional('message'),
      herdrPane: optional('herdr_pane'),
    );
  }
}

/// Two sessions on one host can both own a `w1:p1`, so the id alone is not a pane.
typedef PaneRef = ({String session, String pane});

typedef HerdrRequest = ({String method, Map<String, Object?> params});

/// What a herdr server can answer is asked over its socket. What is left is a TUI the
/// user drives, a shell expansion, a directory test, and the roster itself — no socket
/// method lists sessions.
abstract final class HerdrCommands {
  static final _pane = RegExp(r'^[A-Za-z0-9]+:[A-Za-z0-9]+$');
  static final _session = RegExp(r'^[A-Za-z0-9_.-]+$');

  static bool isSessionName(String name) => _session.hasMatch(name);

  static bool isPane(PaneRef pane) =>
      isSessionName(pane.session) && _pane.hasMatch(pane.pane);

  /// A name is checked against the shape a session name has before it is quoted into a
  /// line. Never a name of the app's own: every one here was read off the host.
  static String _env(String session) {
    if (!isSessionName(session)) throw const HerdrProtocolMismatch();
    return 'env HERDR_SESSION=${shellQuote(session)}';
  }

  static String _herdr(String session, String arguments) =>
      '${_env(session)} herdr $arguments';

  static String sessions() => underSh('exec herdr session list --json');

  /// Quoted for a shell all the same: sshd runs an exec request through the user's
  /// `$SHELL -c`, non-interactively, which is also why no rc of theirs is in front of it.
  static String attach(PaneRef pane, {bool takeover = false}) {
    requirePane(pane.pane);
    final takeoverFlag = takeover ? ' --takeover' : '';
    return _herdr(
      pane.session,
      'agent attach ${shellQuote(pane.pane)}$takeoverFlag',
    );
  }

  /// `workspace.create` takes the cwd it is handed without a word when nothing is there,
  /// so the existence of the directory is settled before it is asked — and `~` is the
  /// shell's to expand, not herdr's.
  static String resolveDirectory(String directory) => underSh(
    'dir=${shellQuote(directory)}; '
    r'''case "$dir" in '~') dir="$HOME";; '~/'*) dir="$HOME/${dir#'~/'}";; esac; '''
    r'''[ -d "$dir" ] || exit 20; printf '%s\n' "$dir"''',
  );

  static String paths() => underSh(r'''
for root in "$HOME/Projects" "$HOME/.dotfiles" "$HOME/src"; do
  [ -d "$root" ] || continue
  find "$root" -name .git -prune -print 2>/dev/null
done | sed "s|/.git$||; s|^$HOME|~|" | sort -u | head -300
''');

  /// A kind that ships with a list prints it; one that does not is asked on the host. Both
  /// answer the same JSON array on stdout.
  static String models(AgentKind kind) {
    final bundled = kind.bundledModels;
    if (bundled != null) {
      return underSh("printf '%s\\n' ${shellQuote(jsonEncode(bundled))}");
    }
    final argv = kind.modelsArgv.map(shellQuote).join(' ');
    return underSh('exec $argv');
  }

  /// Still a command because the shell tab that asks may be reached over mosh, which
  /// forwards no unix socket.
  static String panes(String session) =>
      underSh('exec ${_herdr(session, 'pane list')}');

  static void requirePane(String pane) {
    if (!_pane.hasMatch(pane)) throw const HerdrProtocolMismatch();
  }
}

abstract final class HerdrRequests {
  static final _key = RegExp(r'^(enter|esc|up|down|tab|[A-Za-z0-9])$');
  static final _model = RegExp(r'^[a-z0-9][a-z0-9._:-]{0,63}$');

  /// A flag and not a value: every generated rc assigns `HISTFILE` outright after the
  /// environment is read, so only the rc can undo the rc, and it needs a name to key on.
  static const paneMark = {'DAZZLE_PANE': '1'};

  static const HerdrRequest agentList = (method: 'agent.list', params: {});

  static const HerdrRequest workspaceList = (
    method: 'workspace.list',
    params: {},
  );

  static HerdrRequest workspaceCreate({
    required String cwd,
    required String label,
  }) => (
    method: 'workspace.create',
    params: {'cwd': cwd, 'label': label, 'env': paneMark, 'focus': false},
  );

  static HerdrRequest workspaceClose(String workspace) =>
      (method: 'workspace.close', params: {'workspace_id': workspace});

  static HerdrRequest agentStart({
    required PaneRef pane,
    required String name,
    required AgentKind kind,
    String? model,
  }) {
    HerdrCommands.requirePane(pane.pane);
    if (model != null && !_model.hasMatch(model)) {
      throw ArgumentError.value(model, 'model');
    }
    return (
      method: 'agent.start',
      params: {
        'name': name,
        'kind': kind.name,
        'pane_id': pane.pane,
        'args': [
          ...kind.startFlags,
          if (model != null) ...['--model', model],
        ],
      },
    );
  }

  static HerdrRequest processInfo(PaneRef pane) {
    HerdrCommands.requirePane(pane.pane);
    return (method: 'pane.process_info', params: {'pane_id': pane.pane});
  }

  static HerdrRequest read(PaneRef pane, {int lines = 8}) {
    HerdrCommands.requirePane(pane.pane);
    return (
      method: 'agent.read',
      params: {
        'target': pane.pane,
        'source': 'visible',
        'lines': lines,
        'format': 'text',
      },
    );
  }

  static HerdrRequest sendKeys(PaneRef pane, List<String> keys) {
    HerdrCommands.requirePane(pane.pane);
    if (keys.isEmpty || keys.any((key) => !_key.hasMatch(key))) {
      throw const HerdrProtocolMismatch(null, 'invalid key');
    }
    return (
      method: 'agent.send_keys',
      params: {'target': pane.pane, 'keys': keys},
    );
  }

  static HerdrRequest wait(PaneRef pane, {required Duration timeout}) {
    HerdrCommands.requirePane(pane.pane);
    return (
      method: 'agent.wait',
      params: {
        'target': pane.pane,
        'until': const ['idle'],
        'timeout_ms': timeout.inMilliseconds,
      },
    );
  }

  /// `wait` makes the answer say whether the agent took the text: herdr refuses with
  /// `agent_prompt_stalled` when nothing changed inside the window.
  static HerdrRequest prompt(PaneRef pane, String text) {
    HerdrCommands.requirePane(pane.pane);
    return (
      method: 'agent.prompt',
      params: {
        'target': pane.pane,
        'text': text,
        'wait': {
          'until': const ['working'],
          'timeout_ms': promptStall.inMilliseconds,
        },
      },
    );
  }

  /// Status transitions are not among them — herdr reports those only to a subscription
  /// that named the pane.
  static const paneSet = <Map<String, Object?>>[
    {'type': 'pane.created'},
    {'type': 'pane.closed'},
    {'type': 'pane.exited'},
    {'type': 'pane.agent_detected'},
    {'type': 'workspace.created'},
    {'type': 'workspace.closed'},
  ];

  static List<Map<String, Object?>> paneStatus(PaneRef pane) {
    HerdrCommands.requirePane(pane.pane);
    return [
      {'type': 'pane.agent_status_changed', 'pane_id': pane.pane},
    ];
  }
}

/// A refused spawn is data rather than an exception: the connection worked, but one step
/// of the remote transaction did not.
enum SpawnRefusal {
  noDirectory,
  uploadFailed,
  startFailed,
  spawnFailed,
  timedOut,

  noSession,

  noDefaultSession,
}

class SessionEntry {
  const SessionEntry({
    required this.name,
    required this.running,
    required this.isDefault,
    required this.socketPath,
  });

  final String name;
  final bool running;

  final bool isDefault;

  final String socketPath;
}

sealed class SpawnTarget {
  const SpawnTarget();

  const factory SpawnTarget.session(String name) = SpawnTargetSession;

  const factory SpawnTarget.refused(SpawnRefusal refusal) = SpawnTargetRefused;
}

final class SpawnTargetSession extends SpawnTarget {
  const SpawnTargetSession(this.name);

  final String name;
}

final class SpawnTargetRefused extends SpawnTarget {
  const SpawnTargetRefused(this.refusal);

  final SpawnRefusal refusal;
}

sealed class SpawnResult {
  const SpawnResult();
}

final class SpawnSent extends SpawnResult {
  const SpawnSent(this.paneId);

  final String paneId;
}

final class SpawnRefused extends SpawnResult {
  const SpawnRefused(this.refusal, [this.detail]);

  final SpawnRefusal refusal;

  final String? detail;
}

sealed class HerdrFailure implements Exception {
  const HerdrFailure([this.detail]);

  /// Carried out of here rather than logged here, because the debug line names the host
  /// and the host's name is a thing this layer deliberately does not know.
  final String? detail;

  ReasonLine get line;

  String reason(String host) => line.on(host);

  @override
  String toString() => '$runtimeType(${detail ?? ''})';
}

final class HerdrUnreachable extends HerdrFailure {
  const HerdrUnreachable([super.detail]);

  @override
  ReasonLine get line => ReasonLine.unreachable;
}

/// Separate from [HerdrUnreachable] because the two send the user to different places: a
/// typo in the address, against a port, a firewall or a dead machine.
final class HerdrUnresolved extends HerdrFailure {
  const HerdrUnresolved([super.detail]);

  @override
  ReasonLine get line => ReasonLine.unresolved;
}

final class HerdrKeyRejected extends HerdrFailure {
  const HerdrKeyRejected([super.detail]);

  @override
  ReasonLine get line => ReasonLine.keyRejected;
}

/// Nothing is pinned for this host, and nothing on this path may ask: the poll, the
/// watcher and the send all run with nobody looking at them.
final class HerdrHostKeyUnverified extends HerdrFailure {
  const HerdrHostKeyUnverified([super.detail]);

  @override
  ReasonLine get line => ReasonLine.hostKeyUnverified;
}

final class HerdrHostKeyChanged extends HerdrFailure {
  const HerdrHostKeyChanged([super.detail]);

  @override
  ReasonLine get line => ReasonLine.hostKeyChanged;
}

final class EngineMissing extends HerdrFailure {
  const EngineMissing([super.detail]);

  @override
  ReasonLine get line => ReasonLine.noEngine;
}

final class HerdrMissing extends HerdrFailure {
  const HerdrMissing([super.detail]);

  @override
  ReasonLine get line => ReasonLine.noHerdr;
}

final class HerdrProtocolMismatch extends HerdrFailure {
  const HerdrProtocolMismatch([this.protocol, super.detail]);

  final int? protocol;

  @override
  ReasonLine get line => ReasonLine.protocolMismatch;

  @override
  String reason(String host) => protocolLine(protocol);
}

/// Everything a herdr server can answer travels over one connection, each exchange on a
/// `direct-streamlocal@openssh.com` channel. A channel is a window and two packets,
/// where the command line it replaces was a shell, a `herdr` process and this same
/// socket opened from the far end.
class HerdrSession {
  HerdrSession._(this._socket, this._client);

  @visibleForTesting
  HerdrSession.over(this._socket, this._client);

  final SSHSocket _socket;
  final SSHClient _client;

  final _sockets = <String, String>{};
  final _execs = <SSHSession>{};

  /// One channel per running session reports panes arriving and leaving, one more per
  /// agent pane reports that pane's status transitions, and either kind of event asks the
  /// servers for a fresh list. The roster is re-read on its own slow beat, since no socket
  /// method lists sessions. The stream ends on a dropped connection.
  Stream<List<AgentSnapshot>> watch() => _AgentWatch(this).stream;

  Future<Object?> engine(
    Map<String, Object?> request, {
    Duration? within,
  }) async {
    final result = await _runWithStdin(
      'dazzle-engine',
      Uint8List.fromList(utf8.encode(jsonEncode(request))),
      within: within,
    );
    final said = utf8.decode(result.stderr, allowMalformed: true).trim();
    if (result.exitCode == 127 || said.endsWith('not found')) {
      throw EngineMissing(said);
    }
    try {
      return jsonDecode(utf8.decode(result.stdout));
    } on FormatException {
      throw HerdrProtocolMismatch(
        null,
        said.isEmpty ? 'engine said nothing' : said,
      );
    }
  }

  Future<List<AgentSnapshot>> list() async {
    final roster = await _roster();
    return _agents([
      for (final entry in roster)
        if (entry.running) entry.name,
    ]);
  }

  /// Null rather than throwing: a tail the host would not give up is a notification
  /// without its extra lines, never a notification that does not arrive.
  Future<String?> read(PaneRef pane) => _read(pane);

  Future<void> sendKeys(PaneRef pane, List<String> keys) async {
    final reply = await _call(pane.session, HerdrRequests.sendKeys(pane, keys));
    if (reply is HerdrRefusal) {
      throw HerdrProtocolMismatch(null, _said(reply));
    }
  }

  /// Any failure after workspace creation closes that workspace. The images go first and
  /// outside [deadline]: nothing has been created yet, so an upload that fails leaves no
  /// workspace behind. They are bounded by [uploadDeadline] instead.
  Future<SpawnResult> spawn({
    required AgentKind kind,
    required String directory,
    required String prompt,
    List<RemoteFile> images = const [],
    String? model,
    Duration deadline = spawnDeadline,
  }) async {
    final upload = await _upload(images);
    if (upload != null) {
      return SpawnRefused(SpawnRefusal.uploadFailed, upload);
    }
    String? workspace;
    String? session;
    var expired = false;
    try {
      return await (() async {
        // The session is read off the host, not off a setting: the default when it runs, else
        // the only one running, else a refusal that says which of the two it was.
        final roster = await _guard(
          () => _client.runWithResult(HerdrCommands.sessions()),
        );
        if (roster.exitCode != 0) {
          return SpawnRefused(
            SpawnRefusal.spawnFailed,
            utf8.decode(roster.output).trim(),
          );
        }
        final entries = _remember(
          HerdrClient.parseSessions(utf8.decode(roster.stdout)),
        );
        final target = HerdrClient.spawnTarget(entries);
        final String name;
        switch (target) {
          case SpawnTargetRefused(:final refusal):
            return SpawnRefused(refusal, utf8.decode(roster.stdout).trim());
          case SpawnTargetSession():
            name = target.name;
        }
        session = name;
        final resolved = await _guard(
          () =>
              _client.runWithResult(HerdrCommands.resolveDirectory(directory)),
        );
        if (resolved.exitCode == 20) {
          return const SpawnRefused(SpawnRefusal.noDirectory);
        }
        if (resolved.exitCode != 0) {
          return SpawnRefused(
            SpawnRefusal.spawnFailed,
            utf8.decode(resolved.output).trim(),
          );
        }
        final created = await _call(
          name,
          HerdrRequests.workspaceCreate(
            cwd: utf8.decode(resolved.stdout).trim(),
            label: _directoryLabel(directory),
          ),
        );
        if (created is! HerdrResult) {
          return SpawnRefused(SpawnRefusal.spawnFailed, _said(created));
        }
        final PaneRef pane = (
          session: name,
          pane: HerdrClient.parseWorkspacePane(created.value),
        );
        final made = pane.pane.split(':').first;
        workspace = made;
        if (expired) {
          await _closeWorkspace(made, name);
          return const SpawnRefused(SpawnRefusal.timedOut);
        }
        var started = await _startAtPrompt(
          pane: pane,
          name: _agentName(_directoryLabel(directory), made),
          kind: kind,
          model: model,
        );
        if (started is HerdrRefusal && started.code == 'agent_not_ready') {
          started = await _acceptTrust(pane, kind) ?? started;
        }
        if (started is! HerdrResult) {
          await _closeWorkspace(made, name);
          return SpawnRefused(SpawnRefusal.startFailed, _said(started));
        }
        if (expired) {
          await _closeWorkspace(made, name);
          return const SpawnRefused(SpawnRefusal.timedOut);
        }
        await _awaitReady(pane);
        var sent = await _call(name, HerdrRequests.prompt(pane, prompt));
        // An agent that has just repainted after its trust dialog is idle to herdr a beat
        // before it reads input, and text sent in that beat is gone without a trace.
        for (var attempt = 1; attempt < promptAttempts && !expired; attempt++) {
          if (sent is! HerdrRefusal) break;
          if (HerdrClient.isAgentPending(sent.code)) {
            if (await _acceptTrust(pane, kind) == null) await _awaitReady(pane);
          } else if (!HerdrClient.isPromptStalled(sent.code)) {
            break;
          }
          sent = await _call(name, HerdrRequests.prompt(pane, prompt));
        }
        if (sent is! HerdrResult) {
          await _closeWorkspace(made, name);
          return SpawnRefused(SpawnRefusal.spawnFailed, _said(sent));
        }
        return SpawnSent(pane.pane);
      })().timeout(deadline);
    } on TimeoutException {
      expired = true;
      final made = workspace;
      final name = session;
      if (made != null && name != null) await _closeWorkspace(made, name);
      return const SpawnRefused(SpawnRefusal.timedOut);
    }
  }

  Future<List<String>> paths() async {
    final result = await _guard(
      () => _client.runWithResult(HerdrCommands.paths()),
    );
    if (result.exitCode != 0) return const [];
    return HerdrClient.parsePaths(utf8.decode(result.stdout));
  }

  Future<LaunchTargets> launchTargets({Duration within = launchScanDeadline}) =>
      _guard(() => _launchTargets().timeout(within));

  Future<LaunchTargets> _launchTargets() async {
    final probe = await _guard(
      () => _client.runWithResult(LaunchCommands.present(), stderr: false),
    );
    final present = LaunchCommands.parsePresent(
      utf8.decode(probe.stdout, allowMalformed: true),
    );
    final hasHerdr = present.contains('herdr');
    final hasTmux = present.contains('tmux');
    var sessions = const <SessionEntry>[];
    if (hasHerdr) {
      final roster = await _guard(
        () => _client.runWithResult(HerdrCommands.sessions()),
      );
      if (roster.exitCode == 0) {
        try {
          sessions = HerdrClient.parseSessions(
            utf8.decode(roster.stdout, allowMalformed: true),
          );
        } on HerdrProtocolMismatch {
          sessions = const [];
        }
      }
    }
    final workspaces = <HerdrWorkspaceEntry>[];
    for (final session in sessions.where((session) => session.running)) {
      final listed = await _guard(
        () => _client.runWithResult(LaunchCommands.workspaces(session.name)),
      );
      if (listed.exitCode != 0) continue;
      workspaces.addAll(
        LaunchCommands.parseWorkspaces(
          session.name,
          utf8.decode(listed.stdout, allowMalformed: true),
        ),
      );
    }
    final tmux = hasTmux
        ? await _guard(
            () => _client.runWithResult(LaunchCommands.tmuxSessions()),
          )
        : null;
    return LaunchTargets(
      herdrSessions: sessions,
      workspaces: workspaces,
      tmux: tmux != null && tmux.exitCode == 0
          ? LaunchCommands.parseTmux(
              utf8.decode(tmux.stdout, allowMalformed: true),
            )
          : const [],
      hasHerdr: hasHerdr,
      hasTmux: hasTmux,
    );
  }

  Future<List<String>> models(AgentKind kind) async {
    final result = await _guard(
      () => _client.runWithResult(HerdrCommands.models(kind)),
    );
    if (result.exitCode != 0) return const [];
    return HerdrClient.parseModels(utf8.decode(result.stdout));
  }

  Future<String> openPinRequests({Duration within = pinWatchInterval}) async {
    final result = await _guard(
      () => _runWithStdin(pinentryOpenCommand(), Uint8List(0), within: within),
    );
    return utf8.decode(result.stdout, allowMalformed: true);
  }

  Stream<String> pinRequestChanges() =>
      _changes(pinentryOpenCommand(), pinWatchStep);

  Stream<String> rosterChanges() =>
      _changes(HerdrCommands.sessions(), rosterWatchStep);

  Stream<String> _changes(String command, Duration step) {
    final out = StreamController<String>();
    SSHSession? channel;
    StreamSubscription<String>? frames;
    var cancelled = false;
    out
      ..onListen = () async {
        try {
          channel = await _exec(hostChangesCommand(command, step));
        } catch (error, stack) {
          out.addError(error, stack);
          await out.close();
          return;
        }
        if (cancelled) return _end(channel!);
        frames = hostChangeFrames(channel!.stdout, onQuiet: close).listen(
          out.add,
          onError: out.addError,
          onDone: () {
            _end(channel!);
            unawaited(out.close());
          },
        );
      }
      ..onCancel = () async {
        cancelled = true;
        await frames?.cancel();
        if (channel case final channel?) _end(channel);
      };
    return out.stream;
  }

  /// A closed connection leaves a running exec to sshd, which hands it to init.
  void close() {
    for (final exec in [..._execs]) {
      _end(exec);
    }
    unawaited(closeSsh(_client, _socket));
  }

  Future<SSHSession> _exec(String command) async {
    final session = await _guard(() => _client.execute(command));
    _execs.add(session);
    return session;
  }

  void _end(SSHSession session) {
    _execs.remove(session);
    endExec(session);
  }

  /// `herdr agent start` wants the pane's shell alone at its prompt, and a shell still
  /// sourcing its rc files hands the terminal to every command it runs. herdr refuses with
  /// `agent_pane_busy` for that instant instead of waiting.
  Future<HerdrReply> _startAtPrompt({
    required PaneRef pane,
    required String name,
    required AgentKind kind,
    String? model,
  }) async {
    final settle = Stopwatch()..start();
    while (true) {
      await _awaitPrompt(pane, settle);
      final started = await _call(
        pane.session,
        HerdrRequests.agentStart(
          pane: pane,
          name: name,
          kind: kind,
          model: model,
        ),
      );
      if (started is! HerdrRefusal ||
          settle.elapsed >= promptSettle ||
          started.code != 'agent_pane_busy') {
        return started;
      }
      await Future<void>.delayed(promptPoll);
    }
  }

  Future<void> _awaitPrompt(PaneRef pane, Stopwatch settle) async {
    while (settle.elapsed < promptSettle) {
      final info = await _call(pane.session, HerdrRequests.processInfo(pane));
      if (info is! HerdrResult || HerdrClient.parseShellAtPrompt(info.value)) {
        return;
      }
      await Future<void>.delayed(promptPoll);
    }
  }

  /// A start is answered the moment the process is on the pane, not when the agent is up.
  Future<void> _awaitReady(PaneRef pane) async {
    await _call(pane.session, HerdrRequests.wait(pane, timeout: agentSettle));
  }

  /// `agent_not_ready` is the agent up and waiting on something, and in a directory it has
  /// never been opened in that something is its own trust dialog. Null when the pane shows
  /// anything else: the start's own answer is then the one to report.
  Future<HerdrReply?> _acceptTrust(PaneRef pane, AgentKind kind) async {
    final screen = await _read(pane, lines: trustLines);
    if (screen == null) return null;
    final keys = kind.trustKeys(screen);
    if (keys == null) return null;
    final answered = await _call(
      pane.session,
      HerdrRequests.sendKeys(pane, keys),
    );
    if (answered is HerdrRefusal) return answered;
    return _call(pane.session, HerdrRequests.wait(pane, timeout: trustSettle));
  }

  Future<String?> _read(PaneRef pane, {int lines = 8}) async {
    try {
      final reply = await _call(
        pane.session,
        HerdrRequests.read(pane, lines: lines),
      );
      if (reply is! HerdrResult) return null;
      final read = reply.value['read'];
      final text = read is Map<String, Object?> ? read['text'] : null;
      if (text is! String) return null;
      final tail = text.trimRight();
      return tail.isEmpty ? null : tail;
    } on HerdrFailure {
      return null;
    }
  }

  /// Null when they all landed; the first failure's words otherwise, and the send stops
  /// there rather than prompting an agent about a picture that is not on the host.
  Future<String?> _upload(List<RemoteFile> images) async {
    for (final image in images) {
      final SSHRunResult result;
      try {
        result = await _runWithStdin(
          uploadCommand(image.name),
          image.bytes,
          within: uploadDeadline(image.bytes.length),
        );
      } on TimeoutException {
        return '${image.name} timed out';
      } on HerdrFailure catch (error) {
        return error.detail ?? '$error';
      } catch (error) {
        return '$error';
      }
      if (result.exitCode != 0) {
        final said = utf8.decode(result.stderr).trim();
        return said.isEmpty
            ? '${image.name} exit ${result.exitCode}'
            : '${image.name}: $said';
      }
    }
    return null;
  }

  /// `runWithResult` has no way to write stdin. [within] bounds the whole exchange:
  /// nothing under this notices a link that has stopped moving, since the keepalive pings
  /// on its own timer and swallows whatever comes back.
  Future<SSHRunResult> _runWithStdin(
    String command,
    Uint8List stdin, {
    Duration? within,
  }) async {
    final session = await _exec(command);
    try {
      final out = BytesBuilder(copy: false);
      final err = BytesBuilder(copy: false);
      final drained = Future.wait([
        session.stdout.cast<List<int>>().forEach(out.add),
        session.stderr.cast<List<int>>().forEach(err.add),
      ]);
      session.stdin.add(stdin);
      await awaitWithin(
        Future(() async {
          await session.stdin.close();
          await Future.wait([session.done, drained]);
        }),
        within,
      );
      final stdout = out.takeBytes();
      final stderr = err.takeBytes();
      return SSHRunResult(
        output: Uint8List.fromList([...stdout, ...stderr]),
        exitCode: session.exitCode,
        exitSignal: session.exitSignal,
        stdout: stdout,
        stderr: stderr,
      );
    } finally {
      _end(session);
    }
  }

  Future<void> _closeWorkspace(String workspace, String session) async {
    try {
      await _call(session, HerdrRequests.workspaceClose(workspace));
    } catch (_) {
      // The primary failure is what the caller reports. Cleanup is best effort.
    }
  }

  Future<List<SessionEntry>> _roster() async {
    final result = await _guard(
      () => _client.runWithResult(HerdrCommands.sessions()),
    );
    if (result.exitCode == 127) {
      throw HerdrMissing(utf8.decode(result.output).trim());
    }
    if (result.exitCode != 0) {
      throw HerdrProtocolMismatch(null, utf8.decode(result.output).trim());
    }
    return _remember(HerdrClient.parseSessions(utf8.decode(result.stdout)));
  }

  List<SessionEntry> _remember(List<SessionEntry> entries) {
    _sockets
      ..clear()
      ..addEntries(
        entries.map((entry) => MapEntry(entry.name, entry.socketPath)),
      );
    return entries;
  }

  /// A session whose socket no longer accepts stopped between the roster and its turn, and
  /// is skipped rather than failing the round.
  Future<List<AgentSnapshot>> _agents(Iterable<String> sessions) async {
    final agents = <AgentSnapshot>[];
    for (final session in sessions) {
      final path = _sockets[session];
      if (path == null) continue;
      final link = await _linkOrNone(path);
      if (link == null) continue;
      final reply = await _guard(
        () => _once(link).call(HerdrRequests.agentList.method),
      );
      final found = HerdrClient.parseSessionAgents(reply, session: session);
      if (found.isEmpty) continue;
      agents.addAll(
        HerdrClient.labelWorkspaces(found, await _workspaceLabels(path)),
      );
    }
    return agents;
  }

  Future<Map<String, String>> _workspaceLabels(String path) async {
    try {
      final link = await _linkOrNone(path);
      if (link == null) return const {};
      final reply = await _guard(
        () => _once(link).call(HerdrRequests.workspaceList.method),
      );
      return HerdrClient.parseWorkspaceLabels(reply);
    } on HerdrFailure {
      return const {};
    }
  }

  Future<HerdrReply> _call(String session, HerdrRequest request) =>
      _guard(() => _api(session).call(request.method, request.params));

  HerdrApi _api(String session) {
    final path = _sockets[session];
    if (path == null) {
      throw HerdrProtocolMismatch(null, 'no socket for $session');
    }
    return HerdrApi(() => _link(path));
  }

  HerdrApi _once(HerdrLink link) => HerdrApi(() async => link);

  Future<Stream<HerdrEvent>?> _events(
    String session,
    List<Map<String, Object?>> subscriptions,
  ) async {
    final path = _sockets[session];
    if (path == null) return null;
    final link = await _linkOrNone(path);
    if (link == null) return null;
    return _once(link).subscribe(subscriptions);
  }

  Future<HerdrLink> _link(String path) async {
    final channel = await _guard(() => _client.forwardLocalUnix(path));
    return _wrap(channel);
  }

  /// Null when the far side refused the channel: no server is listening on [path]. A
  /// connection that is itself gone fails with the errors every other exchange fails with.
  Future<HerdrLink?> _linkOrNone(String path) async {
    final SSHForwardChannel channel;
    try {
      channel = await _client.forwardLocalUnix(path);
    } on SSHChannelOpenError {
      return null;
    } catch (error) {
      throw asHerdrFailure(error) ?? error;
    }
    return _wrap(channel);
  }

  /// A channel let go rather than closed: herdr resets a connection whose client
  /// half-closes it, and the answer is already in hand by then.
  HerdrLink _wrap(SSHForwardChannel channel) => HerdrLink(
    incoming: channel.stream,
    outgoing: channel.sink,
    shut: () async => channel.destroy(),
  );

  static String _said(HerdrReply reply) => switch (reply) {
    HerdrRefusal(:final code, :final message) =>
      message.isEmpty ? code : '$code: $message',
    HerdrResult(:final type) => type,
  };
}

class _AgentWatch {
  _AgentWatch(this._session) {
    _out = StreamController<List<AgentSnapshot>>(
      onListen: _start,
      onCancel: _stop,
    );
  }

  final HerdrSession _session;
  late final StreamController<List<AgentSnapshot>> _out;

  final _live = <String>{};
  final _panes = <String, StreamSubscription<HerdrEvent>>{};

  final _statuses = <PaneRef, StreamSubscription<HerdrEvent>>{};

  Timer? _beat;
  StreamSubscription<String>? _rosterChanges;
  Timer? _settle;
  var _busy = false;
  var _again = false;
  var _againRoster = false;
  var _closed = false;

  Stream<List<AgentSnapshot>> get stream => _out.stream;

  void _start() {
    unawaited(_tick(roster: true));
    _rosterChanges = _session.rosterChanges().listen(
      (_) => unawaited(_tick(roster: true)),
      onError: (Object _) {},
      onDone: _pollRoster,
    );
  }

  void _pollRoster() {
    _rosterChanges = null;
    if (_closed) return;
    _beat = Timer.periodic(watchRoster, (_) => unawaited(_tick(roster: true)));
    unawaited(_tick(roster: true));
  }

  Future<void> _stop() async {
    _closed = true;
    _beat?.cancel();
    await _rosterChanges?.cancel();
    _settle?.cancel();
    final held = [..._panes.values, ..._statuses.values];
    _panes.clear();
    _statuses.clear();
    for (final subscription in held) {
      await subscription.cancel();
    }
  }

  /// A burst of events is one list, not one each: a pane going from working to idle moves
  /// the panel once.
  void _nudge() {
    if (_closed) return;
    _settle?.cancel();
    _settle = Timer(watchSettle, () => unawaited(_tick(roster: false)));
  }

  Future<void> _tick({required bool roster}) async {
    if (_closed) return;
    if (_busy) {
      _again = true;
      _againRoster |= roster;
      return;
    }
    _busy = true;
    try {
      if (roster) await _reconcile();
      final agents = await _session._agents(_live);
      if (_closed) return;
      await _track(agents);
      _out.add(agents);
    } catch (error, stack) {
      _fail(error, stack);
      return;
    } finally {
      _busy = false;
    }
    if (_again) {
      _again = false;
      final wanted = _againRoster;
      _againRoster = false;
      unawaited(_tick(roster: wanted));
    }
  }

  Future<void> _reconcile() async {
    final entries = await _session._roster();
    final live = {
      for (final entry in entries)
        if (entry.running) entry.name,
    };
    for (final name in _panes.keys.toList()) {
      if (!live.contains(name)) await _panes.remove(name)!.cancel();
    }
    for (final name in live) {
      if (_panes.containsKey(name)) continue;
      // A channel that ends while the connection lives is that server going away. The next
      // roster puts it back when it returns.
      final held = await _hold(
        name,
        HerdrRequests.paneSet,
        () => _panes.remove(name),
      );
      if (held != null) _panes[name] = held;
    }
    _live
      ..clear()
      ..addAll(live);
  }

  Future<void> _track(List<AgentSnapshot> agents) async {
    final wanted = {for (final agent in agents) agent.pane};
    for (final pane in _statuses.keys.toList()) {
      if (!wanted.contains(pane)) await _statuses.remove(pane)!.cancel();
    }
    for (final pane in wanted) {
      if (_statuses.containsKey(pane)) continue;
      final held = await _hold(
        pane.session,
        HerdrRequests.paneStatus(pane),
        () => _statuses.remove(pane),
      );
      if (held != null) _statuses[pane] = held;
    }
  }

  /// Null when no server answered, or when the watch ended while the channel was being
  /// opened — in which case it is let go rather than left hanging on the connection.
  Future<StreamSubscription<HerdrEvent>?> _hold(
    String session,
    List<Map<String, Object?>> subscriptions,
    void Function() gone,
  ) async {
    final events = await _session._events(session, subscriptions);
    if (events == null) return null;
    final held = events.listen((_) => _nudge(), onDone: gone, onError: _fail);
    if (!_closed) return held;
    await held.cancel();
    return null;
  }

  void _fail(Object error, [StackTrace? stack]) {
    if (_closed) return;
    _closed = true;
    _out.addError(asHerdrFailure(error) ?? error, stack);
    unawaited(_out.close());
  }
}

const spawnDeadline = Duration(seconds: 45);

const launchScanDeadline = Duration(seconds: 15);

/// Sized to the payload rather than flat, because one window cannot be both: short
/// enough to catch a stall and long enough for a picture.
const uploadOpening = Duration(seconds: 15);

/// Bytes per second the budget assumes, well under a bad uplink's real rate.
const uploadRate = 24 * 1024;

Duration uploadDeadline(int bytes) =>
    uploadOpening + Duration(milliseconds: bytes * 1000 ~/ uploadRate);

/// A null [within] is the unbounded wait. What is abandoned is still holding a channel
/// about to be closed under it, and `timeout` drops whatever it fails with then.
Future<void> awaitWithin(Future<void> exchange, Duration? within) =>
    within == null ? exchange : exchange.timeout(within);

/// A login shell on this kind of host is there in well under a second; the window is for
/// slow disks and rc files that call out to the network.
const promptSettle = Duration(seconds: 10);

const promptPoll = Duration(milliseconds: 100);

const trustSettle = Duration(seconds: 15);

const agentSettle = Duration(seconds: 20);

/// Enough of the pane to hold either agent's trust dialog whole.
const trustLines = 40;

/// Longer than herdr's five-second stall window, so a prompt the agent never read is
/// refused as `agent_prompt_stalled` and not as a bare timeout.
const promptStall = Duration(seconds: 6);

const promptAttempts = 3;

/// Long enough that a pane closing and its workspace closing are one read; short enough
/// that the panel is not waiting on it.
const watchSettle = Duration(milliseconds: 250);

const watchRoster = Duration(seconds: 30);

const rosterWatchStep = Duration(seconds: 10);

const hostChangesEnd = '.';

const hostChangesBeat = '~';

const hostChangesBeatEvery = Duration(minutes: 4);

const hostChangesQuiet = Duration(minutes: 5);

/// stdin goes through fd 3, taken before the `&`: sh hands a background job
/// /dev/null, and the subshell reading fd 3 ends the loop with the channel.
String hostChangesCommand(
  String command,
  Duration step, {
  Duration beat = hostChangesBeatEvery,
}) => underSh(
  'exec 2>/dev/null 3<&0; (cat <&3 >/dev/null; kill \$\$) & '
  'sent=; last=; quiet=0; while :; do now=\$($command); '
  'if [ -z "\$sent" ] || [ "\$now" != "\$last" ]; then '
  'sent=1; last=\$now; quiet=0; printf "%s\\n$hostChangesEnd\\n" "\$now"; '
  'else quiet=\$((quiet + ${step.inSeconds})); '
  'if [ \$quiet -ge ${beat.inSeconds} ]; then quiet=0; echo "$hostChangesBeat"; fi; fi; '
  'sleep ${step.inSeconds}; done',
);

Stream<String> hostChangeFrames(
  Stream<List<int>> stdout, {
  Duration quiet = hostChangesQuiet,
  void Function()? onQuiet,
}) {
  final frame = <String>[];
  return stdout
      .cast<List<int>>()
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .timeout(
        quiet,
        onTimeout: (sink) {
          onQuiet?.call();
          sink
            ..addError(
              HerdrUnreachable('no word from the host in ${quiet.inMinutes}m'),
            )
            ..close();
        },
      )
      .transform(
        StreamTransformer.fromHandlers(
          handleData: (line, sink) {
            if (line == hostChangesBeat) return;
            if (line != hostChangesEnd) return frame.add(line);
            sink.add(frame.join('\n'));
            frame.clear();
          },
        ),
      );
}

String _directoryLabel(String directory) {
  final parts = directory.split('/').where((part) => part.isNotEmpty).toList();
  return parts.isEmpty ? 'agent' : parts.last;
}

String _agentName(String label, String workspace) {
  var base = label.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_-]'), '-');
  base = base.replaceFirst(RegExp(r'^[^a-z]+'), '');
  if (base.isEmpty) base = 'agent';
  if (base.length > 24) base = base.substring(0, 24);
  final suffix = workspace.toLowerCase().replaceAll(
    RegExp(r'[^a-z0-9_-]'),
    '-',
  );
  return '$base-$suffix';
}

class HerdrClient {
  const HerdrClient({
    this.timeout = const Duration(seconds: 10),
    this.keepAlive = sshKeepAlive,
  });

  final Duration timeout;

  /// dartssh2 defaults to 10 s; the number is a decision, so it is declared rather than
  /// inherited.
  final Duration keepAlive;

  /// Dart words a name that did not resolve in the exception's own message; the errno
  /// underneath is from the EAI_* namespace, which cannot be told apart from a connect
  /// errno by number alone. Matched over both halves because which one carries the words
  /// depends on the platform.
  static bool isLookupFailure(SocketException error) {
    final said = '${error.message} ${error.osError?.message ?? ''}'
        .toLowerCase();
    return said.contains('failed host lookup') ||
        said.contains('name or service not known') ||
        said.contains('nodename nor servname') ||
        said.contains('no address associated with hostname');
  }

  static String parseWorkspacePane(Map<String, Object?> result) {
    final root = result['root_pane'];
    final pane = root is Map<String, Object?> ? root['pane_id'] : null;
    if (pane is! String) throw const HerdrProtocolMismatch();
    HerdrCommands.requirePane(pane);
    return pane;
  }

  /// Whether the pane's shell holds the terminal alone, which is the state `herdr agent
  /// start` requires. A reply that does not show a process group counts as ready and the
  /// start speaks for itself: throwing past spawn would leak the workspace.
  static bool parseShellAtPrompt(Map<String, Object?> result) {
    final info = result['process_info'];
    if (info is! Map<String, Object?>) return true;
    final shell = info['shell_pid'];
    final group = info['foreground_process_group_id'];
    if (shell is! int || group is! int) return true;
    if (group != shell) return false;
    final processes = info['foreground_processes'];
    if (processes is! List<Object?> || processes.length != 1) return false;
    final only = processes.single;
    return only is Map<String, Object?> && only['pid'] == shell;
  }

  /// The shell's own directory and not `foreground_cwd`: the directory a `vim` is standing
  /// in is not the directory the shell is standing in. A null [paneId] asks for the
  /// focused pane.
  static String? parsePaneCwd(String source, String? paneId) {
    Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      return null;
    }
    final result = decoded is Map<String, Object?> ? decoded['result'] : null;
    final panes = result is Map<String, Object?> ? result['panes'] : null;
    if (panes is! List<Object?>) return null;
    for (final pane in panes) {
      if (pane is! Map<String, Object?>) continue;
      final wanted = paneId == null
          ? pane['focused'] == true
          : pane['pane_id'] == paneId;
      if (!wanted) continue;
      final cwd = pane['cwd'];
      return cwd is String && cwd.startsWith('/') ? cwd : null;
    }
    return null;
  }

  /// herdr saw no state change inside its stall window, or the shorter timeout fired
  /// first. Anything else is the agent refusing the prompt.
  static bool isPromptStalled(String? code) => switch (code) {
    'agent_prompt_stalled' || 'timeout' => true,
    _ => false,
  };

  static bool isAgentPending(String? code) => code == 'agent_not_ready';

  /// Paths are newline-delimited now. JSON arrays remain accepted for hosts running the
  /// previous command wrapper.
  static List<String> parsePaths(String source) {
    Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      return source
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .toList();
    }
    if (decoded is! List<Object?>) return const [];
    return [
      for (final entry in decoded)
        if (entry is String && entry.isNotEmpty) entry,
    ];
  }

  static List<String> parseModels(String source) {
    Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      return const [];
    }
    if (decoded is List<Object?>) {
      return [
        for (final value in decoded)
          if (value is String) value,
      ];
    }
    if (decoded is! Map<String, Object?>) return const [];
    final models = decoded['models'];
    if (models is! List<Object?>) return const [];
    return [
      for (final model in models)
        if (model is Map<String, Object?> && model['slug'] is String)
          model['slug']! as String,
    ];
  }

  /// None when the server stopped between the roster and its turn. Any other refusal is
  /// the host no longer answering the way the app reads it, and an empty panel would hide
  /// that.
  static List<AgentSnapshot> parseSessionAgents(
    HerdrReply reply, {
    required String session,
  }) {
    switch (reply) {
      case HerdrRefusal(:final code, :final message):
        if (code == 'server_not_running') return const [];
        throw HerdrProtocolMismatch(
          null,
          message.isEmpty ? code : '$code: $message',
        );
      case HerdrResult(:final value):
        return parseAgentList(value, session: session);
    }
  }

  /// The document does not say which server answered, and nothing above this layer may
  /// reach a pane without knowing.
  static List<AgentSnapshot> parseAgentList(
    Map<String, Object?> result, {
    required String session,
  }) {
    if (result['type'] != 'agent_list') {
      throw HerdrProtocolMismatch(_protocolOf(result));
    }
    final agents = result['agents'];
    if (agents is! List<Object?>) throw const HerdrProtocolMismatch();
    return [
      for (final agent in agents)
        if (agent is Map<String, Object?>)
          AgentSnapshot.fromJson({...agent, 'session': session})
        else
          throw const HerdrProtocolMismatch(),
    ];
  }

  static Map<String, String> parseWorkspaceLabels(HerdrReply reply) {
    if (reply is! HerdrResult) return const {};
    final result = reply.value;
    final workspaces = result['type'] == 'workspace_list'
        ? result['workspaces']
        : null;
    if (workspaces is! List<Object?>) return const {};
    return {
      for (final workspace in workspaces)
        if (workspace is Map<String, Object?>)
          if ((workspace['workspace_id'], workspace['label'])
              case (final String id, final String label) when label.isNotEmpty)
            id: label,
    };
  }

  static List<AgentSnapshot> labelWorkspaces(
    List<AgentSnapshot> agents,
    Map<String, String> labels,
  ) => [
    for (final agent in agents)
      AgentSnapshot(
        session: agent.session,
        paneId: agent.paneId,
        agent: agent.agent,
        state: agent.state,
        terminalTitleStripped: agent.terminalTitleStripped,
        workspaceId: agent.workspaceId,
        cwd: agent.cwd,
        stateChangeSeq: agent.stateChangeSeq,
        workspaceLabel: labels[agent.workspaceId],
      ),
  ];

  /// A session whose name is not one the app would put on a command line is left out
  /// rather than refused: no command of the app's ever named it either.
  static List<SessionEntry> parseSessions(String source) {
    Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      throw const HerdrProtocolMismatch();
    }
    final sessions = decoded is Map<String, Object?>
        ? decoded['sessions']
        : null;
    if (sessions is! List<Object?>) throw const HerdrProtocolMismatch();
    final entries = <SessionEntry>[];
    for (final entry in sessions) {
      if (entry is! Map<String, Object?>) throw const HerdrProtocolMismatch();
      final name = entry['name'];
      final running = entry['running'];
      final isDefault = entry['default'];
      final socket = entry['socket_path'];
      if (name is! String ||
          running is! bool ||
          isDefault is! bool ||
          socket is! String) {
        throw const HerdrProtocolMismatch();
      }
      if (!HerdrCommands.isSessionName(name)) continue;
      entries.add(
        SessionEntry(
          name: name,
          running: running,
          isDefault: isDefault,
          socketPath: socket,
        ),
      );
    }
    return entries;
  }

  /// The default when it is running, else the only running one, else nowhere.
  static SpawnTarget spawnTarget(List<SessionEntry> sessions) {
    final running = sessions.where((session) => session.running).toList();
    if (running.isEmpty) {
      return const SpawnTarget.refused(SpawnRefusal.noSession);
    }
    for (final session in running) {
      if (session.isDefault) return SpawnTarget.session(session.name);
    }
    if (running.length == 1) return SpawnTarget.session(running.single.name);
    return const SpawnTarget.refused(SpawnRefusal.noDefaultSession);
  }

  static int? _protocolOf(Map<String, Object?> result) {
    final protocol = result['protocol'];
    return protocol is int ? protocol : null;
  }

  Future<HerdrSession> connect({
    required String address,
    required int port,
    required String user,
    required String privateKey,
    HostKeyVerifier? verifier,
    void Function(Future<void> settled)? onSettling,
  }) async {
    final socket = await _guard(
      () => SSHSocket.connect(address, port, timeout: timeout),
      verifier,
    );
    final client = SSHClient(
      socket,
      username: user,
      identities: SSHKeyPair.fromPem(privateKey),
      keepAliveInterval: keepAlive,
      onVerifyHostKey: verifier?.verify,
    );
    try {
      await _guard(
        () => authenticatedWithin(client.authenticated, verifier, timeout),
        verifier,
      );
      return HerdrSession._(socket, client);
    } on HerdrFailure {
      // A half-open connection is worse than none: the host would count it against the one
      // connection per phone until its own timeout.
      final settled = closeSettled(client, socket);
      onSettling?.call(settled);
      rethrow;
    }
  }

  Future<List<AgentSnapshot>> fetch({
    required String address,
    required int port,
    required String user,
    required String privateKey,
    HostKeyVerifier? verifier,
  }) async {
    final session = await connect(
      address: address,
      port: port,
      user: user,
      privateKey: privateKey,
      verifier: verifier,
    );
    try {
      return await session.list();
    } finally {
      session.close();
    }
  }

  Future<List<String>> fetchPaths({
    required String address,
    required int port,
    required String user,
    required String privateKey,
    HostKeyVerifier? verifier,
  }) async {
    final session = await connect(
      address: address,
      port: port,
      user: user,
      privateKey: privateKey,
      verifier: verifier,
    );
    try {
      return await session.paths();
    } finally {
      session.close();
    }
  }

  Future<LaunchTargets> fetchLaunchTargets({
    required String address,
    required int port,
    required String user,
    required String privateKey,
    HostKeyVerifier? verifier,
  }) async {
    final session = await connect(
      address: address,
      port: port,
      user: user,
      privateKey: privateKey,
      verifier: verifier,
    );
    try {
      return await session.launchTargets();
    } finally {
      session.close();
    }
  }

  Future<List<String>> fetchModels({
    required String address,
    required int port,
    required String user,
    required String privateKey,
    required AgentKind kind,
    HostKeyVerifier? verifier,
  }) async {
    final session = await connect(
      address: address,
      port: port,
      user: user,
      privateKey: privateKey,
      verifier: verifier,
    );
    try {
      return await session.models(kind);
    } finally {
      session.close();
    }
  }

  Future<SpawnResult> send({
    required String address,
    required int port,
    required String user,
    required String privateKey,
    required AgentKind kind,
    required String directory,
    required String prompt,
    List<RemoteFile> images = const [],
    String? model,
    HostKeyVerifier? verifier,
  }) async {
    final session = await connect(
      address: address,
      port: port,
      user: user,
      privateKey: privateKey,
      verifier: verifier,
    );
    try {
      return await session.spawn(
        kind: kind,
        directory: directory,
        prompt: prompt,
        images: images,
        model: model,
      );
    } finally {
      session.close();
    }
  }
}

/// Null for anything this app did not expect from ssh: a bug in the layer above reads
/// better as itself than as a reason line.
HerdrFailure? asHerdrFailure(Object error, [HostKeyRefusal? refusal]) =>
    switch (error) {
      HerdrFailure() => error,
      // The verifier's answer is the reason, whatever error the closing handshake surfaced.
      _ when refusal != null => switch (refusal) {
        HostKeyRefusal.unverified => HerdrHostKeyUnverified('$error'),
        HostKeyRefusal.changed => HerdrHostKeyChanged('$error'),
      },
      HerdrMalformed() => HerdrProtocolMismatch(error.protocol, '$error'),
      SSHHostkeyError() => HerdrHostKeyChanged('$error'),
      SSHAuthFailError() => HerdrKeyRejected('$error'),
      SSHKeyDecodeError() => HerdrKeyRejected('$error'),
      SocketException() when HerdrClient.isLookupFailure(error) =>
        HerdrUnresolved('$error'),
      SocketException() => HerdrUnreachable('$error'),
      TimeoutException() => HerdrUnreachable('$error'),
      SSHError() => HerdrUnreachable('$error'),
      _ => null,
    };

Future<T> _guard<T>(
  Future<T> Function() body, [
  HostKeyVerifier? verifier,
]) async {
  try {
    return await body();
  } catch (error) {
    throw asHerdrFailure(error, verifier?.refusal) ?? error;
  }
}
