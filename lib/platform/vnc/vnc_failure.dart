import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';

import 'package:striked/application/agents/reason_lines.dart';
import 'package:striked/platform/herdr/herdr_client.dart';
import 'package:striked/platform/ssh/host_keys.dart';

sealed class VncFailure implements Exception {
  const VncFailure([this.detail]);

  /// Carried out of here so the caller, which is the half that knows the host's name,
  /// writes the debug line.
  final String? detail;

  ReasonLine get line;

  String reason(String host) => line.on(host);

  @override
  String toString() => '$runtimeType(${detail ?? ''})';
}

final class VncUnreachable extends VncFailure {
  const VncUnreachable([super.detail]);

  @override
  ReasonLine get line => ReasonLine.unreachable;
}

final class VncUnresolved extends VncFailure {
  const VncUnresolved([super.detail]);

  @override
  ReasonLine get line => ReasonLine.unresolved;
}

final class VncKeyRejected extends VncFailure {
  const VncKeyRejected([super.detail]);

  @override
  ReasonLine get line => ReasonLine.keyRejected;
}

/// The `direct-tcpip` channel open was denied. SSH is live, so this is its own line
/// rather than `unreachable`.
final class VncTunnelRefused extends VncFailure {
  const VncTunnelRefused([super.detail]);

  @override
  ReasonLine get line => ReasonLine.tunnelRefused;
}

/// The server's security list has neither `None` nor VNC Authentication on it, or
/// refused the handshake outright. Apple's own types land here.
final class VncAuthUnsupported extends VncFailure {
  const VncAuthUnsupported([super.detail]);

  @override
  ReasonLine get line => ReasonLine.authUnsupported;
}

final class VncPasswordNeeded extends VncFailure {
  const VncPasswordNeeded([super.detail]);

  @override
  ReasonLine get line => ReasonLine.passwordNeeded;
}

final class VncUsernameNeeded extends VncFailure {
  const VncUsernameNeeded([super.detail]);

  @override
  ReasonLine get line => ReasonLine.usernameNeeded;
}

final class VncAuthRejected extends VncFailure {
  const VncAuthRejected([super.detail]);

  @override
  ReasonLine get line => ReasonLine.passwordRejected;
}

/// Covers the tunnel dropping mid-session and a handshake that stopped short of the
/// bytes it promised, because from the reader's side those are the same event.
final class VncStreamClosed extends VncFailure {
  const VncStreamClosed([super.detail]);

  @override
  ReasonLine get line => ReasonLine.streamClosed;
}

final class VncHostKeyUnverified extends VncFailure {
  const VncHostKeyUnverified([super.detail]);

  @override
  ReasonLine get line => ReasonLine.hostKeyUnverified;
}

final class VncHostKeyChanged extends VncFailure {
  const VncHostKeyChanged([super.detail]);

  @override
  ReasonLine get line => ReasonLine.hostKeyChanged;
}

/// Null for anything unexpected: a bug in the layer above reads better as itself than as
/// a reason line.
VncFailure? asVncFailure(Object error, [HostKeyRefusal? refusal]) =>
    switch (error) {
      VncFailure() => error,
      // The verifier's answer is the reason, whatever error the closing handshake surfaced.
      _ when refusal != null => switch (refusal) {
        HostKeyRefusal.unverified => VncHostKeyUnverified('$error'),
        HostKeyRefusal.changed => VncHostKeyChanged('$error'),
      },
      HerdrUnresolved() => VncUnresolved(error.detail ?? '$error'),
      HerdrKeyRejected() => VncKeyRejected(error.detail ?? '$error'),
      HerdrHostKeyUnverified() => VncHostKeyUnverified(
        error.detail ?? '$error',
      ),
      HerdrHostKeyChanged() => VncHostKeyChanged(error.detail ?? '$error'),
      HerdrFailure() => VncUnreachable(error.detail ?? '$error'),
      SSHHostkeyError() => VncHostKeyChanged('$error'),
      // dartssh2 raises this when the server answers the channel open with a failure, which
      // is what `restrict` and a missing `permitopen` both do.
      SSHChannelOpenError() => VncTunnelRefused('$error'),
      SSHAuthFailError() => VncKeyRejected('$error'),
      SSHKeyDecodeError() => VncKeyRejected('$error'),
      // The test is [HerdrClient]'s, deliberately: which errno family a lookup failure lands
      // in is a platform detail.
      SocketException() when HerdrClient.isLookupFailure(error) =>
        VncUnresolved('$error'),
      SocketException() => VncUnreachable('$error'),
      TimeoutException() => VncUnreachable('$error'),
      SSHError() => VncUnreachable('$error'),
      _ => null,
    };

Future<T> guardVnc<T>(
  Future<T> Function() body, [
  HostKeyVerifier? verifier,
]) async {
  try {
    return await body();
  } catch (error) {
    throw asVncFailure(error, verifier?.refusal) ?? error;
  }
}
