import 'dart:typed_data';

import 'package:upgrade/application/agents/reason_lines.dart';
import 'package:upgrade/platform/ssh/host_keys.dart';
import 'package:upgrade/platform/ssh/connection_supervisor.dart';

export 'package:upgrade/platform/ssh/host_files.dart'
    show FileBody, FileRoute, FileWrite, PutProgress;

export 'package:upgrade/platform/ssh/connection_supervisor.dart'
    show
        AppResumed,
        AppSuspended,
        ChannelOpenTimeout,
        ControlGaveUp,
        ControlLink,
        ControlReconnecting,
        ControlUp,
        DropReason,
        ExecResult,
        HostChannels,
        NetworkChanged,
        OpenReason,
        PlatformSignal,
        Reconnect,
        ShellEnded,
        UserAction,
        UserClosed,
        UserIntent,
        isHostFailure,
        isKeyFailure;

abstract interface class ShellConnection {
  ShellTransport get transport;

  /// SSH ends its channel when reachability is lost. Mosh stays open while roaming, so it
  /// reports the difference between an existing session and recent server contact here.
  Stream<ShellConnectionHealth> get health;

  ShellContinuity get continuity;

  Stream<Uint8List> get output;

  Stream<Uint8List> get snapshots;

  /// Foreground process metadata from a transport that owns the remote PTY. Empty means
  /// the transport checked and found no unambiguous process.
  Stream<String> get foregroundProcesses;

  void write(Uint8List bytes);

  void resize(int columns, int rows, {int widthPx = 0, int heightPx = 0});

  Future<int?> get exitCode;

  /// False, logged and asserted, for a reason [close] would refuse, so the tab tears
  /// nothing down for it.
  bool accepts(DropReason reason);

  Future<void> close(DropReason reason);

  /// The terminal's end once the transport has seen it, its exit or its stream dying, and
  /// null while it runs. The one [ShellEnded] this connection's [close] accepts.
  ShellEnded? get ended;

  /// For a dial that landed late: false, and nothing closed, once the terminal was read.
  Future<bool> discard();

  /// A [network] change also replaces the SSH control connection under the channel, whose
  /// socket is bound to the network that went; a plain return keeps it.
  Future<void> rehome({NetworkChanged? network});

  Future<void> suspend(AppSuspended reason);

  Future<void> resume(AppResumed reason);

  /// Without an [action] only a held host is used, and none means false.
  Future<bool> terminateRemote(
    String session, {
    required bool durableShell,
    UserAction? action,
  });

  Future<String?> remoteDirectory(String session);

  /// A second channel, so the shell on the pty never sees any of it. Every background read
  /// goes here, and gets null while no host is held.
  HostChannels get channels;

  /// Opens the host for a gesture that needs it when none is held.
  Future<HostChannels?> channelsFor(UserAction action);

  /// Down while the terminal runs but no host is held for [channels]: what background
  /// reads said is stale, and [channelsFor] dials. Emits on change only; a transport
  /// whose terminal dies with its host never emits.
  Stream<ControlLink> get controlLink;
}

enum ShellContinuity { plain, started, resumed }

enum ShellTransport { ssh, mosh, engine }

enum ShellConnectionHealth { connected, reconnecting, disconnected }

typedef ShellOpener = Future<ShellConnection> Function({
  required OpenReason reason,
  required String address,
  required int port,
  required String user,
  required String privateKey,
  required int columns,
  required int rows,
  String? command,
  String? tabSession,
  String? persistentSession,
  required HostKeyVerifier verifier,
  void Function(Reconnect retry)? failed,
  bool alone,
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
