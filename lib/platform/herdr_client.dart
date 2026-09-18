import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../application/agent_kind.dart';
import '../application/agent_state.dart';
import '../application/reason_lines.dart';
import 'herdr_socket.dart';
import 'host_keys.dart';
import 'shell/remote_shell.dart';

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
  });

  /// The herdr session the agent was listed in. Not in herdr's own document,
  /// which one server answers without saying which; stamped by the reader and
  /// carried from there, because no command reaches a pane without it.
  final String session;
  final String paneId;
  final String agent;

  /// What herdr reported this pane's agent to be. The word it sent survives on
  /// the state and goes back out in [toJson]; nothing above this reads it.
  final AgentState state;

  final String terminalTitleStripped;
  final String workspaceId;
  final String cwd;
  final int stateChangeSeq;

  /// The blocked edge is a question about this one field, asked often enough
  /// to be worth a name.
  bool get blocked => state.blocked;

  PaneRef get pane => (session: session, pane: paneId);

  /// The eight fields the watcher's projection consumes, so a snapshot
  /// survives the hop from the watcher's isolate to the UI's without a second
  /// shape to keep in step.
  Map<String, Object?> toJson() => {
    'session': session,
    'pane_id': paneId,
    'agent': agent,
    'agent_status': state.word,
    'terminal_title_stripped': terminalTitleStripped,
    'workspace_id': workspaceId,
    'cwd': cwd,
    'state_change_seq': stateChangeSeq,
  };

  factory AgentSnapshot.fromJson(Map<String, Object?> json) {
    T field<T>(String name) {
      final value = json[name];
      if (value is! T) throw const HerdrProtocolMismatch();
      return value;
    }

    return AgentSnapshot(
      session: field<String>('session'),
      paneId: field<String>('pane_id'),
      agent: field<String>('agent'),
      state: AgentState.of(field<String>('agent_status')),
      terminalTitleStripped: field<String>('terminal_title_stripped'),
      workspaceId: field<String>('workspace_id'),
      cwd: field<String>('cwd'),
      stateChangeSeq: field<int>('state_change_seq'),
    );
  }
}

/// A pane, named with the session that owns it. Two sessions on one host can
/// both own a `w1:p1`, so the id alone is not a pane.
typedef PaneRef = ({String session, String pane});

/// A method and its arguments, ready for a herdr server.
typedef HerdrRequest = ({String method, Map<String, Object?> params});

/// The commands that are still commands.
///
/// What a herdr server can answer is asked over its socket. What is left is a
/// TUI the user drives, a shell expansion, a directory test, and the roster
/// itself — no socket method lists sessions, and reaching a session's socket
/// means knowing where it is.
abstract final class HerdrCommands {
  static final _pane = RegExp(r'^[A-Za-z0-9]+:[A-Za-z0-9]+$');
  static final _session = RegExp(r'^[A-Za-z0-9_.-]+$');

  static bool isSessionName(String name) => _session.hasMatch(name);

  static bool isPane(PaneRef pane) =>
      isSessionName(pane.session) && _pane.hasMatch(pane.pane);

  /// A name is checked against the shape a session name has before it is
  /// quoted into a line, the way a pane id is. Never a name of the app's own:
  /// every one here was read off the host.
  static String _env(String session) {
    if (!isSessionName(session)) throw const HerdrProtocolMismatch();
    return 'env HERDR_SESSION=${shellQuote(session)}';
  }

  static String _herdr(String session, String arguments) =>
      '${_env(session)} herdr $arguments';

  static String sessions() => underSh('exec herdr session list --json');

  /// The command a shell tab runs in place of the login shell, on a channel
  /// with a pty — the attach is a TUI and owns the terminal until the user
  /// detaches, at which point the command exits and takes the tab with it.
  ///
  /// Quoted for a shell all the same: sshd runs an exec request through the
  /// user's `$SHELL -c`, non-interactively, which is also why no rc of theirs
  /// is in front of it.
  static String attach(PaneRef pane, {bool takeover = false}) {
    requirePane(pane.pane);
    final takeoverFlag = takeover ? ' --takeover' : '';
    return _herdr(
      pane.session,
      'agent attach ${shellQuote(pane.pane)}$takeoverFlag',
    );
  }

  /// The absolute directory [directory] names, or exit 20 when there is none.
  /// `workspace.create` takes the cwd it is handed without a word when nothing
  /// is there, so the existence of the directory is settled before it is
  /// asked — and `~` is the shell's to expand, not herdr's.
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

