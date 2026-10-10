import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;

import 'herdr_client.dart';
import 'host_key_dial.dart';
import 'host_keys.dart';
import 'ssh_settle.dart';

typedef SshLink = ({
  SSHSocket socket,
  SSHClient client,
  int Function() received,
});

typedef SshDial = Future<SshLink> Function({
  required String address,
  required int port,
  required String user,
  required String privateKey,
  required HostKeyVerifier verifier,
  void Function(Future<void> settled)? onSettling,
});

enum HostLane { control, screen }

enum HostUse {
  tab('tab'),
  herdrPoll('herdr poll'),
  send('send'),
  launchScan('launch scan'),
  pathScan('path scan'),
  workspace('workspace'),
  pluginScheduler('plugin scheduler'),
  alertAction('alert action'),
  engineOpen('engine open'),
  engineFetch('engine fetch'),
  watcher('watcher'),
  devices('devices'),
  vnc('vnc'),
  deviceDock('device dock');

  const HostUse(this.label);

  final String label;

  HostLane get lane => switch (this) {
    vnc || deviceDock => HostLane.screen,
    tab ||
    herdrPoll ||
    send ||
    launchScan ||
    pathScan ||
    workspace ||
    pluginScheduler ||
    alertAction ||
    engineOpen ||
    engineFetch ||
    watcher ||
    devices => HostLane.control,
  };

  bool get yields => this != tab;

  bool get wakes => switch (this) {
    tab || send || alertAction => true,
    herdrPoll ||
    launchScan ||
    pathScan ||
    workspace ||
    pluginScheduler ||
    engineOpen ||
    engineFetch ||
    watcher ||
    devices ||
    vnc ||
    deviceDock => false,
  };
}

/// A dial refused before it starts, because an earlier failed dial to the same identity is
/// still authenticating. [settled] completes, never with an error, once that one lets go.
final class DialSettling extends SocketException {
  DialSettling(this.settled) : super('an earlier dial is still settling');

  final Future<void> settled;
}

/// RFC 4254 open-failure codes a host answers a session with at its session limit;
/// OpenSSH sends SSH_OPEN_CONNECT_FAILED past MaxSessions.
const _sessionLimitCodes = {1, 2};

class HostLease {
  HostLease._(this._links, this._link, this.use);

  final HostLinks _links;
  final _Link _link;
  final HostUse use;
  var _released = false;

  SSHClient get client => _link.client;

  bool get closed => _released || _link.ended || _link.client.isClosed;

  Future<void> get ended => _link.over.future;

  Future<SSHSession> execute(String command, {SSHPtyConfig? pty}) =>
      _links._session(this, (client) => client.execute(command, pty: pty));

  Future<SSHSession> shell(SSHPtyConfig pty) =>
      _links._session(this, (client) => client.shell(pty: pty));

  /// Runs one keepalive round now, beside the periodic ones, and answers whether the link
  /// lives. With no answer and no other traffic within [HostLinks.answer], the link ends for
  /// every holder. A check already running is joined, never doubled.
  Future<bool> check() =>
      _released ? Future.value(false) : _links._check(_link);

  Future<bool> answers() =>
      _released ? Future.value(false) : _links._answers(_link, use);

  void release() {
    if (_released) return;
    _released = true;
    _links._release(this);
  }
}

final class HostTarget {
  const HostTarget(this.address, this.port, this.user, this.privateKey);

  final String address;
  final int port;
  final String user;
  final String privateKey;

  String _identity(PinnedHostKey? pin) => [
    user,
    address,
    port,
    pin?.type,
    pin?.fingerprint,
    privateKey.hashCode,
  ].join('\u0000');

  bool _same(HostTarget other) =>
      other.user == user &&
      other.address == address &&
      other.port == port &&
      other.privateKey == privateKey;
}

class _Link {
  _Link(this.ssh, this.name, this.use, this.target, this.trusted, this.heardAt)
    : heard = ssh.received();

  final SshLink ssh;
  final String name;
  final HostUse use;
  final HostTarget target;
  final PinnedHostKey? trusted;
  final leases = <HostLease>{};
  String? key;
  Timer? linger;
  DateTime? idleSince;
  Future<String?>? checking;
  int heard;
  DateTime heardAt;
  bool ended = false;
  final over = Completer<void>.sync();
  Timer? keepAlive;
  var probed = 0;
  var answered = true;
  var misses = 0;

  _Link? parent;
  _Link? overflow;
  Future<_Link>? overflowing;
  var sessions = 0;

