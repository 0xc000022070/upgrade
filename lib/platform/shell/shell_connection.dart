import 'dart:convert';
import 'dart:typed_data';

import '../../application/reason_lines.dart';
import '../host_keys.dart';

abstract interface class ShellConnection {
  ShellTransport get transport;

  /// SSH ends its channel when reachability is lost. Mosh stays open while roaming, so it
  /// reports the difference between an existing session and recent server contact here.
  Stream<ShellConnectionHealth> get health;

  ShellContinuity get continuity;

  Stream<Uint8List> get output;

  void write(Uint8List bytes);

  void resize(int columns, int rows);

  Future<int?> get exitCode;

  Future<void> close();

  /// A [network] change also drops the SSH control connection under the channel, whose
  /// socket is bound to the network that went; a plain return keeps it.
  Future<void> rehome({bool network = false});

  Future<bool> terminateRemote(String session, {required bool durableShell});

  Future<String?> remoteDirectory(String session);

  /// A second channel, so the shell on the pty never sees any of it. With a [timeout], a
  /// command still running when it runs out throws and its channel is taken down, so one
  /// blocked on something that will never come does not hold the channel open for the life
  /// of the connection.
  Future<ExecResult> exec(
    String command, {
    Uint8List? stdin,
    Duration? timeout,
  });
}

enum ShellContinuity { plain, started, resumed }

enum ShellTransport { ssh, mosh }

enum ShellConnectionHealth { connected, reconnecting, disconnected }

class ExecResult {
  const ExecResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int? exitCode;
  final Uint8List stdout;
  final Uint8List stderr;

  bool get ok => exitCode == 0;

  String get out => utf8.decode(stdout, allowMalformed: true);
  String get err => utf8.decode(stderr, allowMalformed: true);
}

typedef ShellOpener = Future<ShellConnection> Function({
  required String address,
  required int port,
  required String user,
  required String privateKey,
  required int columns,
  required int rows,
  String? command,
  String? tabSession,
  String? persistentSession,
  HostKeyVerifier? verifier,
});

enum ShellFailureKind {
  unresolved,

  unreachable,

  keyRejected,

  /// Which is what a key line still reading `restrict` without `pty` gives every time.
  shellRefused,

  streamClosed,

  hostKeyUnverified,

  hostKeyChanged,
}

/// The header's word and the reason row's line are both read off it, so the two cannot
/// say different things about the same failure.
extension ShellFailureLine on ShellFailureKind {
  ReasonLine get line => switch (this) {
    ShellFailureKind.unresolved => ReasonLine.unresolved,
    ShellFailureKind.unreachable => ReasonLine.unreachable,
    ShellFailureKind.keyRejected => ReasonLine.keyRejected,
    ShellFailureKind.shellRefused => ReasonLine.shellRefused,
    ShellFailureKind.streamClosed => ReasonLine.streamClosed,
    ShellFailureKind.hostKeyUnverified => ReasonLine.hostKeyUnverified,
    ShellFailureKind.hostKeyChanged => ReasonLine.hostKeyChanged,
  };
}

class ShellFailure implements Exception {
  const ShellFailure(this.kind, {this.detail});

  final ShellFailureKind kind;

  final String? detail;

  @override
  String toString() =>
      'ShellFailure.${kind.name}${detail == null ? '' : ': $detail'}';
}
