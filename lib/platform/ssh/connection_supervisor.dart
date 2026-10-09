/// SSH connection policy.
///
/// This library owns the app's SSH connections: who opens and closes one, and when a tab
/// may dial again. It exists because a probe's timeout once replaced a live connection under
/// a typed SEND; see `SSH-CONNECTION-INCIDENT.md`. Library privacy and sealed reasons
/// enforce each rule below unless the rule names a test.
///
/// Who opens and closes:
/// - [HostLinks] alone opens and closes sockets. Everything else leases and releases, so a
///   command, timeout or probe never closes or replaces a connection.
/// - Only the shell tunnel holds a supervisor, and it takes its raw pty [SSHSession] from
///   [pty]. Other code reads through [HostChannels] views, null while no host is held.
/// - Each host identity has one control and one screen link per isolate; [HostUse] picks
///   the lane. The host key probe and one overflow link for a full host sit outside that.
/// - [UserClosed], [ShellEnded], [_StartupAbandoned] and [_Unclaimed] end one tab's claim.
///   [NetworkChanged] and a dead link end the link for every tab, with one redial after.
/// Why a tab may redial:
/// - A claim, drop, renounce or revive needs a sealed reason; only an open or reopen reason
///   redials. No reason is a command failure, and every switch over reasons is exhaustive.
/// - A probe or command on a handed-out connection is never evidence the host is gone, and
///   is never retried on that host. A dial includes [SshConnector.establish]'s startup steps.
/// - Only this library mints [Reconnect], from a [ShellEnded] or a dial that failed on the
///   host or link, and only a fresh supervisor accepts it. [ShellEnded] is minted and
///   accepted only by the supervisor under the terminal that ended.
/// Liveness and revive:
/// - A held link ends only when its keepalive goes unanswered; [check] runs one round early.
///   A terminal silent past its window has ended.
/// - [HealthCheckFailed] comes only from [HostLease.ended] and reopens only its own host's
///   supervisor, on a fixed schedule if the transport asks for it. No other timer dials.
/// Settling: a dial refused while an earlier one settles ([DialSettling]) waits for it; that
/// is not a failure or a revive step. A [UserAction] waits [SshConnector.timeout] at most.
/// Sleep: past the sleep grace only a live plain-SSH terminal's control link stays, and only
/// [HostUse.wakes] uses may lease beside it.
/// Tokens: [UserIntent] and [PlatformSignal] come only from callbacks their wrappers build.
/// - One token builds one reason, except that [UserClosed.by] builds the close for a
///   [UserAction]'s gesture on that action's spend. A second reason, or a [UserIntent] older
///   than [UserIntent.window], is refused where it would dial or drop, logged and asserted.
/// - `test/ssh_fence_test.dart` pins by resolved element each call site of [UserClosed.by],
///   [SshConnector.establish], [HostLease.client] and [HostLinks]' claim, renounce, sleep,
///   wake, recheckAll and close, each wrapper's slot and the fields a token rides in. No check
///   catches one prompt spend, within the window, from a path no person or platform event
///   started. An alert tapped before mount is a cold launch.
/// A new part, wrapper, raw host path or reason needs the owner's approval.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import '../host_keys.dart';
import '../host_links.dart';
import '../ssh_settle.dart';

part 'exec.dart';
part 'reasons.dart';

sealed class ControlLink {
  const ControlLink();
}

/// A host is held, or nobody is watching: the app is away or the tab is gone.
final class ControlUp extends ControlLink {
  const ControlUp();
}

final class ControlReconnecting extends ControlLink {
  const ControlReconnecting();
}

final class ControlGaveUp extends ControlLink {
  const ControlGaveUp(this.error);

  final Object error;
}

abstract interface class HostChannels {
  /// Runs [command] on the held host, or answers null when none is held; it never dials.
  /// Past [timeout] the channel is closed, never the host.
  Future<ExecResult?> exec(
    String command, {
    Uint8List? stdin,
    required Duration timeout,
  });
}

/// A tab's claim on its host's shared control link. Its channels answer null once it lets go.
final class ConnectionSupervisor implements HostChannels {
  ConnectionSupervisor._(this._connector, this._target);

