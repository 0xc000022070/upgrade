import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';

import 'package:upgrade/platform/reason_lines.dart';
import 'package:upgrade/platform/herdr/herdr_socket.dart';
import 'package:upgrade/platform/ssh/host_keys.dart';

enum HostFailureKind {
  unresolved(ReasonLine.unresolved),
  unreachable(ReasonLine.unreachable),
  keyRejected(ReasonLine.keyRejected),

  /// sshd answered but would not open the channel, or the pty or shell request on it.
  /// Which is what a key line still reading `restrict` without `pty` gives every time.
  shellRefused(ReasonLine.shellRefused),

  streamClosed(ReasonLine.streamClosed),
  hostKeyUnverified(ReasonLine.hostKeyUnverified),
  hostKeyChanged(ReasonLine.hostKeyChanged),
  busy(ReasonLine.hostBusy),
  noEngine(ReasonLine.noEngine),
  noHerdr(ReasonLine.noHerdr),
  protocolMismatch(ReasonLine.protocolMismatch),

  /// The `direct-tcpip` channel open was denied. SSH is live, so this is its own line
  /// rather than `unreachable`.
  tunnelRefused(ReasonLine.tunnelRefused),
  authUnsupported(ReasonLine.authUnsupported),
  passwordNeeded(ReasonLine.passwordNeeded),
  usernameNeeded(ReasonLine.usernameNeeded),
  authRejected(ReasonLine.passwordRejected);

  const HostFailureKind(this.line);

  final ReasonLine line;
}

class HostFailure implements Exception {
  const HostFailure(this.kind, {this.detail, this.protocol});

  const HostFailure.unreachable([String? detail])
    : this(HostFailureKind.unreachable, detail: detail);

  const HostFailure.keyRejected([String? detail])
    : this(HostFailureKind.keyRejected, detail: detail);

  const HostFailure.streamClosed([String? detail])
    : this(HostFailureKind.streamClosed, detail: detail);

  const HostFailure.busy([String? detail])
    : this(HostFailureKind.busy, detail: detail);

  const HostFailure.noEngine([String? detail])
    : this(HostFailureKind.noEngine, detail: detail);

  const HostFailure.noHerdr([String? detail])
    : this(HostFailureKind.noHerdr, detail: detail);

  const HostFailure.authUnsupported([String? detail])
    : this(HostFailureKind.authUnsupported, detail: detail);

  const HostFailure.passwordNeeded([String? detail])
    : this(HostFailureKind.passwordNeeded, detail: detail);

  const HostFailure.usernameNeeded([String? detail])
    : this(HostFailureKind.usernameNeeded, detail: detail);

  const HostFailure.authRejected([String? detail])
    : this(HostFailureKind.authRejected, detail: detail);

  const HostFailure.protocolMismatch([this.protocol, this.detail])
    : kind = HostFailureKind.protocolMismatch;

  final HostFailureKind kind;

  /// Carried out of here rather than logged here, because the debug line names the host
  /// and the host's name is a thing this layer deliberately does not know.
  final String? detail;

  final int? protocol;

  ReasonLine get line => kind.line;

  String reason(String host, {String? address}) =>
      line.reason(host, address: address, protocol: protocol);

  @override
  String toString() => 'HostFailure.${kind.name}(${detail ?? ''})';
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

HostFailureKind? classifyHostFailure(Object error, [HostKeyRefusal? refusal]) =>
    switch (error) {
      // The verifier's answer is the reason, whatever error the closing handshake surfaced.
      _ when refusal != null => switch (refusal) {
        HostKeyRefusal.unverified => HostFailureKind.hostKeyUnverified,
        HostKeyRefusal.changed => HostFailureKind.hostKeyChanged,
      },
      SSHHostkeyError() => HostFailureKind.hostKeyChanged,
      SSHChannelOpenError() ||
      SSHChannelRequestError() => HostFailureKind.shellRefused,
      SSHAuthFailError() || SSHKeyDecodeError() => HostFailureKind.keyRejected,
      SSHAuthAbortError(:final reason?) =>
        classifyHostFailure(reason) ?? HostFailureKind.streamClosed,
      SSHAuthAbortError() || SSHStateError() => HostFailureKind.streamClosed,
      SSHSocketError() =>
        classifyHostFailure(error.error) ?? HostFailureKind.unreachable,
      SocketException() when _isLookupFailure(error) =>
        HostFailureKind.unresolved,
      SocketException() ||
      TimeoutException() ||
      SSHError() => HostFailureKind.unreachable,
      _ => null,
    };

/// Null for anything unexpected: a bug in the layer above reads better as itself than as
/// a reason line. [remap] folds the kinds a caller has no line of its own for onto the
/// ones it has; [words] words the detail when `$error` is not the sentence.
HostFailure? translateHostFailure(
  Object error,
  HostKeyRefusal? refusal, {
  required Map<HostFailureKind, HostFailureKind> remap,
  String Function(Object error)? words,
}) => switch (error) {
  HostFailure() => error,
  HerdrMalformed() when refusal == null => HostFailure.protocolMismatch(
    error.protocol,
    '$error',
  ),
  _ => switch (classifyHostFailure(error, refusal)) {
    null => null,
    final kind => HostFailure(
      remap[kind] ?? kind,
      detail: words?.call(error) ?? '$error',
    ),
  },
};

/// Everything that talks to a host without a screen of its own has one line for a host it
/// cannot talk to, whatever sshd said about it.
const _unreachable = {
  HostFailureKind.shellRefused: HostFailureKind.unreachable,
  HostFailureKind.streamClosed: HostFailureKind.unreachable,
};

HostFailure? asHostFailure(Object error, [HostKeyRefusal? refusal]) =>
    translateHostFailure(error, refusal, remap: _unreachable);

Future<T> guardHost<T>(
  Future<T> Function() body, [
  HostKeyVerifier? verifier,
]) async {
  try {
    return await body();
  } catch (error) {
    throw asHostFailure(error, verifier?.refusal) ?? error;
  }
}