  /// A kind that ships with a list prints it; one that does not is asked on
  /// the host. Both answer the same JSON array on stdout, so the caller has one
  /// thing to parse. No session goes on the line: nothing here talks to a
  /// herdr server.
  static String models(AgentKind kind) {
    final bundled = kind.bundledModels;
    if (bundled != null) {
      return underSh("printf '%s\\n' ${shellQuote(jsonEncode(bundled))}");
    }
    final argv = kind.modelsArgv.map(shellQuote).join(' ');
    return underSh('exec $argv');
  }

  /// The session's panes, each with the directory its own shell is standing
  /// in. Still a command because the shell tab that asks may be reached over
  /// mosh, which forwards no unix socket.
  static String panes(String session) =>
      underSh('exec ${_herdr(session, 'pane list')}');

  static void requirePane(String pane) {
    if (!_pane.hasMatch(pane)) throw const HerdrProtocolMismatch();
  }
}

/// Every request the app puts on a herdr socket, built in one place so what
/// goes out can be read without following the call.
abstract final class HerdrRequests {
  static final _key = RegExp(r'^(enter|esc|up|down|tab|[A-Za-z0-9])$');
  static final _model = RegExp(r'^[a-z0-9][a-z0-9._:-]{0,63}$');

  /// The pane a send opens is nobody's terminal: the only line typed at its
  /// shell is the agent's own start, flags and all, and that line has no
  /// business in the history the user searches on their machine. Both names
  /// because the shell on the far side is zsh's or bash's, and the ignore
  /// lists because they are what a host's rc leaves alone — `HISTFILE` is
  /// assigned outright by every generated rc there is, so a value put here
  /// loses to the one the rc names a moment later.
  static const withoutHistory = {'HISTORY_IGNORE': '*', 'HISTIGNORE': '*'};

  static const HerdrRequest agentList = (method: 'agent.list', params: {});

  static HerdrRequest workspaceCreate({
    required String cwd,
    required String label,
  }) => (
    method: 'workspace.create',
    params: {
      'cwd': cwd,
      'label': label,
      'env': withoutHistory,
      'focus': false,
    },
  );

  static HerdrRequest workspaceClose(String workspace) => (
    method: 'workspace.close',
    params: {'workspace_id': workspace},
  );

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
        'args': [...kind.startFlags, if (model != null) ...['--model', model]],
      },
    );
  }

  static HerdrRequest processInfo(PaneRef pane) {
    HerdrCommands.requirePane(pane.pane);
    return (
      method: 'pane.process_info',
      params: {'pane_id': pane.pane},
    );
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

  /// `wait` makes the answer say whether the agent took the text: herdr
  /// refuses with `agent_prompt_stalled` when nothing changed inside the
  /// window.
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

  /// What a session's own channel listens for: panes arriving and leaving.
  /// Status transitions are not among them — herdr reports those only to a
  /// subscription that named the pane, which is what [paneStatus] asks for.
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

/// A refused spawn is data rather than an exception: the connection worked,
/// but one step of the remote transaction did not.
enum SpawnRefusal {
  noDirectory,
  uploadFailed,
  startFailed,
  spawnFailed,
  timedOut,

  /// The host runs no herdr session, so there is nowhere to start a pane.
  noSession,

  /// The host runs several sessions and not the default: which of them a new
  /// agent belongs in is not the app's to guess.
  noDefaultSession,
}

/// One row of `herdr session list --json`.
class SessionEntry {
  const SessionEntry({
    required this.name,
    required this.running,
    required this.isDefault,
    required this.socketPath,
  });

  final String name;
  final bool running;

  /// The session herdr itself falls back to with no `HERDR_SESSION` set.
  final bool isDefault;

  /// Where this session's server listens. The roster is the only thing that
  /// says so, which is why the roster is read before anything is asked.
  final String socketPath;
}

/// Where a spawn lands, decided from the roster before anything is created.
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

  /// What the host said, for the debug line. Never shown to the user.
  final String? detail;
}

sealed class HerdrFailure implements Exception {
  const HerdrFailure([this.detail]);

  /// What the transport actually said. Carried out of here rather than logged
  /// here, because the debug line names the host — and the host's name is a
  /// thing this layer deliberately does not know. The caller has both halves.
  final String? detail;

  /// Which of the app's reason lines this failure is.
  ReasonLine get line;