  final SshConnector _connector;
  final HostTarget _target;
  PinnedHostKey? _trusted;
  _Hold? _held;
  _Dial? _dial;
  var _retired = false;
  var _suspended = false;
  var _claimed = false;
  ShellEnded? _ended;
  var _revives = false;
  Timer? _revival;
  final _control = StreamController<ControlLink>.broadcast();
  var _reportedDown = false;

  late final HostChannels channels = _Channels(this);

  @override
  Future<ExecResult?> exec(
    String command, {
    Uint8List? stdin,
    required Duration timeout,
  }) async => _held?.exec(command, stdin: stdin, timeout: timeout);

  Stream<ControlLink> get controlLink => _control.stream;

  String get endpoint => '${_target.address}:${_target.port}';

  /// Answers null when the tab is gone or the app is away, and throws what the dial threw.
  /// A gesture dials again once if a network change overtook its dial, and waits out settles
  /// for [SshConnector.timeout] at most; a resume or a network change waits out every settle.
  Future<HostChannels?> open(ReopenReason reason) {
    if (_refuses(reason, endpoint)) return Future.value();
    return switch (reason) {
      UserAction() || AppResumed() || NetworkChanged() => _openUntilHeld(reason),
      _HostDied() => _open(reason).future,
    };
  }

  Future<HostChannels?> _openUntilHeld(ReopenReason reason) async {
    final attended = reason is UserAction;
    final settles = _SettleWait(attended ? _connector.timeout : null);
    var overtakeLeft = attended;
    var dial = _open(reason);
    try {
      while (true) {
        try {
          final channels = await dial.future;
          if (channels != null || !dial.overtaken || !overtakeLeft) {
            return channels;
          }
          overtakeLeft = false;
        } catch (error, stack) {
          if (dial.overtaken && overtakeLeft) {
            overtakeLeft = false;
          } else if (error is DialSettling) {
            await settles.out(error, stack);
            if (!attended && (_retired || _suspended)) return null;
          } else {
            rethrow;
          }
        }
        dial = _open(reason);
      }
    } finally {
      settles.end();
    }
  }

  _Dial _open(ReopenReason reason) {
    if (_retired) return _Dial.none();
    switch (reason) {
      case AppResumed():
        _suspended = false;
        _report();
      case UserAction() || NetworkChanged():
        break;
      case _HostDied():
        if (_suspended) return _Dial.none();
    }
    final held = _held;
    if (held != null) return _Dial.settled(held);
    if (_suspended && reason is NetworkChanged) return _Dial.none();
    final pending = _dial;
    if (pending != null) return pending;
    final dial = _dial = _Dial();
    dial.future = _redial(reason, dial).whenComplete(() {
      if (identical(_dial, dial)) _dial = null;
    });
    return dial;
  }

  /// Revives a dead host on a schedule, for a transport whose terminal outlives its host.
  void reopenWhenHostDies() => _revives = true;

  void _revive(_HostDied reason, int step) {
    _revival?.cancel();
    _revival = Timer(_reviveDelays[step], () async {
      _revival = null;
      if (_retired || _suspended || _held != null) return;
      try {
        await open(reason);
      } catch (error) {
        if (_retired || _suspended || _held != null) return;
        if (error is DialSettling) {
          await error.settled;
          if (_retired || _suspended || _held != null || _revival != null) {
            return;
          }
          _revive(reason, step);
        } else if (isHostFailure(error) && step + 1 < _reviveDelays.length) {
          _revive(reason, step + 1);
        } else {
          _giveUp(error);
        }
      }
    });
  }

  void _report() {
    final down = _held == null && !_suspended && !_retired;
    if (down == _reportedDown || _control.isClosed) return;
    _reportedDown = down;
    _control.add(down ? const ControlReconnecting() : const ControlUp());
  }

  void _giveUp(Object error) {
    _log('revival stopped on $error');
    if (!_reportedDown || _control.isClosed) return;
    _control.add(ControlGaveUp(error));
  }

  bool accepts(DropReason reason) => !_refuses(reason, endpoint);

