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

sealed class HerdrFailure implements Exception {
  const HerdrFailure();
}

final class HerdrUnreachable extends HerdrFailure {
  const HerdrUnreachable();
}

final class HerdrKeyRejected extends HerdrFailure {
  const HerdrKeyRejected();
}

final class HerdrProtocolMismatch extends HerdrFailure {
  const HerdrProtocolMismatch([this.protocol]);

  final int? protocol;
}

class HerdrClient {
  const HerdrClient({
    this.port = 22,
    this.timeout = const Duration(seconds: 10),
  });

  final int port;
  final Duration timeout;

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

  Future<List<AgentSnapshot>> fetch({
    required String address,
    required String user,
    required String privateKey,
  }) async {
    SSHSocket? socket;
    SSHClient? client;
    try {
      socket = await SSHSocket.connect(address, port, timeout: timeout);
      client = SSHClient(
        socket,
        username: user,
        identities: SSHKeyPair.fromPem(privateKey),
        handshakeTimeout: timeout,
        authTimeout: timeout,
      );
      await client.authenticated;
      final result = await client.runWithResult('herdr agent list');
      if (result.exitCode != 0) throw const HerdrProtocolMismatch();
      return parseAgentList(utf8.decode(result.stdout));
    } on SSHAuthFailError {
      throw const HerdrKeyRejected();
    } on HerdrFailure {
      rethrow;
    } on SocketException {
      throw const HerdrUnreachable();
    } on TimeoutException {
      throw const HerdrUnreachable();
    } on SSHAuthAbortError {
      throw const HerdrUnreachable();
    } on SSHHandshakeError {
      throw const HerdrUnreachable();
    } on SSHKeyDecodeError {
      throw const HerdrKeyRejected();
    } on SSHError {
      throw const HerdrUnreachable();
    } finally {
      client?.close();
      socket?.close();
    }
  }
}
