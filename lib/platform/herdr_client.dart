import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../application/agent_kind.dart';
import '../application/agent_state.dart';
import '../application/reason_lines.dart';
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
  /// which one server answers without saying which; stamped by the sweep and
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

  /// The eight fields the watcher's projection consumes, so a
  /// snapshot survives the hop from the watcher's isolate to the UI's without a
  /// second shape to keep in step.
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

abstract final class HerdrCommands {
  static final _pane = RegExp(r'^[A-Za-z0-9]+:[A-Za-z0-9]+$');
  static final _session = RegExp(r'^[A-Za-z0-9_.-]+$');
  static final _key = RegExp(r'^(enter|esc|up|down|tab|[A-Za-z0-9])$');
  static final _model = RegExp(r'^[a-z0-9][a-z0-9._:-]{0,63}$');

  static bool isSessionName(String name) => _session.hasMatch(name);

  /// A name is checked against the shape a session name has before it is
  /// quoted into a line, the way a pane id is. Never a name of the app's own:
  /// every one here was read off the host.
  static String _env(String session) {
    if (!isSessionName(session)) throw const HerdrProtocolMismatch();
    return 'env HERDR_SESSION=${shellQuote(session)}';
  }

  static String _herdr(String session, String arguments) =>
      '${_env(session)} herdr $arguments';

  /// One sweep: the roster, held; then every running session's agent list,
  /// one line each with the name and a tab in front of it; then the roster,
  /// closing the frame. The roster is read before the sessions are asked so a
  /// session that stops in between is one that answers, not one that is
  /// missing.
  static const _sweep =
      r'''r=$(herdr session list --json) || exit; '''
      r'''herdr session list | awk 'NR>1 && $2=="running"{print $1}' | '''
      r'''while read -r s; do printf '%s\t' "$s"; '''
      r'''env HERDR_SESSION="$s" herdr agent list | tr -d '\n'; printf '\n'; '''
      r'''done; printf '%s' "$r" | tr -d '\n'; printf '\n'; ''';

  static String list() => underSh(_sweep);

  static String watch() => underSh('while :; do ${_sweep}sleep 2; done');

  static String sessions() => underSh('exec herdr session list --json');

  /// A line for a login shell, not a command for an exec channel: the attach
  /// is a TUI that owns the terminal until the user detaches, and it exits
  /// back into the shell it was typed in.
  static String attach(PaneRef pane) {
    _requirePane(pane.pane);
    return _herdr(pane.session, 'agent attach ${shellQuote(pane.pane)}');
  }

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

