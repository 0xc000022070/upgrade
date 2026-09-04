import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';

import 'host_keys.dart';

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

  /// The same seven fields the gate's `agent watch` projection carries, so a
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

/// Every string the `hotline-gate` forced command accepts, in one place. The
/// gate denies anything else, so a command built anywhere but here is a bug
/// that only shows up against a real host.
class HerdrCommands {
  /// The short form. The gate still accepts the older `herdr agent list`,
  /// which is what keeps an earlier build working.
  static const list = 'agent list';
  static const watch = 'agent watch';

  /// The git checkouts the host will accept a send into, so a path is picked
  /// rather than typed. Read-only, and the gate decides which roots it walks.
  static const paths = 'agent paths';

  /// The slugs [kind] will accept on this host. Asked of the host because that
  /// is where the CLIs are installed, and a list shipped in the app would be a
  /// snapshot of someone else's release notes.
  static String models(String kind) => 'agent models $kind';

  static String read(String pane) => 'agent read $pane';

  static String keys(String pane, List<String> keys) =>
      'agent keys $pane ${keys.join(' ')}';

  /// The send verb. The directory goes through unquoted and unexpanded: the
  /// gate splits on whitespace and expands `~` itself, so a shell quote here
  /// would reach it as part of the path.
  ///
  /// [model] is a slug or `-`, which is the agent's own default. It sits before
  /// the directory because the directory is the rest of the line.
  static String spawn(String kind, String? model, String directory) =>
      'agent spawn $kind ${model ?? '-'} $directory';
}

/// What the gate answered a spawn. A refusal is data rather than an exception:
/// the connection did its job, and the four lines below are the gate's verdict
/// on the command, not a failure of the transport.
enum SpawnRefusal { noDirectory, gateRefused, spawnFailed, timedOut }

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

  /// Both of the gate's streams, for the debug line. Never shown to the user:
  /// the four reasons are what the sheet says.
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
/// The watcher runs `agent watch` for as long as it lives and reads a blocked
/// pane's tail on the same connection, so the session is the unit rather than
/// the command: a second connect per notification would be a second ssh
/// handshake per blocked agent, and the whole point of the watcher is that the
/// host sees one connection per phone.
class HerdrSession {
  HerdrSession._(this._socket, this._client);

  final SSHSocket _socket;
  final SSHClient _client;

  /// The watch stream: one `herdr agent list` JSON document per line, the
  /// first at once and one more each time the host's projection changes. The
  /// gate never exits on its own, so this stream ends only on a dropped
  /// connection — which is the watcher's signal to back off and reconnect.
  Stream<List<AgentSnapshot>> watch() async* {
    final session = await _guard(() => _client.execute(HerdrCommands.watch));
    try {
      yield* HerdrClient.parseWatchStream(session.stdout.cast<List<int>>());
    } finally {
      session.close();
    }
  }

  /// The expanded notification body. Null rather than throwing: a tail the
  /// gate would not give up is a notification without its extra lines, never a
  /// notification that does not arrive.
  Future<String?> read(String pane) async {
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
  /// what the gate answered.
  Future<void> sendKeys(String pane, List<String> keys) async {
    final result = await _guard(
      () => _client.runWithResult(HerdrCommands.keys(pane, keys)),
    );
    if (result.exitCode != 0) {
      throw HerdrProtocolMismatch(null, utf8.decode(result.output).trim());
    }
  }

  /// The send. The prompt goes to the channel's stdin and the stream is closed,
  /// because the gate reads to EOF before it starts anything — a session left
  /// open would hold it at the read forever and burn the caller's deadline.
  ///
  /// [deadline] covers the whole verb, which on the host is a workspace, an
  /// agent start with its own readiness timeout, and a prompt. Nothing is
  /// retried here: a spawn that half happened is a workspace the gate closes
  /// itself, and a second attempt from this side would make two.
  Future<SpawnResult> spawn({
    required String kind,
    required String directory,
    required String prompt,
    String? model,
    Duration deadline = spawnDeadline,
  }) async {
    final session = await _guard(
      () => _client.execute(HerdrCommands.spawn(kind, model, directory)),
    );
    final out = StringBuffer();
    final err = StringBuffer();
    final drained = Future.wait([
      session.stdout
          .cast<List<int>>()
          .transform(utf8.decoder)
          .forEach(out.write),
      session.stderr
          .cast<List<int>>()
          .transform(utf8.decoder)
          .forEach(err.write),
    ]);
    session.stdin.add(utf8.encode(prompt));
    await session.stdin.close();
    try {
      await Future.wait([session.done, drained]).timeout(deadline);
    } on TimeoutException {
      session.close();
      return const SpawnRefused(SpawnRefusal.timedOut);
    }
    return HerdrClient.readSpawn(
      exitCode: session.exitCode,
      stdout: out.toString(),
      stderr: err.toString(),
    );
  }

  /// The host's git checkouts. Empty rather than throwing on a gate that does
  /// not know the verb: an older host still sends, it just cannot offer a list.
  Future<List<String>> paths() async {
    final result = await _guard(
      () => _client.runWithResult(HerdrCommands.paths),
    );
    if (result.exitCode != 0) return const [];
    return HerdrClient.parsePaths(utf8.decode(result.stdout));
  }

  /// Empty for a gate that does not know the verb, same as [paths]: the send
  /// still works, it just goes out on the agent's own default model.
  Future<List<String>> models(String kind) async {
    final result = await _guard(
      () => _client.runWithResult(HerdrCommands.models(kind)),
    );
    if (result.exitCode != 0) return const [];
    return HerdrClient.parsePaths(utf8.decode(result.stdout));
  }

  Future<List<AgentSnapshot>> list() async {
    final result = await _guard(
      () => _client.runWithResult(HerdrCommands.list),
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

/// How long a send waits on the gate. The host's own agent start gives itself
/// 30 s to see the agent come up, and the workspace and the prompt around it
/// are what the rest covers.
const spawnDeadline = Duration(seconds: 45);

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

  /// The gate's answer, read the way the app has to read it.
  ///
  /// Separate from [HerdrSession.spawn] so every branch can be exercised
  /// without a host: exit 0 with a pane line is the only send that happened,
  /// and the three refusals are told apart by what the gate said, not by the
  /// exit code alone.
  static SpawnResult readSpawn({
    required int? exitCode,
    required String stdout,
    required String stderr,
  }) {
    final said = '$stdout$stderr';
    final pane = stdout
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .lastOrNull;
    if (exitCode == 0 && pane != null) return SpawnSent(pane);
    final detail = said.trim().isEmpty ? null : said.trim();
    if (said.contains('denied: dir')) {
      return SpawnRefused(SpawnRefusal.noDirectory, detail);
    }
    if (said.contains('denied')) {
      return SpawnRefused(SpawnRefusal.gateRefused, detail);
    }
    return SpawnRefused(SpawnRefusal.spawnFailed, detail);
  }

  /// The `agent paths` answer: a JSON array of directories, `~`-relative to
  /// the host's home. Malformed output is no paths, not an exception — the
  /// picker degrades to the field it already had.
  static List<String> parsePaths(String source) {
    Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      return const [];
    }
    if (decoded is! List<Object?>) return const [];
    return [
      for (final entry in decoded)
        if (entry is String && entry.isNotEmpty) entry,
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