  SSHClient get client => ssh.client;
  HostLane get lane => use.lane;
}

class _Settle {
  _Settle(this.target);

  final HostTarget target;
  final _lifted = Completer<void>();

  Future<void> get settled => _lifted.future;

  void lift() {
    if (!_lifted.isCompleted) _lifted.complete();
  }
}

class _Pending {
  _Pending(this.target, this.lane);

  final HostTarget target;
  final HostLane lane;
  late final Future<_Link> link;
  var renounced = false;
}

/// Owns every SSH connection in this isolate: per host identity, one control link, one
/// screen link and one overflow control link. [probe] dials outside this pool.
class HostLinks {
  HostLinks({
    SshDial? dial,
    this.timeout = const Duration(seconds: 10),
    this.keepAlive = sshKeepAlive,
    this.keepAliveMisses = 3,
    this.linger = const Duration(seconds: 30),
    this.screenLinger = const Duration(seconds: 5),
    this.answer = const Duration(seconds: 5),
    this.quiet = const Duration(seconds: 5),
    this.now = DateTime.now,
  }) : _injected = dial;

  final SshDial? _injected;
  late final SshDial _dial = _injected ?? _authenticated;
  final Duration timeout;
  final Duration keepAlive;
  final int keepAliveMisses;
  final Duration linger;
  final Duration screenLinger;
  final Duration answer;

  final Duration quiet;
  final DateTime Function() now;

  final _links = <String, _Link>{};
  final _dialing = <String, _Pending>{};
  final _settling = <String, _Settle>{};
  final _all = <_Link>{};
  final _renounced = <String, Object>{};
  var _closed = false;
  var _asleep = false;
  var _serial = 0;
  var _leases = 0;

  @visibleForTesting
  int get open => _all.length;

  @visibleForTesting
  int get granted => _leases;

  @visibleForTesting
  int get held => _all.fold(0, (count, link) => count + link.leases.length);

  Future<HostLease> lease({
    required String address,
    required int port,
    required String user,
    required String privateKey,
    required HostKeyVerifier verifier,
    required HostUse use,
  }) async {
    try {
      return await claim(
        address: address,
        port: port,
        user: user,
        privateKey: privateKey,
        verifier: verifier,
        use: use,
      );
    } catch (error) {
      throw asHerdrFailure(error, verifier.refusal) ?? error;
    }
  }

  Future<HostLease> claim({
    required String address,
    required int port,
    required String user,
    required String privateKey,
    required HostKeyVerifier verifier,
    required HostUse use,
  }) async {
    final target = HostTarget(address, port, user, privateKey);
    final pinned = verifier.pinned;
    final identity = target._identity(pinned);
    final key = '$identity\u0000${use.lane.name}';
    _Pending? mine;
    while (true) {
      if (_closed) throw const SocketException('host links closed');
      if (_asleep && !use.wakes) {
        throw const SocketException('host links asleep');
      }
      if (pinned != null) {
        final live = _links[key];
        if (live != null) {
          if (await _vouched(live, use) && !live.ended) {
            _log(live.name, 'reuse by ${use.label}');
            return _granted(live, use);
          }
          continue;
        }
        final pending = _dialing[key];
        if (pending != null) {
          final link = await pending.link;
          if (identical(pending, mine)) return _landed(link, use);
          if (link.ended) continue;
          _log(link.name, 'reuse in-flight dial by ${use.label}');
          return _granted(link, use);
        }
      }
      // A failed dial keeps authenticating until sshd lets go, counting against MaxStartups.
      // Dialling again during that window is how the user's own dial gets dropped.
      final settling = _settling[identity];
      if (settling != null) throw DialSettling(settling.settled);
      final pending = _Pending(target, use.lane);
      pending.link = _dialLink(target, verifier, use, identity).then((link) {
        if (pending.renounced) {
          _end(link, 'network changed while dialling');
          return link;
        }
        final filed = verifier.verified ?? pinned;
        if (filed != null) {
          final fileKey = '${target._identity(filed)}\u0000${use.lane.name}';
          if (!_links.containsKey(fileKey)) {
            _links[fileKey] = link;
            link.key = fileKey;
          }
        }
        return link;
      });
      if (pinned == null) return _landed(await pending.link, use);
      mine = pending;
      _dialing[key] = pending;
      pending.link.then((_) {}, onError: (_) {}).whenComplete(() {
        if (identical(_dialing[key], pending)) _dialing.remove(key);
      });
    }
  }