  static String read(PaneRef pane, {int lines = 8}) {
    _requirePane(pane.pane);
    return underSh(
      'exec ${_herdr(pane.session, 'agent read ${shellQuote(pane.pane)} '
      '--source visible --lines $lines --format text')}',
    );
  }

  static String wait(PaneRef pane, {required Duration timeout}) {
    _requirePane(pane.pane);
    return underSh(
      'exec ${_herdr(pane.session, 'agent wait ${shellQuote(pane.pane)} '
      '--until idle --timeout ${timeout.inMilliseconds}')}',
    );
  }

  static String keys(PaneRef pane, List<String> keys) {
    _requirePane(pane.pane);
    if (keys.isEmpty || keys.any((key) => !_key.hasMatch(key))) {
      throw const HerdrProtocolMismatch(null, 'invalid key');
    }
    final arguments = keys.map(shellQuote).join(' ');
    return underSh(
      'exec ${_herdr(pane.session, 'agent send-keys ${shellQuote(pane.pane)} '
      '$arguments')}',
    );
  }

  static String workspaceCreate(
    String directory, {
    required String label,
    required String session,
  }) => underSh(
    'dir=${shellQuote(directory)}; '
    r'''case "$dir" in '~') dir="$HOME";; '~/'*) dir="$HOME/${dir#'~/'}";; esac; '''
    r'''[ -d "$dir" ] || { printf '%s\n' 'spectacle: no directory' >&2; exit 20; }; '''
    '${_herdr(session, 'workspace create --cwd "\$dir" '
    '--label ${shellQuote(label)} --no-focus')}',
  );

  static String agentStart({
    required PaneRef pane,
    required String name,
    required AgentKind kind,
    String? model,
  }) {
    _requirePane(pane.pane);
    if (model != null && !_model.hasMatch(model)) {
      throw ArgumentError.value(model, 'model');
    }
    final flags = [...kind.startFlags];
    if (model != null) flags.addAll(['--model', model]);
    final arguments = [
      'agent',
      'start',
      name,
      '--kind',
      kind.name,
      '--pane',
      pane.pane,
      '--',
      ...flags,
    ].map(shellQuote).join(' ');
    return underSh('exec ${_herdr(pane.session, arguments)}');
  }

  static String processInfo(PaneRef pane) {
    _requirePane(pane.pane);
    return underSh(
      'exec ${_herdr(pane.session, 'pane process-info --pane '
      '${shellQuote(pane.pane)}')}',
    );
  }

  /// `--wait --until working` makes the exit code say whether the agent took
  /// the text: herdr answers `agent_prompt_stalled` when nothing changed
  /// within its own five-second window.
  static String prompt(PaneRef pane) {
    _requirePane(pane.pane);
    return underSh(
      r'''text=$(cat); [ -n "$text" ] || exit 2; '''
      'exec ${_herdr(pane.session, 'agent prompt ${shellQuote(pane.pane)} '
      '"\$text" --wait --until working '
      '--timeout ${promptStall.inMilliseconds}')}',
    );
  }

  static String workspaceClose(String workspace, {required String session}) =>
      underSh(
        '${_herdr(session, 'workspace close ${shellQuote(workspace)}')} '
        '>/dev/null 2>&1 || true',
      );

  static void _requirePane(String pane) {
    if (!_pane.hasMatch(pane)) throw const HerdrProtocolMismatch();
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
  });

  final String name;
  final bool running;

  /// The session herdr itself falls back to with no `HERDR_SESSION` set.
  final bool isDefault;
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

  /// Both remote streams, for the debug line. Never shown to the user.
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

  /// That line, given the host it happened to. The host's name is a thing this
  /// layer deliberately does not know, so it is handed in.
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
/// The watcher runs a remote polling loop for as long as it lives and reads a
/// blocked pane's tail on the same connection. A second connection per
/// notification would add another SSH handshake for every blocked agent.
class HerdrSession {
  HerdrSession._(this._socket, this._client);

  final SSHSocket _socket;
  final SSHClient _client;

  /// The watch stream: one sweep of every running session per frame, the
  /// first at once and another every two seconds. The loop never exits on its
  /// own, so this stream ends only on a dropped
  /// connection — which is the watcher's signal to back off and reconnect.
  Stream<List<AgentSnapshot>> watch() async* {
    final session = await _guard(() => _client.execute(HerdrCommands.watch()));
    try {
      yield* HerdrClient.parseWatchStream(session.stdout.cast<List<int>>());
    } finally {
      session.close();
    }
  }

  /// The expanded notification body. Null rather than throwing: a tail the
  /// host would not give up is a notification without its extra lines, never a
  /// notification that does not arrive.
  Future<String?> read(PaneRef pane) async {
    try {
      final result = await _guard(
        () => _client.runWithResult(HerdrCommands.read(pane)),
      );
      if (result.exitCode != 0) return null;
      final tail = utf8.decode(result.stdout).trimRight();
      return tail.isEmpty ? null : tail;
    } on HerdrFailure {
      return null;
    }
  }

  /// The notification's `YES` / `NO`. Throws so it can say `FAILED · …` with
  /// what the host answered.
  Future<void> sendKeys(PaneRef pane, List<String> keys) async {
    final result = await _guard(
      () => _client.runWithResult(HerdrCommands.keys(pane, keys)),
    );
    if (result.exitCode != 0) {
      throw HerdrProtocolMismatch(null, utf8.decode(result.output).trim());
    }
  }

