/// SSH connection policy.
///
/// [HostLinks] alone opens and closes sockets; every other holder only leases and releases,
/// so a command, timeout or probe can never close or replace a connection. A tab's claim,
/// drop, renounce and revive additionally need a sealed [OpenReason], [ReopenReason] or
/// [DropReason], and only an open or reopen reason redials a tab. Why: a probe's timeout
/// once replaced a live connection under a typed SEND; see `SSH-CONNECTION-INCIDENT.md`.
///
/// Guaranteed by this library's `_` privacy and its sealed reasons:
/// - Outside code holds no host or supervisor, only [HostChannels] views that answer null
///   while no host is held.
/// - [HealthCheckFailed] comes only from [HostLease.ended]. [ShellEnded] comes only from,
///   and is accepted only by, the supervisor under the terminal that ended.
/// - [Reconnect] is minted only here, from a [ShellEnded] or a dial that failed on the host
///   or link, and only a fresh supervisor accepts it. A [HealthCheckFailed] reopens only its
///   own host's supervisor, and no caller can hand it one. A timer dials for nothing else.
/// - A dial includes the startup steps [SshConnector.establish] runs; a probe or command
///   on a handed-out connection is never evidence, and is never retried on the same host.
/// - No reason is a command failure, and every switch over reasons is exhaustive.
/// - A held host that dies is redialled on a fixed schedule for transports that ask. A
///   terminal silent past its window has ended; a held link ends only by its keepalive.
///   [check] is one keepalive round, run early on a stalled write or a rehome.
/// - A dial refused while an earlier one settles ([DialSettling]) waits for that settle;
///   it is not a failure and spends no step of the schedule. A [UserAction] waits no
///   longer in all than [SshConnector.timeout], then fails on the refusal.
/// - One owner per host per isolate: one control and one screen link per identity, a
///   [HostUse] fixing the lane. [UserClosed], [ShellEnded], [_StartupAbandoned] and
///   [_Unclaimed] release one tab's claim; [NetworkChanged] and a dead link end it for all,
///   with one redial. Beside it: other identities or isolates, the trust probe, one overflow.
/// - Past the sleep grace the app holds only a live plain-SSH terminal's control link, and
///   only [HostUse.wakes] uses lease beside it.
/// [UserIntent] is minted only in a gesture handler and [PlatformSignal] only in a platform
/// callback. Privacy cannot hold that, nor who calls [SshConnector.establish], the public
/// [HostLinks] controls or [HostLease.client]; `test/ssh_fence_test.dart` pins each call
/// site by name. A new part, public reason constructor, raw host path or reason variant
/// needs the owner's approval.
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

/// Held, or the app away: nothing reads stale.
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
  /// Null with no host held; never dials. A [timeout] covers the channel open, and closes
  /// the channel, never the host.
  Future<ExecResult?> exec(
    String command, {
    Uint8List? stdin,
    required Duration timeout,
  });
}

/// One tab's claim on its host's shared control link; [open]'s channels outlive it as null.
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

  /// Null when the tab is gone or the app away; throws what the dial threw. A gesture whose
  /// dial a network change overtook, or an earlier dial's settle refused, opens again once;
  /// a resume or a network change waits out every settle that refuses it.
  Future<HostChannels?> open(ReopenReason reason) => switch (reason) {
    UserAction() || AppResumed() || NetworkChanged() => _openUntilHeld(reason),
    _HostDied() => _open(reason).future,
  };

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

  /// Only for a transport whose terminal outlives its host; a plain SSH terminal dies with it.
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

  /// Throws, before anything is dropped, for an end another supervisor minted.
  Future<void> drop(DropReason reason) {
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
    // A dial in flight is no longer [_dial] when it lands, so it is closed.
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

  /// Called only from the terminal's own end; the same end every time.
  ShellEnded terminalEnded() => _ended ??= ShellEnded._(this);

  void claim() => _claimed = true;

  bool get claimed => _claimed;

  /// Drops a connection nobody ever read: false, and nothing dropped, once one has.
  Future<bool> discard() async {
    if (_claimed) return false;
    await drop(const _Unclaimed());
    return true;
  }

  Future<void> check() async => _held?.lease.check();

  Future<SSHSession> pty(String? command, SSHPtyConfig config) async {
    final lease = _held?.lease;
    // What dartssh2 throws for a gone client, so the tab reads it as a lost stream.
    if (lease == null) throw SSHStateError('No SSH host is held.');
    // An exec request, not a shell one, is what makes a detach end the channel like `exit`.
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

/// Then it stops: a host still gone waits for a gesture, a resume or a network.
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

  /// A [startup] that throws drops the host first: a half-open connection counts against
  /// the host until its own timeout. A host or link failure hands [failed] its [Reconnect].
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
    final purpose = _purpose(reason);
    // Nobody is there to answer for an unpinned key: such an open refuses it instead.
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

/// One hold of a host by one supervisor. The channels it hands out answer null once the
/// supervisor holds another, even a lease on the same link.
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