  /// Throws, before dropping anything, for a [ShellEnded] another supervisor minted.
  Future<void> drop(DropReason reason) {
    if (_refuses(reason, endpoint)) return Future.value();
    switch (reason) {
      case ShellEnded(:final _of) when !identical(_of, this):
        throw ArgumentError.value(reason, 'reason', 'ended another terminal');
      case UserClosed() || ShellEnded() || _StartupAbandoned() || _Unclaimed():
        _retired = true;
      case AppSuspended():
        _suspended = true;
      case NetworkChanged() || HealthCheckFailed():
        break;
    }
    // Clearing [_dial] makes a dial still in flight release its lease when it lands.
    _dial?.overtaken = reason is NetworkChanged;
    _dial = null;
    final held = _held;
    _held = null;
    if (held != null) _log('drop for ${reason.runtimeType}');
    if (_retired || _suspended) {
      _revival?.cancel();
      _revival = null;
    }
    _report();
    if (_retired && !_control.isClosed) unawaited(_control.close());
    if (reason is NetworkChanged) _connector._renounce(_target, reason);
    held?.lease.release();
    return Future.value();
  }

  /// Only for the terminal's own end. Every call returns the same [ShellEnded].
  ShellEnded terminalEnded() => _ended ??= ShellEnded._(this);

  void claim() => _claimed = true;

  bool get claimed => _claimed;

  /// Drops this supervisor if no tab ever claimed it, and answers whether it did.
  Future<bool> discard() async {
    if (_claimed) return false;
    await drop(const _Unclaimed());
    return true;
  }

  Future<void> check() async => _held?.lease.check();

  Future<SSHSession> pty(String? command, SSHPtyConfig config) async {
    final lease = _held?.lease;
    // The error dartssh2 throws for a closed client, so the tab treats it as a lost stream.
    if (lease == null) throw SSHStateError('No SSH host is held.');
    // An exec request, unlike a shell request, lets a detach end the channel as `exit` does.
    return command == null
        ? lease.shell(config)
        : lease.execute(command, pty: config);
  }

  Future<HostChannels?> _redial(ReopenReason reason, _Dial dial) async {
    final HostLease lease;
    try {
      lease = await _connector._claim(
        _target,
        HostKeyVerifier.pinnedOnly(_trusted),
      );
    } catch (error) {
      debugPrint('upgrade.shell $endpoint: redial: $error');
      rethrow;
    }
    final cause = switch (reason) {
      _HostDied() => 'a host that died',
      final OpenReason opening => _purpose(opening).cause,
    };
    if (!identical(_dial, dial)) {
      _log('redial for $cause, discarded');
      lease.release();
      return null;
    }
    _log('redial for $cause');
    return _hold(lease);
  }

  _Hold _hold(HostLease lease) {
    final held = _held = _Hold(this, lease);
    _revival?.cancel();
    _revival = null;
    _report();
    void died() {
      if (!identical(_held, held)) return;
      const failed = HealthCheckFailed._();
      unawaited(drop(failed));
      if (_revives) _revive(const _HostDied(failed), 0);
    }

    unawaited(lease.ended.then((_) => died()));
    return held;
  }

  void _log(String message) => debugPrint(
    'upgrade.shell $endpoint supervisor ${identityHashCode(this)}: '
    '$message',
  );
}

final class _Dial {
  _Dial();

  _Dial.settled(HostChannels? channels) : future = Future.value(channels);

  _Dial.none() : this.settled(null);

  late final Future<HostChannels?> future;
  var overtaken = false;
}

final class _Channels implements HostChannels {
  _Channels(this._owner);

  final ConnectionSupervisor _owner;

  @override
  Future<ExecResult?> exec(
    String command, {
    Uint8List? stdin,
    required Duration timeout,
  }) => _owner.exec(command, stdin: stdin, timeout: timeout);
}

/// Revive delays. After the last, a dead host waits for a gesture, resume or network change.
const _reviveDelays = <Duration>[
  Duration(seconds: 1),
  Duration(seconds: 2),
  Duration(seconds: 5),
  Duration(seconds: 10),
  Duration(seconds: 30),
];

