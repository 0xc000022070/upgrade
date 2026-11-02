import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';

import 'package:upgrade/application/agents/reason_lines.dart';
import 'package:upgrade/platform/herdr/herdr_socket.dart';
import 'package:upgrade/platform/ssh/host_keys.dart';

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

final class HerdrBusy extends HerdrFailure {
  const HerdrBusy([super.detail]);

  @override
  ReasonLine get line => ReasonLine.hostBusy;
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

/// Dart words a name that did not resolve in the exception's own message; the errno
/// underneath is from the EAI_* namespace, which cannot be told apart from a connect
/// errno by number alone. Matched over both halves because which one carries the words
/// depends on the platform.
bool _isLookupFailure(SocketException error) {
  final said = '${error.message} ${error.osError?.message ?? ''}'.toLowerCase();
  return said.contains('failed host lookup') ||
      said.contains('name or service not known') ||
      said.contains('nodename nor servname') ||
      said.contains('no address associated with hostname');
}

enum HostFailureKind {
  unresolved,
  unreachable,
  keyRejected,

  /// sshd answered but would not open the channel, or the pty or shell request on it.
  refused,

  streamClosed,
  hostKeyUnverified,
  hostKeyChanged,
}

HostFailureKind? classifyHostFailure(
  Object error, [
  HostKeyRefusal? refusal,
]) => switch (error) {
  // The verifier's answer is the reason, whatever error the closing handshake surfaced.
  _ when refusal != null => switch (refusal) {
    HostKeyRefusal.unverified => HostFailureKind.hostKeyUnverified,
    HostKeyRefusal.changed => HostFailureKind.hostKeyChanged,
  },
  SSHHostkeyError() => HostFailureKind.hostKeyChanged,
  SSHChannelOpenError() || SSHChannelRequestError() => HostFailureKind.refused,
  SSHAuthFailError() || SSHKeyDecodeError() => HostFailureKind.keyRejected,
  SSHAuthAbortError(:final reason?) =>
    classifyHostFailure(reason) ?? HostFailureKind.streamClosed,
  SSHAuthAbortError() || SSHStateError() => HostFailureKind.streamClosed,
  SSHSocketError() =>
    classifyHostFailure(error.error) ?? HostFailureKind.unreachable,
  SocketException() when _isLookupFailure(error) => HostFailureKind.unresolved,
  SocketException() ||
  TimeoutException() ||
  SSHError() => HostFailureKind.unreachable,
  _ => null,
};

HerdrFailure? asHerdrFailure(Object error, [HostKeyRefusal? refusal]) =>
    switch (error) {
      HerdrFailure() => error,
      HerdrMalformed() when refusal == null => HerdrProtocolMismatch(
        error.protocol,
        '$error',
      ),
      _ => switch (classifyHostFailure(error, refusal)) {
        null => null,
        HostFailureKind.unresolved => HerdrUnresolved('$error'),
        HostFailureKind.keyRejected => HerdrKeyRejected('$error'),
        HostFailureKind.hostKeyUnverified => HerdrHostKeyUnverified('$error'),
        HostFailureKind.hostKeyChanged => HerdrHostKeyChanged('$error'),
        HostFailureKind.unreachable ||
        HostFailureKind.refused ||
        HostFailureKind.streamClosed => HerdrUnreachable('$error'),
      },
    };

Future<T> guardHerdr<T>(
  Future<T> Function() body, [
  HostKeyVerifier? verifier,
]) async {
  try {
    return await body();
  } catch (error) {
    throw asHerdrFailure(error, verifier?.refusal) ?? error;
  }
}
