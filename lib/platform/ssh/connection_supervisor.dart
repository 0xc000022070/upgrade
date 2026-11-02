/// SSH connection policy.
///
/// Why: a probe's timeout once replaced a live connection under a typed SEND
/// (incident write-up: `git show f168971`). A connection is durable state: commands,
/// probes and timeouts borrow it and never close, replace or retry it.
///
/// Tags name what holds a rule. Untagged: privacy or a sealed type; breaking it fails to
/// compile. (fence): `test/platform/ssh/ssh_fence_test.dart` holds the allowed call sites. (tested: x):
/// `test/x_test.dart` covers it. (convention): review only.
///
/// Who owns what:
/// - [HostLinks] is the pool: it alone opens sockets (fence) and closes them (convention).
///   Everyone else takes a [HostLease] and releases it; the pool decides when an idle link
///   ends (tested: host_links).
/// - [ConnectionSupervisor] is one tab's claim on its host. Only the shell tunnel holds
///   one, from [SshConnector.establish] (fence), and takes its raw pty [SSHSession] from
///   [ConnectionSupervisor.pty]. Other code runs commands through a [HostChannels] view,
///   which answers null while no host is held and never dials.
/// - [HostLinks.claim], [HostLinks.renounce], [HostLinks.sleep], [HostLinks.wake],
///   [HostLinks.recheckAll], [HostLinks.close], [HostUse.tab], [HostUse.ownTab] and
///   [HostLease.client] are used only where the fence allows (fence).
///
/// Lanes: a pool keeps one control link and one screen link per host identity, and
/// [HostUse.lane] picks the link (tested: host_links). A tab opened [HostUse.alone] dials a
/// control link of its own that nothing else rides and that ends with it. Outside this sit
/// the [HostLinks.probe] host key check, one overflow control link for a host at its session
/// limit, one transfer link a file goes up on so it never queues behind or ahead of a held
/// link's keepalive ([HostLease.sftp], [HostLease.upload]), and a silent link a waking use
/// set aside for its holders. One pool per isolate
/// (convention: a caller passing none gets a new pool).
///
/// Reasons. Every reason type is sealed and lives in `reasons.dart`:
/// - A tab's claim, drop, renounce or revive takes a reason. Only an [OpenReason] or
///   [ReopenReason] dials; a [DropReason] only lets go. Every switch over reasons is
///   exhaustive.
/// - No reason stands for a failed command. A probe or command on a handed-out connection
///   is never evidence the host is gone, and is never retried on that host (tested:
///   ssh_lifecycle_model, shell_tunnel).
/// - [UserClosed], [ShellEnded], [_StartupAbandoned] and [_Unclaimed] end one tab's claim.
///   [NetworkChanged] and a dead link end the link for every tab on it; their redials to a
///   pinned host key join one dial in flight (tested: host_links, host_owner).
///
/// When a tab may dial again:
/// - Only this library mints [Reconnect]: from a [ShellEnded], or from a dial that failed
///   on the host or link, startup steps of [SshConnector.establish] included. Only
///   [SshConnector.establish] accepts one, so it always makes a fresh supervisor.
/// - Only the supervisor under the ended terminal mints its [ShellEnded]
///   ([ConnectionSupervisor.terminalEnded]); any other supervisor's drop refuses it
///   (tested: ssh_lifecycle_model).
/// - A terminal silent past its health window has ended (tested: shell_tunnel).
/// - Besides the revive below, only `ShellSessions`' reconnect schedule for a dropped tab
///   and its banner watch over a waiting tab dial on a timer, with a [Reconnect] (convention).
///
/// Liveness, settling, sleep (tested: host_links, host_owner, ssh_lifecycle_model,
/// shell_sessions):
/// - No timeout, probe or command ends a held link. Besides the explicit ends (network
///   change, sleep, pool close, the transport closing), only an unanswered keepalive does.
///   [ConnectionSupervisor.check] runs one keepalive round early; a startup command past
///   its deadline counts as the link's failure only when that round goes unanswered.
/// - A gesture, or a waking use on a link not heard within [HostLinks.quiet], asks for one
///   round first ([ConnectionSupervisor.answers]). On silence it dials beside the link,
///   which stays for its holders until their own keepalive ends it.
/// - [HealthCheckFailed] comes only from [HostLease.ended] and drops the supervisor whose
///   link died. If its transport asked through [ConnectionSupervisor.reopenWhenHostDies],
///   that supervisor alone reopens itself on the fixed [_reviveDelays] schedule.
/// - A dial refused with [DialSettling] (an earlier failed dial still authenticating) waits
///   for it, which is not a failure or a revive step. A [UserAction] waits at most
///   [SshConnector.timeout], other reasons as long as it takes.
/// - Past the sleep grace, only a live plain-SSH terminal's control link stays, and only a
///   use with [HostUse.wakes] may lease beside it. Mosh and engine tabs let go of theirs
///   with [AppSuspended].
///
/// Tokens prove a person or the platform caused an action:
/// - [UserIntent] and [PlatformSignal] come only from callbacks their wrappers build, such
///   as [UserIntent.onGesture]. Each wrapper is called only in its slot, and a token rides
///   only in the landing fields the fence lists, each read once (fence).
/// - One token builds one reason. The one exception: [UserClosed.by] builds the close for a
///   [UserAction]'s gesture on that action's spend (fence).
/// - A token's second reason, or a [UserIntent] older than [UserIntent.window], is refused
///   wherever it would dial or drop, logged and asserted (tested: ssh_reason_spend).
/// - Gap: nothing catches one prompt spend, in the window, on a path no person or platform
///   event started.
/// - An alert tapped before mount is a cold launch with no intent (convention).
///
/// Changing the rules: a new part file, token wrapper, raw host path or reason type needs
/// the owner's approval. The fence fails on the first three; only review catches a new
/// reason type.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import 'package:upgrade/platform/ssh/host_failure.dart';
import 'package:upgrade/platform/ssh/host_files.dart';
import 'package:upgrade/platform/ssh/host_keys.dart';
import 'package:upgrade/platform/ssh/host_links.dart';
import 'package:upgrade/platform/ssh/ssh_settle.dart';

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

  Future<FileWrite?> put(
    String path,
    FileBody body, {
    required Duration timeout,
    PutProgress? onProgress,
  });
}

