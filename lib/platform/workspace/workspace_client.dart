import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';

import '../herdr_client.dart';
import '../host_keys.dart';
import '../ssh_settle.dart';

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

abstract interface class WorkspaceRunner {
  Future<WorkspaceReply> run(String command);

  Future<void> close();
}

/// Held, not reopened: a handshake is the expensive part of asking a machine anything,
/// and every tap on this screen is one command on a connection that already exists.
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
      keepAliveInterval: keepAlive,
      onVerifyHostKey: verifier?.verify,
    );
    try {
      await _guard(() => client.authenticated.timeout(timeout), verifier);
      return WorkspaceSsh._(socket, client);
    } on HerdrFailure {
      // Half-open costs the host a connection until its own timeout, and the phone has one of
      // these per workspace it opens.
      unawaited(closeSettled(client, socket));
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
    // The ssh failures are ssh failures whoever asked.
    throw asHerdrFailure(error, verifier?.refusal) ?? error;
  }
}
