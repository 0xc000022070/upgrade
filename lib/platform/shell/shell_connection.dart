import 'dart:convert';
import 'dart:typed_data';

import '../../application/reason_lines.dart';
import '../host_keys.dart';

/// One live shell on a host, whatever is carrying it.
///
/// The seam between the transport (builder A, `shell_tunnel.dart`) and the
/// route and store (builder B, `lib/features/shell/`). A test drives the
/// store and the view through its own implementation of this; real sessions
/// are either a Mosh UDP channel or an SSH channel with a pty.
abstract interface class ShellConnection {
  ShellTransport get transport;

  /// Whether this channel started a durable remote shell, found one, or had
  /// to fall back to a plain SSH shell because the host has no tmux client.
  ShellContinuity get continuity;

  /// What the shell prints, stdout and stderr in arrival order.
  Stream<Uint8List> get output;

  /// What the user typed, bytes exactly as the terminal emitted them.
  void write(Uint8List bytes);

  /// The view's new size, forwarded as a window change.
  void resize(int columns, int rows);

  /// Completes when the remote shell ends, with its exit code, or with
  /// null when the channel closed without one.
  Future<int?> get exitCode;

  /// Closes the channel and the connection under it.
  Future<void> close();

  /// Moves a roaming transport onto the phone's current network. Plain SSH
  /// has nothing to do here; Mosh rebinds its UDP socket.
  Future<void> rehome();

  /// Ends this tab's marked Mosh server and, for an ordinary durable shell,
  /// its Dazzle-owned tmux session. True means the pending cleanup may be
  /// forgotten.
  Future<bool> terminateRemote(String session, {required bool durableShell});

  /// The active pane's directory in one Dazzle-owned remote shell.
  Future<String?> remoteDirectory(String session);

  /// Runs one command on a second channel of the same connection, with
  /// [stdin] written to it and closed, and answers once it has exited. The
  /// shell on the pty never sees any of it: what lands a clip on the host and
  /// what puts it on the host's clipboard both go this way, so nothing about
  /// the user's own prompt is disturbed.
  Future<ExecResult> exec(String command, {Uint8List? stdin});
}

enum ShellContinuity { plain, started, resumed }

enum ShellTransport { ssh, mosh }

/// What a command on an exec channel came back with.
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

/// What the store needs of the transport: open one shell at this size, or one
/// [command] on a pty of that size instead of the login shell. The real one is
/// `ShellTunnel.open`. Failures are thrown as the `VncFailure`-style reasons
/// the header already knows how to word.
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

/// Why a shell did not open or did not stay open, one line's worth each.
enum ShellFailureKind {
  /// The name did not resolve.
  unresolved,

  /// The machine did not answer.
  unreachable,

  /// The host would not take the key.
  keyRejected,

  /// The channel, the pty or the shell request was denied, which is what a
  /// key line still reading `restrict` without `pty` gives every time.
  shellRefused,

  /// The connection went away without an exit code.
  streamClosed,

  /// Nothing is pinned for this host and nobody could be asked, or the user
  /// was asked and said no.
  hostKeyUnverified,

  /// The machine presented a key that is not the one pinned for it. Refused
  /// with no way past it here; the pin is dropped on the host form or not at
  /// all.
  hostKeyChanged,
}

/// Which sentence each kind is worded as. The header's word and the reason
/// row's line are both read off it, so the two cannot say different things
/// about the same failure.
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

/// Thrown by the opener and by the transport while a session is up.
class ShellFailure implements Exception {
  const ShellFailure(this.kind, {this.detail});

  final ShellFailureKind kind;

  /// The underlying error's words, for the debug log only.
  final String? detail;

  @override
  String toString() =>
      'ShellFailure.${kind.name}${detail == null ? '' : ': $detail'}';
}
