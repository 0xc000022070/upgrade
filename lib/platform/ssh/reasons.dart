// Part of the SSH connection policy library; read the header in connection_supervisor.dart before editing.
part of 'connection_supervisor.dart';

/// Proof a person asked. Mint only in a gesture handler and pass it down; never store one
/// or mint one where a timer, a stream or a probe reaches.
final class UserIntent {
  UserIntent._();

  static VoidCallback onGesture(void Function(UserIntent intent) handler) =>
      () => handler(UserIntent._());

  static ValueChanged<T> onGestureWith<T>(
    void Function(UserIntent intent, T value) handler,
  ) =>
      (value) => handler(UserIntent._(), value);

  static void Function(T response) onNotificationTap<T>(
    void Function(UserIntent intent, T response) handler,
  ) =>
      (response) => handler(UserIntent._(), response);
}

/// Proof the platform said so. Mint only in the callback that hears it.
final class PlatformSignal {
  PlatformSignal._();

  static Future<void> onLaunch(
    Future<void> Function(PlatformSignal launch) boot,
  ) => boot(PlatformSignal._());

  static void Function(bool? was, bool now) onLifecycle(
    void Function(PlatformSignal signal, bool? was, bool now) handler,
  ) =>
      (was, now) => handler(PlatformSignal._(), was, now);

  static void Function(bool up) onNetwork(
    void Function(PlatformSignal signal, bool up) handler,
  ) =>
      (up) => handler(PlatformSignal._(), up);
}

sealed class OpenReason {
  const OpenReason._();
}

sealed class ReopenReason {
  const ReopenReason._();
}

sealed class DropReason {
  const DropReason._();
}

final class UserAction implements OpenReason, ReopenReason {
  const UserAction(UserIntent _);
}

final class AppResumed implements OpenReason, ReopenReason {
  const AppResumed(PlatformSignal _);
}

/// Both a drop and an open: the old socket is bound to the network that went.
final class NetworkChanged implements OpenReason, ReopenReason, DropReason {
  const NetworkChanged(PlatformSignal _);
}

final class UserClosed extends DropReason {
  const UserClosed(UserIntent _) : super._();
}

final class AppSuspended extends DropReason {
  const AppSuspended(PlatformSignal _) : super._();
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

/// On the host or link, in the handshake or a startup step before the hand-out.
final class _DialFailed extends _Evidence {
  const _DialFailed(this.error);

  final Object error;
}

/// The terminal exited, its stream died, or it stayed silent past the health window. Only
/// the supervisor under it mints one, and only that supervisor accepts it.
final class ShellEnded implements DropReason {
  ShellEnded._(this._of);

  @visibleForTesting
  factory ShellEnded.unbound() => ShellEnded._(null);

  final ConnectionSupervisor? _of;

  Reconnect get reconnect => Reconnect._(_TerminalEnded(this));
}

final class HealthCheckFailed extends DropReason {
  const HealthCheckFailed._() : super._();
}

final class _HostDied extends ReopenReason {
  const _HostDied(this.failed) : super._();

  final HealthCheckFailed failed;
}

final class _StartupAbandoned extends DropReason {
  const _StartupAbandoned() : super._();
}

final class _Unclaimed extends DropReason {
  const _Unclaimed() : super._();
}
