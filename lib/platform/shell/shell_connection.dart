import 'dart:typed_data';

import '../host_keys.dart';

/// One live shell on a host, whatever is carrying it.
///
/// The seam between the transport (builder A, `shell_tunnel.dart`) and the
/// route and store (builder B, `lib/features/shell/`). A test drives the
/// store and the view through its own implementation of this; the real one
/// is an ssh channel with a pty and the remote's login shell on it, and
/// nothing else.
abstract interface class ShellConnection {
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
}

/// What the store needs of the transport: open one shell at this size.
/// The real one is `ShellTunnel.open`. Failures are thrown as the
/// `VncFailure`-style reasons the header already knows how to word.
typedef ShellOpener = Future<ShellConnection> Function({
  required String address,
  required int port,
  required String user,
  required String privateKey,
  required int columns,
  required int rows,
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