/// A tab's claim on its host's shared control link. Its channels answer null once it lets go.
final class ConnectionSupervisor implements HostChannels {
  ConnectionSupervisor._(this._connector, this._target, this._use);

  final SshConnector _connector;
  final HostTarget _target;
  final HostUse _use;
  PinnedHostKey? _trusted;
  _State _state = const _Idle();
  var _claimed = false;
  ShellEnded? _ended;
  var _revives = false;
  Timer? _revival;
  final _control = StreamController<ControlLink>.broadcast();
  var _reportedDown = false;

  late final HostChannels channels = _Channels(this);

  _Live? get _live => switch (_state) {
    final _Live live => live,
    _Suspended(:final live) => live,
    _Retired() => null,
  };

  _Hold? get _held => switch (_live) {
    _Held(:final hold) => hold,
    _Idle() || _Dialing() || null => null,
  };

  _Dial? get _dial => switch (_live) {
    _Dialing(:final dial) => dial,
    _Idle() || _Held() || null => null,
  };

  bool get _down => switch (_state) {
    _Idle() || _Dialing() => true,
    _Held() || _Suspended() || _Retired() => false,
  };

  /// A suspension outlasts what a gesture holds under it; a retired supervisor stays so.
  void _become(_Live live) => _state = switch (_state) {
    _Suspended() => _Suspended(live),
    _Live() => live,
    _Retired() => _state,
  };

  @override
  Future<ExecResult?> exec(
    String command, {
    Uint8List? stdin,
    required Duration timeout,
  }) async => _held?.exec(command, stdin: stdin, timeout: timeout);

  @override
  Future<FileWrite?> put(
    String path,
    FileBody body, {
    required Duration timeout,
    PutProgress? onProgress,
  }) async => _held?.put(path, body, timeout: timeout, onProgress: onProgress);

  Stream<ControlLink> get controlLink => _control.stream;

  String get endpoint => '${_target.address}:${_target.port}';

  /// Answers null when the tab is gone or the app is away, and throws what the dial threw.
  /// A gesture dials again once if a network change overtook its dial, and waits out settles
  /// for [SshConnector.timeout] at most; a resume or a network change waits out every settle.
  Future<HostChannels?> open(ReopenReason reason) {
    if (_refuses(reason, endpoint)) return Future.value();
    return switch (reason) {
      UserAction() ||
      AppResumed() ||
      NetworkChanged() => _openUntilHeld(reason),
      _HostDied() => _open(reason).future,
    };
  }

  Future<HostChannels?> _openUntilHeld(ReopenReason reason) async {
    final attended = reason is UserAction;
    final settles = _SettleWait(attended ? _connector.timeout : null);
    var overtakeLeft = attended;
    final held = _held;
    if (attended && held != null && !await held.lease.answers()) {
      if (identical(_held, held)) {
        _become(const _Idle());
        _log('set aside a silent host');
        _report();
        held.lease.release();
      }
    }
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
            if (_state case _Retired() || _Suspended() when !attended) {
              return null;
            }
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
    final _Live live;
    switch (_state) {
      case _Retired():
        return _Dial.none();
      case final _Live awake:
        live = awake;
      case _Suspended(live: final asleep):
        switch (reason) {
          case AppResumed():
            _state = live = asleep;
            _report();
          case _HostDied():
            return _Dial.none();
          case NetworkChanged() when asleep is! _Held:
            return _Dial.none();
          case UserAction() || NetworkChanged():
            live = asleep;
        }
    }
    switch (live) {
      case _Held(:final hold):
        return _Dial.settled(hold);
      case _Dialing(:final dial):
        return dial;
      case _Idle():
        final dial = _Dial();
        _become(_Dialing(dial));
        dial.future = _redial(reason, dial).whenComplete(() {
          if (identical(_dial, dial)) _become(const _Idle());
        });
        return dial;
    }
  }

