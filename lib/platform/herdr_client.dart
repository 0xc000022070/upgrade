import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'host_keys.dart';
import 'shell/remote_shell.dart';

class AgentSnapshot {
  const AgentSnapshot({
    required this.paneId,
    required this.agent,
    required this.agentStatus,
    required this.terminalTitleStripped,
    required this.workspaceId,
    required this.cwd,
    required this.stateChangeSeq,
  });

  final String paneId;
  final String agent;
  final String agentStatus;
  final String terminalTitleStripped;
  final String workspaceId;
  final String cwd;
  final int stateChangeSeq;

  /// The blocked edge is a question about this one field, asked often enough
  /// to be worth a name.
  bool get blocked => agentStatus == 'blocked';

  /// The seven fields the watcher's projection consumes, so a
  /// snapshot survives the hop from the watcher's isolate to the UI's without a
  /// second shape to keep in step.
  Map<String, Object?> toJson() => {
    'pane_id': paneId,
    'agent': agent,
    'agent_status': agentStatus,
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
      paneId: field<String>('pane_id'),
      agent: field<String>('agent'),
      agentStatus: field<String>('agent_status'),
      terminalTitleStripped: field<String>('terminal_title_stripped'),
      workspaceId: field<String>('workspace_id'),
      cwd: field<String>('cwd'),
      stateChangeSeq: field<int>('state_change_seq'),
    );
  }
}

abstract final class HerdrCommands {
  static const defaultSession = 'hub';

  static final _pane = RegExp(r'^[A-Za-z0-9]+:[A-Za-z0-9]+$');
  static final _key = RegExp(r'^(enter|esc|up|down|tab|[A-Za-z0-9])$');
  static final _model = RegExp(r'^[a-z0-9][a-z0-9._:-]{0,63}$');

  static String _env(String session) =>
      'env HERDR_SESSION=${shellQuote(session)}';

  static String _herdr(String session, String arguments) =>
      '${_env(session)} herdr $arguments';

  static String list([String session = defaultSession]) =>
      underSh('exec ${_herdr(session, 'agent list')}');

  static String watch([String session = defaultSession]) => underSh(
    'while :; do ${_herdr(session, 'agent list')} || exit; sleep 2; done',
  );

  static String paths() => underSh(r'''
for root in "$HOME/Projects" "$HOME/.dotfiles" "$HOME/src"; do
  [ -d "$root" ] || continue
  find "$root" -name .git -prune -print 2>/dev/null
done | sed "s|/.git$||; s|^$HOME|~|" | sort -u | head -300
''');

  static String models(String kind, [String session = defaultSession]) =>
      switch (kind) {
        'codex' => underSh(
          'exec ${_env(session)} codex debug models --bundled',
        ),
        'claude' => underSh(r'''printf '%s\n' '["opus","sonnet","fable"]' '''),
        _ => throw ArgumentError.value(kind, 'kind'),
      };

  static String read(String pane, [String session = defaultSession]) {
    _requirePane(pane);
    return underSh(
      'exec ${_herdr(session, 'agent read ${shellQuote(pane)} '
      '--source visible --lines 8 --format text')}',
    );
  }

  static String keys(
    String pane,
    List<String> keys, [
    String session = defaultSession,
  ]) {
    _requirePane(pane);
    if (keys.isEmpty || keys.any((key) => !_key.hasMatch(key))) {
      throw const HerdrProtocolMismatch(null, 'invalid key');
    }
    final arguments = keys.map(shellQuote).join(' ');
    return underSh(
      'exec ${_herdr(session, 'agent send-keys ${shellQuote(pane)} $arguments')}',
    );
  }

  static String workspaceCreate(
    String directory, {
    required String label,
    String session = defaultSession,
  }) => underSh(
    'dir=${shellQuote(directory)}; '
    r'''case "$dir" in '~') dir="$HOME";; '~/'*) dir="$HOME/${dir#'~/'}";; esac; '''
    r'''[ -d "$dir" ] || { printf '%s\n' 'spectacle: no directory' >&2; exit 20; }; '''
    '${_herdr(session, 'workspace create --cwd "\$dir" '
    '--label ${shellQuote(label)} --no-focus')}',
  );

  static String agentStart({
    required String pane,
    required String name,
    required String kind,
    String? model,
    String session = defaultSession,
  }) {
    _requirePane(pane);
    if (kind != 'claude' && kind != 'codex') {
      throw ArgumentError.value(kind, 'kind');
    }
    if (model != null && !_model.hasMatch(model)) {
      throw ArgumentError.value(model, 'model');
    }
    final flags = kind == 'claude'
        ? <String>[
            '--settings',
            '{"skipDangerousModePermissionPrompt":true}',
            '--dangerously-skip-permissions',
          ]
        : <String>['--yolo'];
    if (model != null) flags.addAll(['--model', model]);
    final arguments = [
      'agent',
      'start',
      name,
      '--kind',
      kind,
      '--pane',
      pane,
      '--',
      ...flags,
    ].map(shellQuote).join(' ');
    return underSh('exec ${_herdr(session, arguments)}');
  }

  static String processInfo(String pane, [String session = defaultSession]) {
    _requirePane(pane);
    return underSh(
      'exec ${_herdr(session, 'pane process-info --pane ${shellQuote(pane)}')}',
    );
  }

  static String prompt(String pane, [String session = defaultSession]) {
    _requirePane(pane);
    return underSh(
      r'''text=$(cat); [ -n "$text" ] || exit 2; '''
      'exec ${_herdr(session, 'agent prompt ${shellQuote(pane)} "\$text"')}',
    );
  }

  static String workspaceClose(
    String workspace, [
    String session = defaultSession,
  ]) => underSh(
    '${_herdr(session, 'workspace close ${shellQuote(workspace)}')} '
    '>/dev/null 2>&1 || true',
  );

  static void _requirePane(String pane) {
    if (!_pane.hasMatch(pane)) throw const HerdrProtocolMismatch();
  }
}

