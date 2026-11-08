// Part of the SSH connection policy library; read the header in connection_supervisor.dart before editing.
part of 'connection_supervisor.dart';

/// Proof a person asked. Take one from a gesture wrapper and pass it down; never store it,
/// or call a wrapper from a timer, stream or probe. It builds one reason, within [window].
final class UserIntent {
  UserIntent._();

  static const window = Duration(seconds: 5);

  static final _watch = Stopwatch()..start();
  static Duration _elapsed() => _watch.elapsed;
  static Duration Function() _clock = _elapsed;

  @visibleForTesting
  static set clock(Duration Function()? clock) => _clock = clock ?? _elapsed;

  final Duration _minted = _clock();
  var _spent = false;

  String? _spend() {
    if (_spent) return 'its intent was spent before';
    _spent = true;
    final age = _clock() - _minted;
    return age > window ? 'its intent is ${age.inMilliseconds} ms old' : null;
  }

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

/// Proof the platform reported an event, minted in its callback. It builds one reason.
final class PlatformSignal {
  PlatformSignal._();

  var _spent = false;

  String? _spend() {
    if (_spent) return 'its signal was spent before';
    _spent = true;
    return null;
  }

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

mixin _Spends {
  String? get _refused;
}

bool _refuses(Object reason, String where) {
  if (reason case _Spends(:final _refused?)) {
    final line = 'refused ${reason.runtimeType}: $_refused';
    debugPrint('$appSlug.ssh $where: $line');
    assert(false, line);
    return true;
  }
  return false;
}

final class UserAction with _Spends implements OpenReason, ReopenReason {
  UserAction(UserIntent intent) : _refused = intent._spend();

  @override
  final String? _refused;
}

final class AppResumed with _Spends implements OpenReason, ReopenReason {
  AppResumed(PlatformSignal signal) : _refused = signal._spend();

  @override
  final String? _refused;
}

/// Both a drop and an open, because the old socket is bound to the network that went away.
final class NetworkChanged
    with _Spends
    implements OpenReason, ReopenReason, DropReason {
  NetworkChanged(PlatformSignal signal) : _refused = signal._spend();

  @override
  final String? _refused;
}

final class UserClosed extends DropReason with _Spends {
  UserClosed(UserIntent intent) : _refused = intent._spend(), super._();

  UserClosed.by(UserAction action) : _refused = action._refused, super._();

  @override
  final String? _refused;
}

final class AppSuspended extends DropReason with _Spends {
  AppSuspended(PlatformSignal signal) : _refused = signal._spend(), super._();

  @override
  final String? _refused;
}

/// Minted only in this library, from evidence that a terminal or a dial ended. A command,
/// timeout or probe on a connection already handed out is never such evidence.
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

/// A dial failed on the host or link, in the handshake or a startup step before hand-out.
final class _DialFailed extends _Evidence {
  const _DialFailed(this.error);

  final Object error;
}

/// The terminal exited, its stream died, or it stayed silent past the health window. Only the
/// supervisor under that terminal mints one, and only that supervisor accepts it.
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
