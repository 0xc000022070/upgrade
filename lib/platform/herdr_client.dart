import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';

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

  /// SPEC.md §39.31's blocked edge is a question about this one field, asked
  /// often enough to be worth a name.
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

/// SPEC.md §39.31: the four strings the `hotline-gate` forced command accepts,
/// in one place. The gate denies anything else, so a command built anywhere but
/// here is a bug that only shows up against a real host.
class HerdrCommands {
  /// §39.31 switches the app to the short form. The gate still accepts
  /// §39.20's `herdr agent list`, which is what keeps a v20 build working.
  static const list = 'agent list';
  static const watch = 'agent watch';

  static String read(String pane) => 'agent read $pane';

  static String keys(String pane, List<String> keys) =>
      'agent keys $pane ${keys.join(' ')}';
}

sealed class HerdrFailure implements Exception {
  const HerdrFailure([this.detail]);

  /// SPEC.md §39.29: what the transport actually said. Carried out of here
  /// rather than logged here, because the debug line the spec asks for names
  /// the host — and the host's name is a thing this layer deliberately does not
  /// know. The caller has both halves.
  final String? detail;

  @override
  String toString() => '$runtimeType(${detail ?? ''})';
}

final class HerdrUnreachable extends HerdrFailure {
  const HerdrUnreachable([super.detail]);
}

/// SPEC.md §39.29. The name never resolved, so no socket was ever opened.
/// Separate from [HerdrUnreachable] because the two send the user to different
/// places: a typo in the address, against a port, a firewall or a dead machine.
final class HerdrUnresolved extends HerdrFailure {
  const HerdrUnresolved([super.detail]);
}

final class HerdrKeyRejected extends HerdrFailure {
  const HerdrKeyRejected([super.detail]);
}

final class HerdrProtocolMismatch extends HerdrFailure {
  const HerdrProtocolMismatch([this.protocol, super.detail]);

  final int? protocol;
}

/// One authenticated connection to a host, held open.
///
/// SPEC.md §39.31 runs `agent watch` for as long as the watcher lives and reads
/// a blocked pane's tail "on the same connection", so the session is the unit
/// rather than the command: a second connect per notification would be a second
/// ssh handshake per blocked agent, and the spec's own reason for the watcher is
/// that the host sees one connection per phone.
class HerdrSession {
  HerdrSession._(this._socket, this._client);

  final SSHSocket _socket;
  final SSHClient _client;

  /// §39.31's watch stream: one `herdr agent list` JSON document per line, the
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

  /// §39.31's expanded notification body. Null rather than throwing: a tail the
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

  /// §39.31's `YES` / `NO`. Throws so the notification can say `FAILED · …`
  /// with what the gate answered.
  Future<void> sendKeys(String pane, List<String> keys) async {
    final result = await _guard(
      () => _client.runWithResult(HerdrCommands.keys(pane, keys)),
    );
    if (result.exitCode != 0) {
      throw HerdrProtocolMismatch(null, utf8.decode(result.output).trim());
    }
  }

  Future<List<AgentSnapshot>> list() async {
    final result = await _guard(
      () => _client.runWithResult(HerdrCommands.list),
    );
    if (result.exitCode != 0) {
      // §39.29: what the remote said, both streams, is the debug line.
      throw HerdrProtocolMismatch(null, utf8.decode(result.output).trim());
    }
    return HerdrClient.parseAgentList(utf8.decode(result.stdout));
  }

  void close() {
    _client.close();
    _socket.close();
  }
}

class HerdrClient {
  const HerdrClient({
    this.timeout = const Duration(seconds: 10),
    this.keepAlive = const Duration(seconds: 15),
  });

  final Duration timeout;

  /// SPEC.md §39.31: "keepalive every 15 s". dartssh2 defaults to 10; the
  /// number is the spec's, so it is declared rather than inherited.
  final Duration keepAlive;

  /// SPEC.md §39.29. Dart words a name that did not resolve in the exception's
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

  /// §39.31's watch stream, decoded: one `herdr agent list` document per line.
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
  }) async {
    final socket = await _guard(
      () => SSHSocket.connect(address, port, timeout: timeout),
    );
    final client = SSHClient(
      socket,
      username: user,
      identities: SSHKeyPair.fromPem(privateKey),
      handshakeTimeout: timeout,
      authTimeout: timeout,
      keepAliveInterval: keepAlive,
    );
    try {
      await _guard(() => client.authenticated);
      return HerdrSession._(socket, client);
    } on HerdrFailure {
      // A half-open connection is worse than none: the host would count it
      // against §39.31's one connection per phone until its own timeout.
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
  }) async {
    final session = await connect(
      address: address,
      port: port,
      user: user,
      privateKey: privateKey,
    );
    try {
      return await session.list();
    } finally {
      session.close();
    }
  }
}

/// Every ssh error this app can meet, mapped onto §39.20's four reason lines.
///
/// Shared by the one-shot fetch and by every command on a held session: a
/// session that drops mid-`watch` fails with the same [SSHError] shapes as one
/// that never connected, and §39.31 asks the watcher to say why in §39.29's
/// words.
/// Null for anything this app did not expect from ssh: a bug in the layer above
/// reads better as itself than as `nyx unreachable`.
HerdrFailure? asHerdrFailure(Object error) => switch (error) {
  HerdrFailure() => error,
  SSHAuthFailError() => HerdrKeyRejected('$error'),
  SSHKeyDecodeError() => HerdrKeyRejected('$error'),
  // §39.29: the only failure that happens before an address exists.
  SocketException() when HerdrClient.isLookupFailure(error) => HerdrUnresolved(
    '$error',
  ),
  SocketException() => HerdrUnreachable('$error'),
  TimeoutException() => HerdrUnreachable('$error'),
  SSHError() => HerdrUnreachable('$error'),
  _ => null,
};

Future<T> _guard<T>(Future<T> Function() body) async {
  try {
    return await body();
  } catch (error) {
    throw asHerdrFailure(error) ?? error;
  }
}