  /// Lands [images], creates a workspace, starts one agent, then sends the
  /// prompt on stdin. Any failure after workspace creation closes that
  /// workspace.
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
        final target = HerdrClient.spawnTarget(
          HerdrClient.parseSessions(utf8.decode(roster.stdout)),
        );
        final String name;
        switch (target) {
          case SpawnTargetRefused(:final refusal):
            return SpawnRefused(refusal, utf8.decode(roster.stdout).trim());
          case SpawnTargetSession():
            name = target.name;
        }
        session = name;
        final created = await _guard(
          () => _client.runWithResult(
            HerdrCommands.workspaceCreate(
              directory,
              label: _directoryLabel(directory),
              session: name,
            ),
          ),
        );
        if (created.exitCode == 20) {
          return const SpawnRefused(SpawnRefusal.noDirectory);
        }
        if (created.exitCode != 0) {
          return SpawnRefused(
            SpawnRefusal.spawnFailed,
            utf8.decode(created.output).trim(),
          );
        }
        final PaneRef pane = (
          session: name,
          pane: HerdrClient.parseWorkspacePane(utf8.decode(created.stdout)),
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
        if (started.exitCode != 0 &&
            HerdrClient.parseErrorCode(utf8.decode(started.stderr)) ==
                'agent_not_ready') {
          started = await _acceptTrust(pane, kind) ?? started;
        }
        if (started.exitCode != 0) {
          await _closeWorkspace(made, name);
          return SpawnRefused(
            SpawnRefusal.startFailed,
            utf8.decode(started.output).trim(),
          );
        }
        if (expired) {
          await _closeWorkspace(made, name);
          return const SpawnRefused(SpawnRefusal.timedOut);
        }
        // An agent that has just repainted after its trust dialog is idle to
        // herdr a beat before it reads input, and text sent in that beat is
        // gone without a trace. A stalled prompt is sent again.
        var sent = await _runPrompt(pane, prompt);
        for (var attempt = 1; attempt < promptAttempts && !expired; attempt++) {
          if (sent.exitCode == 0 ||
              !HerdrClient.isPromptStalled(utf8.decode(sent.stderr))) {
            break;
          }
          sent = await _runPrompt(pane, prompt);
        }
        if (sent.exitCode != 0) {
          await _closeWorkspace(made, name);
          return SpawnRefused(
            SpawnRefusal.spawnFailed,
            utf8.decode(sent.output).trim(),
          );
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

  /// `herdr agent start` wants the pane's shell alone at its prompt, and a
  /// shell still sourcing its rc files hands the terminal to every command it
  /// runs. herdr answers `agent_pane_busy` for that instant instead of
  /// waiting, so the start is held until process-info shows the prompt, and a
  /// busy answer inside the settle window is the shell not being there yet.
  Future<SSHRunResult> _startAtPrompt({
    required PaneRef pane,
    required String name,
    required AgentKind kind,
    String? model,
  }) async {
    final settle = Stopwatch()..start();
    while (true) {
      await _awaitPrompt(pane, settle);
      final started = await _guard(
        () => _client.runWithResult(
          HerdrCommands.agentStart(
            pane: pane,
            name: name,
            kind: kind,
            model: model,
          ),
        ),
      );
      if (started.exitCode == 0 ||
          settle.elapsed >= promptSettle ||
          HerdrClient.parseErrorCode(utf8.decode(started.stderr)) !=
              'agent_pane_busy') {
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
      final info = await _guard(
        () => _client.runWithResult(HerdrCommands.processInfo(pane)),
      );
      if (info.exitCode != 0 ||
          HerdrClient.parseShellAtPrompt(utf8.decode(info.stdout))) {
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
  Future<SSHRunResult?> _acceptTrust(PaneRef pane, AgentKind kind) async {
    final screen = await _guard(
      () => _client.runWithResult(HerdrCommands.read(pane, lines: trustLines)),
    );
    if (screen.exitCode != 0) return null;
    final keys = kind.trustKeys(utf8.decode(screen.stdout));
    if (keys == null) return null;
    final answered = await _guard(
      () => _client.runWithResult(HerdrCommands.keys(pane, keys)),
    );
    if (answered.exitCode != 0) return answered;
    return _guard(
      () =>
          _client.runWithResult(HerdrCommands.wait(pane, timeout: trustSettle)),
    );
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

  Future<SSHRunResult> _runPrompt(PaneRef pane, String prompt) =>
      _runWithStdin(HerdrCommands.prompt(pane), utf8.encode(prompt));

  /// `runWithResult` has no way to write stdin, and both the prompt and an
  /// upload are a command whose whole input arrives that way.
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
      await _guard(
        () => _client.runWithResult(
          HerdrCommands.workspaceClose(workspace, session: session),
        ),
      );
    } catch (_) {
      // The primary failure is what the caller reports. Cleanup is best effort.
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

  /// Empty leaves the agent's own default model selected. No session goes on
  /// the line: nothing here talks to a herdr server.
  Future<List<String>> models(AgentKind kind) async {
    final result = await _guard(
      () => _client.runWithResult(HerdrCommands.models(kind)),
    );
    if (result.exitCode != 0) return const [];
    return HerdrClient.parseModels(utf8.decode(result.stdout));
  }

  /// One sweep of every running session.
  Future<List<AgentSnapshot>> list() async {
    final result = await _guard(
      () => _client.runWithResult(HerdrCommands.list()),
    );
    if (result.exitCode != 0) {
      // What the remote said, both streams, is the debug line.
      throw HerdrProtocolMismatch(null, utf8.decode(result.output).trim());
    }
    return HerdrClient.parseSweepOutput(utf8.decode(result.stdout));
  }

  void close() {
    _client.close();
    _socket.close();
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
/// read comes back as `agent_prompt_stalled` and not as a bare timeout.
const promptStall = Duration(seconds: 6);

const promptAttempts = 3;

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

  /// Dart words a name that did not resolve in the exception's
  /// own message; the errno underneath is from the EAI_* namespace, which
  /// cannot be told apart from a connect errno by number alone. Matched on the
  /// message for that reason, over both halves because which one carries the
  /// words depends on the platform.
  static bool isLookupFailure(SocketException error) {
    final said = '${error.message} ${error.osError?.message ?? ''}'
        .toLowerCase();
    return said.contains('failed host lookup') ||
        said.contains('name or service not known') ||
        said.contains('nodename nor servname') ||
        said.contains('no address associated with hostname');
  }

  /// The watch stream, decoded: one sweep frame per snapshot.
  ///
  /// Separate from [HerdrSession.watch] so the shape the gate emits can be run
  /// through the real code without an ssh connection to emit it.
  static Stream<List<AgentSnapshot>> parseWatchStream(Stream<List<int>> bytes) {
    final lines = bytes
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        // A connection that drops mid-watch raises the same [SSHError] shapes
        // as one that never opened, and the watcher's reason line is written
        // from a [HerdrFailure]. Mapped on the stream rather than around the
        // parse, which would leave the parse errors and the transport errors on
        // two different paths.
        .handleError((Object error) => throw asHerdrFailure(error) ?? error);
    return _frames(lines);
  }

  /// A frame is the session lines up to the roster line that closes it. The
  /// roster is the one line of the sweep that is a JSON document on its own,
  /// so it is told apart by its first character and not by counting.
  static Stream<List<AgentSnapshot>> _frames(Stream<String> lines) async* {
    final answers = <String, String>{};
    await for (final line in lines) {
      final frame = _feed(answers, line);
      if (frame != null) yield frame;
    }
  }

  /// One sweep's whole output, for the one-shot list: the frame the watch
  /// reads, read once. Output with no roster line in it is not a frame.
  static List<AgentSnapshot> parseSweepOutput(String source) {
    final answers = <String, String>{};
    for (final line in const LineSplitter().convert(source)) {
      final frame = _feed(answers, line);
      if (frame != null) return frame;
    }
    throw HerdrProtocolMismatch(null, source.trim());
  }

  /// The frame [line] closes, or null while one is still being gathered into
  /// [answers], which is emptied when it closes.
  static List<AgentSnapshot>? _feed(Map<String, String> answers, String line) {
    if (line.trim().isEmpty) return null;
    if (line.startsWith('{')) {
      final frame = parseSweep(answers, line);
      answers.clear();
      return frame;
    }
    final tab = line.indexOf('\t');
    if (tab < 0) throw const HerdrProtocolMismatch();
    answers[line.substring(0, tab)] = line.substring(tab + 1);
    return null;
  }

  static String parseWorkspacePane(String source) {
    Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      throw const HerdrProtocolMismatch();
    }
    if (decoded is! Map<String, Object?>) {
      throw const HerdrProtocolMismatch();
    }
    final result = decoded['result'];
    final root = result is Map<String, Object?> ? result['root_pane'] : null;
    final pane = root is Map<String, Object?> ? root['pane_id'] : null;
    if (pane is! String) throw const HerdrProtocolMismatch();
    HerdrCommands._requirePane(pane);
    return pane;
  }

  /// Whether the pane's shell holds the terminal alone: it owns the foreground
  /// process group and is that group's only member. This is the state
  /// `herdr agent start` requires. A reply that does not show a process group
  /// cannot be waited on, so it counts as ready and the start speaks for
  /// itself. Not a mismatch: throwing past spawn would leak the workspace.
  static bool parseShellAtPrompt(String source) {
    Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      return true;
    }
    final result = decoded is Map<String, Object?> ? decoded['result'] : null;
    final info = result is Map<String, Object?> ? result['process_info'] : null;
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

  /// Whether a failed `agent prompt --wait` means the text was never read:
  /// herdr saw no state change inside its stall window, or the shorter
  /// `--timeout` fired first. Anything else is the agent refusing the prompt.
  static bool isPromptStalled(String stderr) =>
      switch (parseErrorCode(stderr)) {
        'agent_prompt_stalled' || 'timeout' => true,
        _ => false,
      };

  /// The `error.code` of a failed herdr response, or null for anything else.
  static String? parseErrorCode(String source) {
    Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      return null;
    }
    final error = decoded is Map<String, Object?> ? decoded['error'] : null;
    final code = error is Map<String, Object?> ? error['code'] : null;
    return code is String ? code : null;
  }

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

  /// One session's `herdr agent list` document, every agent in it stamped
  /// with [session]: the document itself does not say which server answered,
  /// and nothing above this layer may reach a pane without knowing.
  static List<AgentSnapshot> parseAgentList(
    String source, {
    required String session,
  }) {
    Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      throw const HerdrProtocolMismatch();
    }
    if (decoded is! Map<String, Object?>) {
      throw const HerdrProtocolMismatch();
    }
    final result = decoded['result'];
    if (decoded['id'] != 'cli:agent:list' ||
        result is! Map<String, Object?> ||
        result['type'] != 'agent_list') {
      throw HerdrProtocolMismatch(_protocolFrom(decoded, result));
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
  /// the app would put on a command line is left out rather than refused: the
  /// sweep never asked it either.
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
      if (name is! String || running is! bool || isDefault is! bool) {
        throw const HerdrProtocolMismatch();
      }
      if (!HerdrCommands.isSessionName(name)) continue;
      entries.add(
        SessionEntry(name: name, running: running, isDefault: isDefault),
      );
    }
    return entries;
  }

  /// One sweep, decoded: the per-session answers in the order they were
  /// printed, and the roster that closed the frame.
  ///
  /// A session that stopped between the roster and its own turn answers
  /// `server_not_running` and is skipped. A session the roster calls running
  /// that printed no line is the host's `session list` no longer reading the
  /// way the sweep reads it, which is a mismatch and not an empty panel.
  static List<AgentSnapshot> parseSweep(
    Map<String, String> answers,
    String roster,
  ) {
    for (final session in parseSessions(roster)) {
      if (session.running && !answers.containsKey(session.name)) {
        throw HerdrProtocolMismatch(null, 'no answer from ${session.name}');
      }
    }
    return [
      for (final MapEntry(key: session, value: answer) in answers.entries)
        if (parseErrorCode(answer) != 'server_not_running')
          ...parseAgentList(answer, session: session),
    ];
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

  static int? _protocolFrom(Map<String, Object?> root, Object? result) {
    final rootProtocol = root['protocol'];
    if (rootProtocol is int) return rootProtocol;
    if (result is Map<String, Object?> && result['protocol'] is int) {
      return result['protocol'] as int;
    }
    return null;
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

/// Every ssh error this app can meet, mapped onto the four reason lines.
///
/// Shared by the one-shot fetch and by every command on a held session: a
/// session that drops mid-`watch` fails with the same [SSHError] shapes as one
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