  /// That line, given the host it happened to.
  String reason(String host) => line.on(host);

  @override
  String toString() => '$runtimeType(${detail ?? ''})';
}

final class HerdrUnreachable extends HerdrFailure {
  const HerdrUnreachable([super.detail]);

  @override
  ReasonLine get line => ReasonLine.unreachable;
}

/// The name never resolved, so no socket was ever opened. Separate from
/// [HerdrUnreachable] because the two send the user to different places: a typo
/// in the address, against a port, a firewall or a dead machine.
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

/// Nothing is pinned for this host, and nothing on this path may ask: the
/// poll, the watcher and the send all run with nobody looking at them.
final class HerdrHostKeyUnverified extends HerdrFailure {
  const HerdrHostKeyUnverified([super.detail]);

  @override
  ReasonLine get line => ReasonLine.hostKeyUnverified;
}

/// The machine presented a key that is not the one pinned for it.
final class HerdrHostKeyChanged extends HerdrFailure {
  const HerdrHostKeyChanged([super.detail]);

  @override
  ReasonLine get line => ReasonLine.hostKeyChanged;
}

final class HerdrProtocolMismatch extends HerdrFailure {
  const HerdrProtocolMismatch([this.protocol, super.detail]);

  final int? protocol;

  @override
  ReasonLine get line => ReasonLine.protocolMismatch;

  /// The only failure whose line carries a value.
  @override
  String reason(String host) => protocolLine(protocol);
}

/// One authenticated connection to a host, held open.
///
/// Everything a herdr server can answer travels over that one connection, each
/// exchange on a `direct-streamlocal@openssh.com` channel to the server's own
/// socket. A channel is a window and two packets; the command line it replaces
/// was a shell, a `herdr` process and this same socket opened from the far end.
class HerdrSession {
  HerdrSession._(this._socket, this._client);

  final SSHSocket _socket;
  final SSHClient _client;

  /// Where each herdr session's server listens, as of the last roster read.
  final _sockets = <String, String>{};

  /// Agents as they change, not as a clock says to look.
  ///
  /// One channel per running session reports panes arriving and leaving, one
  /// more per agent pane reports that pane's status transitions, and either
  /// kind of event asks the servers for a fresh list. The roster is re-read on
  /// its own slow beat, since no socket method lists sessions. The stream ends
  /// on a dropped connection, which is the watcher's signal to back off and
  /// reconnect.
  Stream<List<AgentSnapshot>> watch() => _AgentWatch(this).stream;

  /// Every running session's agents, read once.
  Future<List<AgentSnapshot>> list() async {
    final roster = await _roster();
    return _agents([
      for (final entry in roster)
        if (entry.running) entry.name,
    ]);
  }

  /// The expanded notification body. Null rather than throwing: a tail the
  /// host would not give up is a notification without its extra lines, never a
  /// notification that does not arrive.
  Future<String?> read(PaneRef pane) => _read(pane);

  /// The notification's `YES` / `NO`. Throws so it can say `FAILED · …` with
  /// what the host answered.
  Future<void> sendKeys(PaneRef pane, List<String> keys) async {
    final reply = await _call(pane.session, HerdrRequests.sendKeys(pane, keys));
    if (reply is HerdrRefusal) {
      throw HerdrProtocolMismatch(null, _said(reply));
    }
  }