  void renounce({
    required String address,
    required int port,
    required String user,
    required String privateKey,
    required Object change,
  }) {
    final target = HostTarget(address, port, user, privateKey);
    final place = target._identity(null);
    if (identical(_renounced[place], change)) return;
    _renounced[place] = change;
    for (final link in [..._all]) {
      if (link.parent == null &&
          link.lane == HostLane.control &&
          link.target._same(target)) {
        _end(link, 'network changed');
      }
    }
    _dialing.removeWhere((_, pending) {
      final gone =
          pending.lane == HostLane.control && pending.target._same(target);
      if (gone) pending.renounced = true;
      return gone;
    });
    // A settling dial's socket is on the path that just went away.
    _settling.removeWhere((_, settle) {
      final gone = settle.target._same(target);
      if (gone) settle.lift();
      return gone;
    });
  }

  /// Runs [HostLease.check] on every link, held or lingering. After a network change a link
  /// on the old path goes silent long before its keepalive would notice.
  Future<void> recheckAll() => Future.wait([
    for (final link in [..._all]) _check(link),
  ]);

  void sleep() {
    _asleep = true;
    for (final link in [..._all]) {
      for (final lease in [...link.leases]) {
        if (!lease.use.yields || lease._released) continue;
        lease._released = true;
        link.leases.remove(lease);
        _log(link.name, 'yield by ${lease.use.label}');
      }
      if (link.parent == null && link.leases.isEmpty) _end(link, 'asleep');
    }
  }

  void wake() => _asleep = false;

