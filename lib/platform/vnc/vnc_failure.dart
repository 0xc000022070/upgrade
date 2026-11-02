import 'package:upgrade/application/agents/reason_lines.dart';
import 'package:upgrade/platform/ssh/host_failure.dart';
import 'package:upgrade/platform/ssh/host_keys.dart';

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
      HerdrUnresolved(:final detail) => VncUnresolved(detail ?? '$error'),
      HerdrKeyRejected(:final detail) => VncKeyRejected(detail ?? '$error'),
      HerdrHostKeyUnverified(:final detail) => VncHostKeyUnverified(
        detail ?? '$error',
      ),
      HerdrHostKeyChanged(:final detail) => VncHostKeyChanged(
        detail ?? '$error',
      ),
      HerdrFailure(:final detail) => VncUnreachable(detail ?? '$error'),
      _ => switch (classifyHostFailure(error, refusal)) {
        null => null,
        HostFailureKind.unresolved => VncUnresolved('$error'),
        HostFailureKind.unreachable => VncUnreachable('$error'),
        HostFailureKind.keyRejected => VncKeyRejected('$error'),
        // What `restrict` and a missing `permitopen` both answer the `direct-tcpip` open with.
        HostFailureKind.refused => VncTunnelRefused('$error'),
        HostFailureKind.streamClosed => VncStreamClosed('$error'),
        HostFailureKind.hostKeyUnverified => VncHostKeyUnverified('$error'),
        HostFailureKind.hostKeyChanged => VncHostKeyChanged('$error'),
      },
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