/// A refused spawn is data rather than an exception: the connection worked,
/// but one step of the remote transaction did not.
enum SpawnRefusal { noDirectory, startFailed, spawnFailed, timedOut }

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

  @override
  String toString() => '$runtimeType(${detail ?? ''})';
}

final class HerdrUnreachable extends HerdrFailure {
  const HerdrUnreachable([super.detail]);
}

/// The name never resolved, so no socket was ever opened. Separate from
/// [HerdrUnreachable] because the two send the user to different places: a typo
/// in the address, against a port, a firewall or a dead machine.
final class HerdrUnresolved extends HerdrFailure {
  const HerdrUnresolved([super.detail]);
}

final class HerdrKeyRejected extends HerdrFailure {
  const HerdrKeyRejected([super.detail]);
}

/// Nothing is pinned for this host, and nothing on this path may ask: the
/// poll, the watcher and the send all run with nobody looking at them.
final class HerdrHostKeyUnverified extends HerdrFailure {
  const HerdrHostKeyUnverified([super.detail]);
}

/// The machine presented a key that is not the one pinned for it.
final class HerdrHostKeyChanged extends HerdrFailure {
  const HerdrHostKeyChanged([super.detail]);
}

final class HerdrProtocolMismatch extends HerdrFailure {
  const HerdrProtocolMismatch([this.protocol, super.detail]);

  final int? protocol;
}

/// One authenticated connection to a host, held open.
///
/// The watcher runs a remote polling loop for as long as it lives and reads a
/// blocked pane's tail on the same connection. A second connection per
/// notification would add another SSH handshake for every blocked agent.
class HerdrSession {
  HerdrSession._(this._socket, this._client, this._sessionName);

  final SSHSocket _socket;
  final SSHClient _client;
  final String _sessionName;

  /// The watch stream: one `herdr agent list` JSON document per line, the
  /// first at once and another every two seconds. The loop never exits on its
  /// own, so this stream ends only on a dropped
  /// connection — which is the watcher's signal to back off and reconnect.
  Stream<List<AgentSnapshot>> watch() async* {
    final session = await _guard(
      () => _client.execute(HerdrCommands.watch(_sessionName)),
    );
    try {
      yield* HerdrClient.parseWatchStream(session.stdout.cast<List<int>>());
    } finally {
      session.close();
    }
  }