  static Future<void> probe({
    required String address,
    required int port,
    required String user,
    required String privateKey,
    required HostKeyVerifier verifier,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final offered = Completer<void>();
    final decided = Completer<void>();
    final broken = Completer<void>();
    _log('$address:$port', 'dial by host key probe');
    final socket = await SSHSocket.connect(address, port, timeout: timeout);
    final client = _client(socket, user, privateKey, sshKeepAlive, (
      type,
      fingerprint,
    ) async {
      if (!offered.isCompleted) offered.complete();
      try {
        return await verifier.verify(type, fingerprint);
      } finally {
        if (!decided.isCompleted) decided.complete();
      }
    });
    unawaited(
      client.authenticated.then(
        (_) {},
        onError: (Object error, StackTrace stack) {
          if (!broken.isCompleted) broken.completeError(error, stack);
        },
      ),
    );
    try {
      await Future.any([offered.future, broken.future])
          .timeout(timeout, onTimeout: () => throw const HostKeySilent());
      await decided.future;
    } finally {
      unawaited(
        offered.isCompleted
            ? closeSettled(client, socket)
            : closeSsh(client, socket),
      );
    }
  }

  Future<SshLink> _authenticated({
    required String address,
    required int port,
    required String user,
    required String privateKey,
    required HostKeyVerifier verifier,
    void Function(Future<void> settled)? onSettling,
  }) async {
    final socket = _CountingSocket(
      await SSHSocket.connect(address, port, timeout: timeout),
    );
    return authenticatedLink(
      socket,
      _client(socket, user, privateKey, null, verifier.verify),
      () => socket.received,
      verifier: verifier,
      timeout: timeout,
      onSettling: onSettling,
    );
  }

  void close() {
    _closed = true;
    for (final link in [..._all]) {
      _end(link, 'pool closed');
    }
    _links.clear();
    _dialing.clear();
  }

  Future<_Link> _dialLink(
    HostTarget target,
    HostKeyVerifier verifier,
    HostUse use,
    String settleKey, {
    _Link? parent,
  }) async {
    final role = parent == null ? use.lane.name : 'overflow';
    final name = '${target.address}:${target.port} $role #${++_serial}';
    _log(name, 'dial by ${use.label}');
    final SshLink ssh;
    try {
      ssh = await _dial(
        address: target.address,
        port: target.port,
        user: target.user,
        privateKey: target.privateKey,
        verifier: verifier,
        onSettling: (settled) => _settle(settleKey, target, settled),
      );
    } catch (error) {
      _log(name, 'dial failed by ${use.label}: ${error.runtimeType}');
      rethrow;
    }
    final link = _Link(
      ssh,
      name,
      use,
      target,
      verifier.verified ?? verifier.pinned,
      now(),
    )..parent = parent;
    _all.add(link);
    if (_closed) {
      _end(link, 'pool closed');
      throw const SocketException('host links closed');
    }
    ssh.client.done.then(
      (_) => _end(link, 'client done'),
      onError: (Object error) => _end(link, 'client done: $error'),
    );
    link.keepAlive = Timer.periodic(keepAlive, (_) => _probe(link));
    return link;
  }

  void _probe(_Link link) {
    if (link.ended) return;
    final received = link.ssh.received();
    link.misses = link.answered || received != link.probed
        ? 0
        : link.misses + 1;
    if (link.misses >= keepAliveMisses) {
      _end(link, 'keepalive unanswered');
      return;
    }
    link.probed = received;
    link.answered = false;
    link.client.ping().then<void>(
      (_) => link.answered = true,
      onError: (Object _) {},
    );
  }

  /// A link quiet past [quiet] is pinged before reuse: a held one only for a waking use,
  /// set aside by [_answers]; an unheld one ended if nothing comes back.
  Future<bool> _vouched(_Link link, HostUse use) async {
    if (link.ended) return false;
    if (link.client.isClosed) {
      _end(link, 'client closed');
      return false;
    }
    if (link.leases.isNotEmpty) {
      return !use.wakes ||
          now().difference(link.heardAt) < quiet ||
          await _answers(link, use);
    }
    final idle = link.idleSince;
    if (idle != null && now().difference(idle) >= _lingerOf(link)) {
      _end(link, 'linger expired');
      return false;
    }
    if (_fresh(link)) return true;
    final silent = await _round(link);
    if (silent != null && link.leases.isEmpty) {
      _end(link, 'ping $silent');
      return false;
    }
    return !link.ended;
  }

  bool _fresh(_Link link) {
    final heard = link.ssh.received();
    if (heard != link.heard) {
      link.heard = heard;
      link.heardAt = now();
      return true;
    }
    return now().difference(link.heardAt) < quiet;
  }

  Future<bool> _check(_Link link) async {
    if (link.ended) return false;
    if (link.client.isClosed) {
      _end(link, 'client closed');
      return false;
    }
    final silent = await _round(link);
    if (silent != null) _end(link, 'keepalive $silent on check');
    return !link.ended;
  }

  Future<bool> _answers(_Link link, HostUse use) async {
    if (link.ended) return false;
    if (link.client.isClosed) {
      _end(link, 'client closed');
      return false;
    }
    final silent = await _round(link);
    if (silent == null) return !link.ended;
    final key = link.key;
    if (key != null && identical(_links[key], link)) {
      _links.remove(key);
      _log(link.name, 'set aside, ping $silent by ${use.label}');
      if (link.leases.isEmpty) _end(link, 'released unfiled');
    }
    return false;
  }

  Future<String?> _round(_Link link) {
    final checking = link.checking;
    if (checking != null) return checking;
    final round = _ping(link);
    link.checking = round;
    return round.whenComplete(() {
      if (identical(link.checking, round)) link.checking = null;
    });
  }

  Future<String?> _ping(_Link link) async {
    final seen = link.ssh.received();
    try {
      await link.client.ping().timeout(answer);
    } on TimeoutException {
      if (link.ssh.received() == seen) return 'unanswered';
    } catch (error) {
      // ignored: returned as the round's reason; each caller decides whether to log it.
      return 'failed: $error';
    }
    link.heard = link.ssh.received();
    link.heardAt = now();
    return null;
  }

  HostLease _landed(_Link link, HostUse use) {
    if (link.ended) {
      throw const SocketException('the link ended as its dial landed');
    }
    return _granted(link, use);
  }

  HostLease _granted(_Link link, HostUse use) {
    if (_asleep && !use.wakes) {
      if (link.leases.isEmpty) _end(link, 'landed asleep');
      throw const SocketException('host links asleep');
    }
    return _hold(link, use);
  }

  HostLease _hold(_Link link, HostUse use) {
    link.linger?.cancel();
    link.linger = null;
    link.idleSince = null;
    final lease = HostLease._(this, link, use);
    _leases++;
    link.leases.add(lease);
    return lease;
  }

  void _release(HostLease lease) {
    final link = lease._link;
    if (!link.leases.remove(lease) || link.leases.isNotEmpty || link.ended) {
      return;
    }
    final key = link.key;
    if (_asleep) {
      _end(link, 'released asleep');
    } else if (key == null || !identical(_links[key], link)) {
      _end(link, 'released unfiled');
    } else {
      final idle = now();
      link.idleSince = idle;
      final received = link.ssh.received();
      if (received != link.heard) {
        link.heard = received;
        link.heardAt = idle;
      }
      link.linger = Timer(_lingerOf(link), () => _end(link, 'linger expired'));
    }
  }

  Duration _lingerOf(_Link link) => switch (link.lane) {
    HostLane.control => linger,
    HostLane.screen => screenLinger,
  };

  Future<SSHSession> _session(
    HostLease lease,
    Future<SSHSession> Function(SSHClient client) open,
  ) async {
    if (lease._released) throw SSHStateError('The lease was let go.');
    final link = lease._link;
    try {
      return await open(link.client);
    } on SSHChannelOpenError catch (error) {
      if (!_sessionLimitCodes.contains(error.code) ||
          link.lane != HostLane.control ||
          link.ended) {
        rethrow;
      }
      var spill = await _overflow(link, lease.use);
      // The overflow may have ended with its last session while this waited.
      if (spill.ended) spill = await _overflow(link, lease.use);
      if (spill.ended) rethrow;
      spill.sessions++;
      final SSHSession session;
      try {
        session = await open(spill.client);
      } catch (_) {
        _spilled(spill);
        rethrow;
      }
      session.done.then(
        (_) => _spilled(spill),
        onError: (_) => _spilled(spill),
      );
      return session;
    }
  }

  Future<_Link> _overflow(_Link parent, HostUse use) {
    final live = parent.overflow;
    if (live != null && !live.ended) return Future.value(live);
    final dialing = parent.overflowing;
    if (dialing != null) return dialing;
    final identity = parent.target._identity(parent.trusted);
    final dial =
        _dialLink(
          parent.target,
          HostKeyVerifier.pinnedOnly(parent.trusted),
          use,
          '$identity\u0000overflow',
          parent: parent,
        ).then((link) {
          if (parent.ended) {
            _end(link, 'parent ended');
            throw SSHStateError('The link this overflowed ended.');
          }
          parent.overflow = link;
          return link;
        });
    parent.overflowing = dial;
    dial.then((_) {}, onError: (_) {}).whenComplete(() {
      if (identical(parent.overflowing, dial)) parent.overflowing = null;
    });
    return dial;
  }

  void _spilled(_Link spill) {
    if (--spill.sessions > 0) return;
    _end(spill, 'overflow idle');
  }

  void _end(_Link link, String why) {
    final key = link.key;
    if (key != null && identical(_links[key], link)) _links.remove(key);
    link.linger?.cancel();
    link.linger = null;
    link.keepAlive?.cancel();
    link.keepAlive = null;
    _all.remove(link);
    final parent = link.parent;
    if (parent != null && identical(parent.overflow, link)) {
      parent.overflow = null;
    }
    if (link.ended) return;
    link.ended = true;
    _log(link.name, 'end, $why, dialed by ${link.use.label}');
    unawaited(closeSsh(link.client, link.ssh.socket));
    final overflow = link.overflow;
    if (overflow != null) _end(overflow, 'parent ended');
    link.over.complete();
  }

  void _settle(String key, HostTarget target, Future<void> settled) {
    final settle = _Settle(target);
    _settling[key] = settle;
    void lift() {
      settle.lift();
      if (identical(_settling[key], settle)) _settling.remove(key);
    }

    settled.then((_) => lift(), onError: (Object _) => lift());
  }
}

Future<SshLink> authenticatedLink(
  SSHSocket socket,
  SSHClient client,
  int Function() received, {
  required HostKeyVerifier verifier,
  required Duration timeout,
  void Function(Future<void> settled)? onSettling,
}) async {
  try {
    await authenticatedWithin(client.authenticated, verifier, timeout);
    return (socket: socket, client: client, received: received);
  } catch (_) {
    onSettling?.call(closeSettled(client, socket));
    rethrow;
  }
}

void _log(String name, String message) =>
    debugPrint('upgrade.ssh $name: $message');

SSHClient _client(
  SSHSocket socket,
  String user,
  String privateKey,
  Duration? keepAlive,
  SSHHostkeyVerifyHandler verify,
) => SSHClient(
  socket,
  username: user,
  identities: SSHKeyPair.fromPem(privateKey),
  keepAliveInterval: keepAlive,
  onVerifyHostKey: verify,
);

class _CountingSocket implements SSHSocket {
  _CountingSocket(this._inner) {
    stream = _inner.stream.map((bytes) {
      received += bytes.length;
      return bytes;
    });
  }

  final SSHSocket _inner;
  var received = 0;

  @override
  late final Stream<Uint8List> stream;

  @override
  StreamSink<List<int>> get sink => _inner.sink;

  @override
  Future<void> get done => _inner.done;

  @override
  Future<void> close() => _inner.close();

  @override
  void destroy() => _inner.destroy();

  @override
  Future<void> flush() => _inner.flush();
}
