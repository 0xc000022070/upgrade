import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';

import '../herdr_client.dart';
import '../host_keys.dart';

/// What one command on a workspace came back with.
class WorkspaceReply {
  const WorkspaceReply({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int? exitCode;
  final String stdout;
  final String stderr;

  bool get ok => exitCode == 0;
}

/// The seam the workspace screens are driven through. A test hands the store
/// its own function and never opens a socket; the real one is [WorkspaceSsh].
abstract interface class WorkspaceRunner {
  /// Runs one command and answers with what it printed. The connection is the
  /// implementation's business: the caller asks in round trips, not in
  /// sessions.
  Future<WorkspaceReply> run(String command);

  Future<void> close();
}

/// One ssh connection, held open for as long as a workspace is on screen.
///
/// Held, not reopened: a handshake is the expensive part of asking a machine
/// anything, and every tap on this screen — a file's hunks, a directory's
/// entries — is one command on a connection that already exists. The screen
/// closes it on the way out.
class WorkspaceSsh implements WorkspaceRunner {
  WorkspaceSsh._(this._socket, this._client);

  static const timeout = Duration(seconds: 10);
  static const keepAlive = Duration(seconds: 20);

  final SSHSocket _socket;
  final SSHClient _client;
  var _closed = false;

  static Future<WorkspaceSsh> open({
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
      return WorkspaceSsh._(socket, client);
    } on HerdrFailure {
      // Half-open costs the host a connection until its own timeout, and the
      // phone has one of these per workspace it opens.
      client.close();
      socket.close();
      rethrow;
    }
  }

  @override
  Future<WorkspaceReply> run(String command) async {
    final result = await _guard(() => _client.runWithResult(command));
    return WorkspaceReply(
      exitCode: result.exitCode,
      stdout: utf8.decode(result.stdout, allowMalformed: true),
      stderr: utf8.decode(result.stderr, allowMalformed: true),
    );
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _client.close();
    _socket.close();
  }
}

Future<T> _guard<T>(
  Future<T> Function() body, [
  HostKeyVerifier? verifier,
]) async {
  try {
    return await body();
  } catch (error) {
    // The ssh failures are ssh failures whoever asked: the same four reason
    // lines the agent list and the path scan already word.
    throw asHerdrFailure(error, verifier?.refusal) ?? error;
  }
}