  /// Lands [images], creates a workspace, starts one agent, then prompts it.
  /// Any failure after workspace creation closes that workspace.
  ///
  /// The images go first and outside [deadline]: nothing has been created yet,
  /// so an upload that fails leaves no workspace behind, and a photo on a
  /// phone's uplink is not the hang that deadline is there to catch. They are
  /// bounded all the same, each by its own [uploadDeadline].
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
        // The session is read off the host, not off a setting: the default
        // when it runs, else the only one running, else a refusal that says
        // which of the two it was.
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
          () => _client.runWithResult(
            HerdrCommands.resolveDirectory(directory),
          ),
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
        // An agent that has just repainted after its trust dialog is idle to
        // herdr a beat before it reads input, and text sent in that beat is
        // gone without a trace. A stalled prompt is sent again.
        var sent = await _call(name, HerdrRequests.prompt(pane, prompt));
        for (var attempt = 1; attempt < promptAttempts && !expired; attempt++) {
          if (sent is! HerdrRefusal ||
              !HerdrClient.isPromptStalled(sent.code)) {
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

  /// The host's git checkouts. Empty leaves the manual path field available.
  Future<List<String>> paths() async {
    final result = await _guard(
      () => _client.runWithResult(HerdrCommands.paths()),
    );
    if (result.exitCode != 0) return const [];
    return HerdrClient.parsePaths(utf8.decode(result.stdout));
  }

  /// Empty leaves the agent's own default model selected. No session is
  /// involved: nothing here talks to a herdr server.
  Future<List<String>> models(AgentKind kind) async {
    final result = await _guard(
      () => _client.runWithResult(HerdrCommands.models(kind)),
    );
    if (result.exitCode != 0) return const [];
    return HerdrClient.parseModels(utf8.decode(result.stdout));
  }

  void close() {
    _client.close();
    _socket.close();
  }

  /// `herdr agent start` wants the pane's shell alone at its prompt, and a
  /// shell still sourcing its rc files hands the terminal to every command it
  /// runs. herdr refuses with `agent_pane_busy` for that instant instead of
  /// waiting, so the start is held until process-info shows the prompt, and a
  /// busy answer inside the settle window is the shell not being there yet.
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

  /// Returns once the shell holds the terminal, the settle window closes, or
  /// the host cannot say. In the last two cases the start itself reports what
  /// is actually wrong.
  Future<void> _awaitPrompt(PaneRef pane, Stopwatch settle) async {
    while (settle.elapsed < promptSettle) {
      final info = await _call(pane.session, HerdrRequests.processInfo(pane));
      if (info is! HerdrResult ||
          HerdrClient.parseShellAtPrompt(info.value)) {
        return;
      }
      await Future<void>.delayed(promptPoll);
    }
  }

  /// `agent_not_ready` is the agent up and waiting on something, and in a
  /// directory it has never been opened in that something is its own trust
  /// dialog. The user chose the directory and the run is already unattended,
  /// so the dialog is answered for them and `agent wait` judges the start.
  /// Null when the pane shows anything else: the start's own answer is then
  /// the one to report.
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
    return _call(
      pane.session,
      HerdrRequests.wait(pane, timeout: trustSettle),
    );
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

  /// Every image on one exec channel each, in the order they were attached.
  /// Null when they all landed; the first failure's words otherwise, and the
  /// send stops there rather than prompting an agent about a picture that is
  /// not on the host.
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

  /// `runWithResult` has no way to write stdin, and an image's whole content
  /// arrives that way.
  ///
  /// [within] bounds the whole exchange. Nothing under this notices a link
  /// that has stopped moving — the keepalive pings on its own timer and
  /// swallows whatever comes back — so a channel that stalls stalls for as
  /// long as the app is willing to wait on it, and this is where that is
  /// decided.
  Future<SSHRunResult> _runWithStdin(
    String command,
    Uint8List stdin, {
    Duration? within,
  }) async {
    final session = await _guard(() => _client.execute(command));
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
      session.close();
    }
  }

  Future<void> _closeWorkspace(String workspace, String session) async {
    try {
      await _call(session, HerdrRequests.workspaceClose(workspace));
    } catch (_) {
      // The primary failure is what the caller reports. Cleanup is best effort.
    }
  }

  /// The roster, and with it where every session listens.
  Future<List<SessionEntry>> _roster() async {
    final result = await _guard(
      () => _client.runWithResult(HerdrCommands.sessions()),
    );
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

  /// The agents in [sessions], each stamped with the session that answered. A
  /// session whose socket no longer accepts stopped between the roster and its
  /// turn, and is skipped rather than failing the round.
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
      agents.addAll(HerdrClient.parseSessionAgents(reply, session: session));
    }
    return agents;
  }

  Future<HerdrReply> _call(String session, HerdrRequest request) => _guard(
    () => _api(session).call(request.method, request.params),
  );

  HerdrApi _api(String session) {
    final path = _sockets[session];
    if (path == null) {
      throw HerdrProtocolMismatch(null, 'no socket for $session');
    }
    return HerdrApi(() => _link(path));
  }

  /// An api over a link that is already open. Good for exactly one exchange,
  /// which is all a herdr connection answers anyway.
  HerdrApi _once(HerdrLink link) => HerdrApi(() async => link);

  /// An event channel held open on [session]'s server, or null when nothing
  /// answers on its socket.
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

  /// The same, but null when the far side refused the channel: no server is
  /// listening on [path]. A connection that is itself gone fails with the
  /// errors every other exchange fails with, and is not swallowed here.
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

