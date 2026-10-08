// Part of the SSH connection policy library; read the header in connection_supervisor.dart before editing.
part of 'connection_supervisor.dart';

/// Proof a person asked. Mint only in a gesture handler and pass it down; never store one
/// or mint one where a timer, a stream or a probe reaches.
final class UserIntent {
  UserIntent._();

  factory UserIntent.fromGesture() => UserIntent._();
}

/// Proof the platform said so. Mint only in the callback that hears it.
final class PlatformSignal {
  PlatformSignal._();

  factory PlatformSignal.fromPlatform() => PlatformSignal._();
}

sealed class OpenReason {
  const OpenReason._();
}

sealed class DropReason {
  const DropReason._();
}

final class UserAction extends OpenReason {
  const UserAction(this.intent) : super._();

  final UserIntent intent;
}

final class AppResumed extends OpenReason {
  const AppResumed(this.signal) : super._();

  final PlatformSignal signal;
}

/// Both a drop and an open: the old socket is bound to the network that went.
final class NetworkChanged implements OpenReason, DropReason {
  const NetworkChanged(this.signal);

  final PlatformSignal signal;
}

final class UserClosed extends DropReason {
  const UserClosed(this.intent) : super._();

  final UserIntent intent;
}

final class AppSuspended extends DropReason {
  const AppSuspended(this.signal) : super._();

  final PlatformSignal signal;
}

/// Minted only here, bound to evidence of an end. A command, timeout or probe on a
/// connection already handed out is never evidence.
final class Reconnect extends OpenReason {
  const Reconnect._(this._cause) : super._();

  final _Evidence _cause;
}

sealed class _Evidence {
  const _Evidence();
}

final class _TerminalEnded extends _Evidence {
  const _TerminalEnded(this.end);

  final ShellEnded end;
}

final class _HostDied extends _Evidence {
  const _HostDied(this.failed, this.of);

  final HealthCheckFailed failed;
  final ConnectionSupervisor of;
}

/// On the host or link, in the handshake or a startup step before the hand-out.
final class _DialFailed extends _Evidence {
  const _DialFailed(this.error);

  final Object error;
}

/// The terminal exited, its stream died, or it stayed silent past the health window. Only
/// the supervisor under it mints one, and only that supervisor accepts it.
final class ShellEnded implements DropReason {
  ShellEnded._(this._of);

  /// Bound to no supervisor, so none accepts it: what a fake transport hands the store.
  @visibleForTesting
  factory ShellEnded.unbound() => ShellEnded._(null);

  final ConnectionSupervisor? _of;

  Reconnect get reconnect => Reconnect._(_TerminalEnded(this));
}

final class HealthCheckFailed extends DropReason {
  const HealthCheckFailed._() : super._();
}

final class _StartupAbandoned extends DropReason {
  const _StartupAbandoned() : super._();
}

final class _Unclaimed extends DropReason {
  const _Unclaimed() : super._();
}
