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
  const HerdrFailure([this.detail]);

  /// SPEC.md §39.29: what the transport actually said. Carried out of here
  /// rather than logged here, because the debug line the spec asks for names
  /// the host — and the host's name is a thing this layer deliberately does not
  /// know. The caller has both halves.
  final String? detail;
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

class HerdrClient {
  const HerdrClient({this.timeout = const Duration(seconds: 10)});

  final Duration timeout;

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
    required int port,
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
      if (result.exitCode != 0) {
        // §39.29: what the remote said, both streams, is the debug line.
        throw HerdrProtocolMismatch(null, utf8.decode(result.output).trim());
      }
      return parseAgentList(utf8.decode(result.stdout));
    } on SSHAuthFailError catch (error) {
      throw HerdrKeyRejected('$error');
    } on HerdrFailure {
      rethrow;
    } on SocketException catch (error) {
      // §39.29: the only failure that happens before an address exists.
      throw isLookupFailure(error)
          ? HerdrUnresolved('$error')
          : HerdrUnreachable('$error');
    } on TimeoutException catch (error) {
      throw HerdrUnreachable('$error');
    } on SSHAuthAbortError catch (error) {
      throw HerdrUnreachable('$error');
    } on SSHHandshakeError catch (error) {
      throw HerdrUnreachable('$error');
    } on SSHKeyDecodeError catch (error) {
      throw HerdrKeyRejected('$error');
    } on SSHError catch (error) {
      throw HerdrUnreachable('$error');
    } finally {
      client?.close();
      socket?.close();
    }
  }
}