  /// A channel let go rather than closed: herdr resets a connection whose
  /// client half-closes it, and the answer is already in hand by then.
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

/// The event-driven watch: the roster on a slow beat, the servers' own events
/// for everything else, and one agent list per settled burst of them.
class _AgentWatch {
  _AgentWatch(this._session) {
    _out = StreamController<List<AgentSnapshot>>(
      onListen: _start,
      onCancel: _stop,
    );
  }

  final HerdrSession _session;
  late final StreamController<List<AgentSnapshot>> _out;

  /// The running sessions, and the channel each one's panes are reported on.
  final _live = <String>{};
  final _panes = <String, StreamSubscription<HerdrEvent>>{};

  /// One channel per agent pane. Nothing else reports a status transition.
  final _statuses = <PaneRef, StreamSubscription<HerdrEvent>>{};

  Timer? _beat;
  Timer? _settle;
  var _busy = false;
  var _again = false;
  var _againRoster = false;
  var _closed = false;

  Stream<List<AgentSnapshot>> get stream => _out.stream;

  void _start() {
    unawaited(_tick(roster: true));
    _beat = Timer.periodic(watchRoster, (_) => unawaited(_tick(roster: true)));
  }

  Future<void> _stop() async {
    _closed = true;
    _beat?.cancel();
    _settle?.cancel();
    final held = [..._panes.values, ..._statuses.values];
    _panes.clear();
    _statuses.clear();
    for (final subscription in held) {
      await subscription.cancel();
    }
  }

  /// A burst of events is one list, not one each: a pane going from working to
  /// idle moves the panel once.
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

  /// The roster, and a pane channel for every session it calls running.
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
      // A channel that ends while the connection lives is that server going
      // away. The next roster puts it back when it returns.
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

  /// A status channel for every pane in [agents], and none for panes that are
  /// no longer there.
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