({bool attended, String cause}) _purpose(OpenReason reason) => switch (reason) {
  UserAction() => (attended: true, cause: 'a gesture'),
  AppResumed() => (attended: false, cause: 'a resume'),
  NetworkChanged() => (attended: false, cause: 'a network change'),
  Reconnect(:final _cause) => switch (_cause) {
    _TerminalEnded() => (attended: false, cause: 'a terminal that ended'),
    _DialFailed() => (attended: false, cause: 'a dial that failed'),
  },
};

final class SshConnector {
  SshConnector({HostLinks? links, required this.timeout})
    : _links = links ?? HostLinks();

  final HostLinks _links;
  final Duration timeout;

  void _renounce(HostTarget target, NetworkChanged change) => _links.renounce(
    address: target.address,
    port: target.port,
    user: target.user,
    privateKey: target.privateKey,
    change: change,
  );

  /// If [startup] throws, the host is dropped first: a half-open connection counts against
  /// the host until it times out. A host or link failure hands [failed] a [Reconnect].
  Future<T> establish<T>({
    required String address,
    required int port,
    required String user,
    required String privateKey,
    required HostKeyVerifier verifier,
    required OpenReason reason,
    required Future<T> Function(ConnectionSupervisor supervisor) startup,
    void Function(Reconnect retry)? failed,
  }) async {
    if (_refuses(reason, '$address:$port')) {
      throw StateError('a refused ${reason.runtimeType} dials nothing');
    }
    final purpose = _purpose(reason);
    // Nobody is watching to answer a host key prompt, so an unattended open cannot carry one.
    if (!purpose.attended && verifier.prompt != null) {
      throw ArgumentError.value(
        verifier,
        'verifier',
        'an open for ${purpose.cause} asks nobody about a host key',
      );
    }
    final target = HostTarget(address, port, user, privateKey);
    final supervisor = ConnectionSupervisor._(this, target)
      .._log('dial for ${purpose.cause}');
    final HostLease lease;
    try {
      lease = await _SettleWait(purpose.attended ? timeout : null)
          .outlast(() => _claim(target, verifier));
    } catch (error) {
      if (isHostFailure(error)) failed?.call(Reconnect._(_DialFailed(error)));
      rethrow;
    }
    supervisor._trusted = verifier.verified ?? verifier.pinned;
    supervisor._hold(lease);
    try {
      return await startup(supervisor);
    } catch (error) {
      unawaited(supervisor.drop(const _StartupAbandoned()));
      if (isHostFailure(error)) failed?.call(Reconnect._(_DialFailed(error)));
      rethrow;
    }
  }

  Future<HostLease> _claim(HostTarget target, HostKeyVerifier verifier) =>
      _links.claim(
        address: target.address,
        port: target.port,
        user: target.user,
        privateKey: target.privateKey,
        verifier: verifier,
        use: HostUse.tab,
      );
}

final class _SettleWait {
  _SettleWait(this._within);

  final Duration? _within;
  final _spent = Completer<bool>();
  Timer? _limit;

  Future<void> out(DialSettling settling, StackTrace stack) async {
    final within = _within;
    if (within == null) return settling.settled;
    _limit ??= Timer(within, () => _spent.complete(false));
    final lifted = await Future.any([
      settling.settled.then((_) => true),
      _spent.future,
    ]);
    if (!lifted) Error.throwWithStackTrace(settling, stack);
  }

  void end() => _limit?.cancel();

  Future<T> outlast<T>(Future<T> Function() dial) async {
    try {
      while (true) {
        try {
          return await dial();
        } on DialSettling catch (settling, stack) {
          await out(settling, stack);
        }
      }
    } finally {
      end();
    }
  }
}

/// One supervisor's hold on one lease. Its channels answer null once the supervisor holds
/// another lease, even one on the same link.
final class _Hold implements HostChannels {
  _Hold(this._owner, this.lease);

  final ConnectionSupervisor _owner;
  final HostLease lease;

  @override
  Future<ExecResult?> exec(
    String command, {
    Uint8List? stdin,
    required Duration timeout,
  }) async {
    if (!identical(_owner._held, this)) return null;
    return _run(lease, command, stdin: stdin, timeout: timeout);
  }
}