  /// The expanded notification body. Null rather than throwing: a tail the
  /// host would not give up is a notification without its extra lines, never a
  /// notification that does not arrive.
  Future<String?> read(String pane) async {
    try {
      final result = await _guard(
        () => _client.runWithResult(HerdrCommands.read(pane, _sessionName)),
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
  Future<void> sendKeys(String pane, List<String> keys) async {
    final result = await _guard(
      () => _client.runWithResult(HerdrCommands.keys(pane, keys, _sessionName)),
    );
    if (result.exitCode != 0) {
      throw HerdrProtocolMismatch(null, utf8.decode(result.output).trim());
    }
  }

  /// Creates a workspace, starts one agent, then sends the prompt on stdin.
  /// Any failure after workspace creation closes that workspace.
  Future<SpawnResult> spawn({
    required String kind,
    required String directory,
    required String prompt,
    String? model,
    Duration deadline = spawnDeadline,
  }) async {
    String? workspace;
    var expired = false;
    try {
      return await (() async {
        final created = await _guard(
          () => _client.runWithResult(
            HerdrCommands.workspaceCreate(
              directory,
              label: _directoryLabel(directory),
              session: _sessionName,
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
        final pane = HerdrClient.parseWorkspacePane(
          utf8.decode(created.stdout),
        );
        workspace = pane.split(':').first;
        if (expired) {
          await _closeWorkspace(workspace!);
          return const SpawnRefused(SpawnRefusal.timedOut);
        }
        final started = await _startAtPrompt(
          pane: pane,
          name: _agentName(_directoryLabel(directory), workspace!),
          kind: kind,
          model: model,
        );
        if (started.exitCode != 0) {
          await _closeWorkspace(workspace!);
          return SpawnRefused(
            SpawnRefusal.startFailed,
            utf8.decode(started.output).trim(),
          );
        }
        if (expired) {
          await _closeWorkspace(workspace!);
          return const SpawnRefused(SpawnRefusal.timedOut);
        }
        final sent = await _runPrompt(pane, prompt);
        if (sent.exitCode != 0) {
          await _closeWorkspace(workspace!);
          return SpawnRefused(
            SpawnRefusal.spawnFailed,
            utf8.decode(sent.output).trim(),
          );
        }
        return SpawnSent(pane);
      })().timeout(deadline);
    } on TimeoutException {
      expired = true;
      final made = workspace;
      if (made != null) await _closeWorkspace(made);
      return const SpawnRefused(SpawnRefusal.timedOut);
    }
  }

  /// `herdr agent start` wants the pane's shell alone at its prompt, and a
  /// shell still sourcing its rc files hands the terminal to every command it
  /// runs. herdr answers `agent_pane_busy` for that instant instead of
  /// waiting, so the start is held until process-info shows the prompt, and a
  /// busy answer inside the settle window is the shell not being there yet.
  Future<SSHRunResult> _startAtPrompt({
    required String pane,
    required String name,
    required String kind,
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
            session: _sessionName,
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
  Future<void> _awaitPrompt(String pane, Stopwatch settle) async {
    while (settle.elapsed < promptSettle) {
      final info = await _guard(
        () => _client.runWithResult(
          HerdrCommands.processInfo(pane, _sessionName),
        ),
      );
      if (info.exitCode != 0 ||
          HerdrClient.parseShellAtPrompt(utf8.decode(info.stdout))) {
        return;
      }
      await Future<void>.delayed(promptPoll);
    }
  }

  Future<SSHRunResult> _runPrompt(String pane, String prompt) async {
    final session = await _guard(
      () => _client.execute(HerdrCommands.prompt(pane, _sessionName)),
    );
    final out = BytesBuilder(copy: false);
    final err = BytesBuilder(copy: false);
    final drained = Future.wait([
      session.stdout.cast<List<int>>().forEach(out.add),
      session.stderr.cast<List<int>>().forEach(err.add),
    ]);
    session.stdin.add(utf8.encode(prompt));
    await session.stdin.close();
    await Future.wait([session.done, drained]);
    session.close();
    final stdout = out.takeBytes();
    final stderr = err.takeBytes();
    return SSHRunResult(
      output: Uint8List.fromList([...stdout, ...stderr]),
      exitCode: session.exitCode,
      exitSignal: session.exitSignal,
      stdout: stdout,
      stderr: stderr,
    );
  }

  Future<void> _closeWorkspace(String workspace) async {
    try {
      await _guard(
        () => _client.runWithResult(
          HerdrCommands.workspaceClose(workspace, _sessionName),
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

  /// Empty leaves the agent's own default model selected.
  Future<List<String>> models(String kind) async {
    final result = await _guard(
      () => _client.runWithResult(HerdrCommands.models(kind, _sessionName)),
    );
    if (result.exitCode != 0) return const [];
    return HerdrClient.parseModels(utf8.decode(result.stdout));
  }

  Future<List<AgentSnapshot>> list() async {
    final result = await _guard(
      () => _client.runWithResult(HerdrCommands.list(_sessionName)),
    );
    if (result.exitCode != 0) {
      // What the remote said, both streams, is the debug line.
      throw HerdrProtocolMismatch(null, utf8.decode(result.output).trim());
    }
    return HerdrClient.parseAgentList(utf8.decode(result.stdout));
  }

  void close() {
    _client.close();
    _socket.close();
  }
}

/// How long a send waits for workspace creation, agent startup, and the prompt.
const spawnDeadline = Duration(seconds: 45);

/// How long a fresh pane's shell may take to reach its prompt. A login shell
/// on this kind of host is there in well under a second; the window is for
/// slow disks and rc files that call out to the network.
const promptSettle = Duration(seconds: 10);

const promptPoll = Duration(milliseconds: 100);

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
    this.sessionName = HerdrCommands.defaultSession,
  });

  final Duration timeout;

  /// Keepalive every 15 s. dartssh2 defaults to 10; the number is a decision,
  /// so it is declared rather than inherited.
  final Duration keepAlive;
  final String sessionName;

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

  /// The watch stream, decoded: one `herdr agent list` document per line.
  ///
  /// Separate from [HerdrSession.watch] so the shape the gate emits can be run
  /// through the real code without an ssh connection to emit it.
  static Stream<List<AgentSnapshot>> parseWatchStream(Stream<List<int>> bytes) {
    return bytes
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        // A connection that drops mid-watch raises the same [SSHError] shapes
        // as one that never opened, and the watcher's reason line is written
        // from a [HerdrFailure]. Mapped on the stream rather than around the
        // parse, which would leave the parse errors and the transport errors on
        // two different paths.
        .handleError((Object error) => throw asHerdrFailure(error) ?? error)
        .where((line) => line.trim().isNotEmpty)
        .map(parseAgentList);
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

  static List<AgentSnapshot> parseAgentList(String source) {
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
          AgentSnapshot.fromJson(agent)
        else
          throw const HerdrProtocolMismatch(),
    ];
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
      return HerdrSession._(socket, client, sessionName);
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
    required String kind,
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
    required String kind,
    required String directory,
    required String prompt,
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