  /// One channel, listening. Null when no server answered, or when the watch
  /// ended while it was being opened — in which case the channel just opened
  /// is let go rather than left hanging on the connection.
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

/// How long a send waits for workspace creation, agent startup, and the prompt.
const spawnDeadline = Duration(seconds: 45);

/// What an image's bytes are given before the upload is called a hang: a flat
/// cost for opening the channel, plus the time the bytes themselves need at a
/// rate a phone away from wifi still meets.
///
/// Sized to the payload rather than flat, because one window cannot be both:
/// short enough to catch a stall and long enough for a picture.
const uploadOpening = Duration(seconds: 15);

/// Bytes per second the budget assumes, well under a bad uplink's real rate.
const uploadRate = 24 * 1024;

Duration uploadDeadline(int bytes) =>
    uploadOpening + Duration(milliseconds: bytes * 1000 ~/ uploadRate);

/// Waits for [exchange], or, past [within], stops waiting and abandons it.
/// A null [within] is the unbounded wait, for the exchanges that are already
/// inside a deadline of their own.
///
/// What is abandoned is still holding a channel that is about to be closed
/// under it, and `timeout` drops whatever it fails with then: the caller has
/// already been told the exchange gave up, and one failure is the whole of
/// what happened.
Future<void> awaitWithin(Future<void> exchange, Duration? within) =>
    within == null ? exchange : exchange.timeout(within);

/// How long a fresh pane's shell may take to reach its prompt. A login shell
/// on this kind of host is there in well under a second; the window is for
/// slow disks and rc files that call out to the network.
const promptSettle = Duration(seconds: 10);

const promptPoll = Duration(milliseconds: 100);

/// How long an agent that has just been told to trust its directory may take
/// to reach its prompt.
const trustSettle = Duration(seconds: 15);

/// Enough of the pane to hold either agent's trust dialog whole.
const trustLines = 40;

/// Longer than herdr's five-second stall window, so a prompt the agent never
/// read is refused as `agent_prompt_stalled` and not as a bare timeout.
const promptStall = Duration(seconds: 6);

const promptAttempts = 3;

/// How long a burst of events is gathered before the agents are read. Long
/// enough that a pane closing and its workspace closing are one read; short
/// enough that the panel is not waiting on it.
const watchSettle = Duration(milliseconds: 250);

/// How often the roster is re-read while watching. Slow, because the only
/// thing it catches is a herdr session starting or stopping, and it is the one
/// part of the watch that still costs a process.
const watchRoster = Duration(seconds: 30);

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
    this.keepAlive = const Duration(seconds: 15),
  });

  final Duration timeout;

  /// Keepalive every 15 s. dartssh2 defaults to 10; the number is a decision,
  /// so it is declared rather than inherited.
  final Duration keepAlive;

  /// Dart words a name that did not resolve in the exception's own message;
  /// the errno underneath is from the EAI_* namespace, which cannot be told
  /// apart from a connect errno by number alone. Matched on the message for
  /// that reason, over both halves because which one carries the words depends
  /// on the platform.
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

  /// Whether the pane's shell holds the terminal alone: it owns the foreground
  /// process group and is that group's only member. This is the state
  /// `herdr agent start` requires. A reply that does not show a process group
  /// cannot be waited on, so it counts as ready and the start speaks for
  /// itself. Not a mismatch: throwing past spawn would leak the workspace.
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

  /// Where one pane's shell is standing, out of a `pane list`. The shell's own
  /// directory and not `foreground_cwd`: the directory a `vim` is standing in
  /// is not the directory the shell is standing in.
  ///
  /// A null [paneId] asks for the focused pane, which is what a tab holding a
  /// whole session is showing.
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

  /// Whether a refused `agent.prompt` means the text was never read: herdr saw
  /// no state change inside its stall window, or the shorter timeout fired
  /// first. Anything else is the agent refusing the prompt.
  static bool isPromptStalled(String? code) => switch (code) {
    'agent_prompt_stalled' || 'timeout' => true,
    _ => false,
  };

  /// Paths are newline-delimited now. JSON arrays remain accepted for hosts
  /// running the previous command wrapper.
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

  /// What one session contributes to a list: its agents, or none when the
  /// server stopped between the roster and its turn. Any other refusal is the
  /// host no longer answering the way the app reads it, and an empty panel
  /// would hide that.
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

  /// One server's `agent.list` result, every agent in it stamped with
  /// [session]: the document does not say which server answered, and nothing
  /// above this layer may reach a pane without knowing.
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

  /// The `herdr session list --json` roster. A session whose name is not one
  /// the app would put on a command line is left out rather than refused: no
  /// command of the app's ever named it either.
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

  /// Where a spawn goes on a host with these sessions: the default when it is
  /// running, else the only running one, else nowhere.
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
  }) async {
    final socket = await _guard(
      () => SSHSocket.connect(address, port, timeout: timeout),
      verifier,
    );
    final client = SSHClient(
      socket,
      username: user,
      identities: SSHKeyPair.fromPem(privateKey),
      handshakeTimeout: timeout,
      authTimeout: timeout,
      keepAliveInterval: keepAlive,
      onVerifyHostKey: verifier?.verify,
    );
    try {
      await _guard(() => client.authenticated, verifier);
      return HerdrSession._(socket, client);
    } on HerdrFailure {
      // A half-open connection is worse than none: the host would count it
      // against the one connection per phone until its own timeout.
      client.close();
      socket.close();
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

  /// The host's git checkouts, on a connection of its own. One shot: the
  /// picker asks once when it opens and the answer is cached by the caller.
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

/// Every ssh error this app can meet, mapped onto the reason lines.
///
/// Shared by the one-shot fetch and by every exchange on a held session: a
/// session that drops mid-watch fails with the same [SSHError] shapes as one
/// that never connected, and the watcher says why in those same words.
/// Null for anything this app did not expect from ssh: a bug in the layer above
/// reads better as itself than as `nyx unreachable`.
HerdrFailure? asHerdrFailure(
  Object error, [
  HostKeyRefusal? refusal,
]) => switch (error) {
  HerdrFailure() => error,
  // The verifier's answer is the reason, whatever error the closing handshake
  // surfaced.
  _ when refusal != null => switch (refusal) {
    HostKeyRefusal.unverified => HerdrHostKeyUnverified('$error'),
    HostKeyRefusal.changed => HerdrHostKeyChanged('$error'),
  },
  // A socket that answered something this app cannot read is a herdr the app
  // does not know how to talk to.
  HerdrMalformed() => HerdrProtocolMismatch(error.protocol, '$error'),
  SSHHostkeyError() => HerdrHostKeyChanged('$error'),
  SSHAuthFailError() => HerdrKeyRejected('$error'),
  SSHKeyDecodeError() => HerdrKeyRejected('$error'),
  // The only failure that happens before an address exists.
  SocketException() when HerdrClient.isLookupFailure(error) => HerdrUnresolved(
    '$error',
  ),
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