  /// Revives a dead host on a schedule, for a transport whose terminal outlives its host.
  void reopenWhenHostDies() => _revives = true;

  void _revive(_HostDied reason, int step) {
    _revival?.cancel();
    _revival = Timer(_reviveDelays[step], () async {
      _revival = null;
      if (!_down) return;
      try {
        await open(reason);
      } catch (error) {
        if (!_down) return;
        if (error is DialSettling) {
          await error.settled;
          if (!_down || _revival != null) return;
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
    final down = _down;
    if (down == _reportedDown || _control.isClosed) return;
    _reportedDown = down;
    _control.add(down ? const ControlReconnecting() : const ControlUp());
  }

  void _giveUp(Object error) {
    _log('revival stopped on $error');
    if (!_reportedDown || _control.isClosed) return;
    _control.add(ControlGaveUp(error));
  }

  /// Answers whether [drop] takes [reason]: false where it would refuse or throw.
  bool accepts(DropReason reason) {
    if (reason case ShellEnded(:final _of) when !identical(_of, this)) {
      return false;
    }
    return !_refuses(reason, endpoint);
  }

  /// Throws, before dropping anything, for a [ShellEnded] another supervisor minted.
  Future<void> drop(DropReason reason) {
    if (_refuses(reason, endpoint)) return Future.value();
    final dial = _dial;
    final held = _held;
    switch (reason) {
      case ShellEnded(:final _of) when !identical(_of, this):
        throw ArgumentError.value(reason, 'reason', 'ended another terminal');
      case UserClosed() || ShellEnded() || _StartupAbandoned() || _Unclaimed():
        _state = const _Retired();
      case AppSuspended():
        if (_state is! _Retired) _state = const _Suspended(_Idle());
      case NetworkChanged() || HealthCheckFailed():
        _become(const _Idle());
    }
    // Leaving [_Dialing] makes a dial still in flight release its lease when it lands.
    dial?.overtaken = reason is NetworkChanged;
    if (held != null) _log('drop for ${reason.runtimeType}');
    final retired = _state is _Retired;
    if (retired || _state is _Suspended) {
      _revival?.cancel();
      _revival = null;
    }
    _report();
    if (retired && !_control.isClosed) unawaited(_control.close());
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

  Future<bool> check() async => await _held?.lease.check() ?? false;

  Future<bool> answers() async => await _held?.lease.answers() ?? true;

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
        _use,
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
    final held = _Hold(this, lease);
    _become(_Held(held));
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

sealed class _State {
  const _State();
}

sealed class _Live extends _State {
  const _Live();
}

final class _Idle extends _Live {
  const _Idle();
}

final class _Dialing extends _Live {
  const _Dialing(this.dial);

  final _Dial dial;
}

final class _Held extends _Live {
  const _Held(this.hold);

  final _Hold hold;
}

final class _Suspended extends _State {
  const _Suspended(this.live);

  final _Live live;
}

final class _Retired extends _State {
  const _Retired();
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

  @override
  Future<FileWrite?> put(
    String path,
    FileBody body, {
    required Duration timeout,
    PutProgress? onProgress,
  }) => _owner.put(path, body, timeout: timeout, onProgress: onProgress);
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
    bool alone = false,
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
    final use = alone ? HostUse.ownTab : HostUse.tab;
    final supervisor = ConnectionSupervisor._(this, target, use)
      .._log('dial for ${purpose.cause}');
    final HostLease lease;
    try {
      lease = await _SettleWait(purpose.attended ? timeout : null)
          .outlast(() => _claim(target, verifier, use));
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

  Future<HostLease> _claim(
    HostTarget target,
    HostKeyVerifier verifier,
    HostUse use,
  ) => _links.claim(
    address: target.address,
    port: target.port,
    user: target.user,
    privateKey: target.privateKey,
    verifier: verifier,
    use: use,
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

  @override
  Future<FileWrite?> put(
    String path,
    FileBody body, {
    required Duration timeout,
    PutProgress? onProgress,
  }) async {
    if (!identical(_owner._held, this)) return null;
    return putFile(
      sftp: lease.sftp,
      exec: (command, feed) =>
          transferExec(lease, command, feed: feed, timeout: timeout),
      path: path,
      body: body,
      timeout: timeout,
      onProgress: onProgress,
    );
  }
}
