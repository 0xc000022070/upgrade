import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';

import '../herdr_client.dart';

/// The screen route's six reason lines, as types.
///
/// The three ssh-shaped ones are the same failures the agent poll already
/// names, and
/// [VncFailure.reason] words them the way [AgentOutcome.reason] does. The other
/// three belong to the screen: the tunnel, the security handshake, and a
/// stream that ended under a session that was still reading it.
sealed class VncFailure implements Exception {
  const VncFailure([this.detail]);

  /// What the transport actually said. Carried out of here so
  /// the caller, which is the half that knows the host's name, writes the
  /// `hotline.vnc <host>: …` debug line.
  final String? detail;

  /// The reason line, given the host it happened to. Only the two failures that
  /// are about reaching a machine name it — the rest are about this connection
  /// and read the same wherever they happen.
  String reason(String host);

  @override
  String toString() => '$runtimeType(${detail ?? ''})';
}

final class VncUnreachable extends VncFailure {
  const VncUnreachable([super.detail]);

  @override
  String reason(String host) => '${host.toLowerCase()} unreachable';
}

final class VncUnresolved extends VncFailure {
  const VncUnresolved([super.detail]);

  @override
  String reason(String host) => '${host.toLowerCase()} unresolved';
}

final class VncKeyRejected extends VncFailure {
  const VncKeyRejected([super.detail]);

  @override
  String reason(String host) => 'key rejected';
}

/// The `direct-tcpip` channel open was denied. On a host whose key line
/// still reads `restrict`, this is what every connection gets — sshd refuses
/// the forward, not the login — which is why it is its own line and not
/// `unreachable`.
final class VncTunnelRefused extends VncFailure {
  const VncTunnelRefused([super.detail]);

  @override
  String reason(String host) => 'tunnel refused';
}

/// The server's security list has no `None` in it. This app has no
/// password to offer and does not ask for one.
final class VncAuthUnsupported extends VncFailure {
  const VncAuthUnsupported([super.detail]);

  @override
  String reason(String host) => 'auth unsupported';
}

/// The RFB stream ended. Covers the tunnel dropping mid-session and a
/// handshake that stopped short of the bytes it promised, because from the
/// reader's side those are the same event.
final class VncStreamClosed extends VncFailure {
  const VncStreamClosed([super.detail]);

  @override
  String reason(String host) => 'stream closed';
}

/// Every error the ssh layer can raise, on those lines.
///
/// Null for anything unexpected: the real error belongs in the debug log,
/// and a bug in the layer above reads better as itself than as
/// `nyx unreachable`.
VncFailure? asVncFailure(Object error) => switch (error) {
  VncFailure() => error,
  // dartssh2 raises this when the server answers the channel open with a
  // failure, which is what `restrict` and a missing `permitopen` both do.
  SSHChannelOpenError() => VncTunnelRefused('$error'),
  SSHAuthFailError() => VncKeyRejected('$error'),
  SSHKeyDecodeError() => VncKeyRejected('$error'),
  // The only failure that happens before an address exists. The test
  // is [HerdrClient]'s, deliberately: which errno family a lookup failure
  // lands in is a platform detail, and one copy of that guess is enough.
  SocketException() when HerdrClient.isLookupFailure(error) => VncUnresolved(
    '$error',
  ),
  SocketException() => VncUnreachable('$error'),
  TimeoutException() => VncUnreachable('$error'),
  SSHError() => VncUnreachable('$error'),
  _ => null,
};

Future<T> guardVnc<T>(Future<T> Function() body) async {
  try {
    return await body();
  } catch (error) {
    throw asVncFailure(error) ?? error;
  }
}
