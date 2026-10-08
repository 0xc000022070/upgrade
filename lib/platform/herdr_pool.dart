import 'dart:async';

import 'package:dartssh2/dartssh2.dart';

import 'herdr_client.dart';
import 'host_keys.dart';
import 'host_links.dart';

class HerdrSessionPool {
  HerdrSessionPool(
    this._links, {
    this.borrow = HerdrSession.borrowed,
    this.idle = const Duration(seconds: 30),
    this.reuse = const Duration(seconds: 5),
    this.now = DateTime.now,
  });

  final HostLinks _links;
  final HerdrSession Function(HostLease lease) borrow;
  final Duration idle;

  /// A live session lists in well under a second; one silent this long has lost its socket,
  /// and TCP takes minutes to say so. Half the poll's beat, so the redial lands in the next.
  final Duration reuse;

  // Wall time: timers run on the monotonic clock, which stops while the phone sleeps.
  final DateTime Function() now;
  final _held = <String, _Held>{};

  Future<List<AgentSnapshot>> fetch({
    required String address,
    required int port,
    required String user,
    required String privateKey,
    HostKeyVerifier? verifier,
  }) async {
    final pinned = verifier?.pinned;
    final key = [
      user,
      address,
      port,
      pinned?.type,
      pinned?.fingerprint,
      privateKey.hashCode,
    ].join('\u0000');

    var held = _held[key];
    if (held != null && now().difference(held.usedAt) >= idle) {
      _drop(key, held);
      if (held.client case final client?) await _links.vouch(client);
      held = null;
    }
    if (held != null) {
      try {
        return await held.list(now(), within: reuse);
      } on TimeoutException {
        _drop(key, held);
        if (held.client case final client?) await _links.vouch(client);
        if (!held.ready) rethrow;
      } catch (_) {
        _drop(key, held);
        if (!held.ready) rethrow;
      }
    }

    late final _Held created;
    final fresh = _held[key] ??= created = _Held(
      _links.lease(
        address: address,
        port: port,
        user: user,
        privateKey: privateKey,
        verifier: verifier,
        caller: 'herdr poll',
      ),
      borrow,
      idle,
      now(),
      () => _drop(key, created),
    );
    try {
      return await fresh.list(now());
    } catch (_) {
      _drop(key, fresh);
      rethrow;
    }
  }

  void close() {
    for (final held in _held.values) {
      held.close();
    }
    _held.clear();
  }

  void _drop(String key, _Held? held) {
    if (held == null || !identical(_held[key], held)) return;
    _held.remove(key);
    held.close();
  }
}

class _Held {
  _Held(
    Future<HostLease> lease,
    HerdrSession Function(HostLease lease) borrow,
    this._idle,
    this.usedAt,
    this._expire,
  ) {
    _session = lease.then((lease) {
      client = lease.client;
      return borrow(lease);
    });
    _session.then((_) {
      ready = true;
    }, onError: (_) {});
    _arm();
  }

  late final Future<HerdrSession> _session;
  final Duration _idle;
  final void Function() _expire;
  Timer? _timer;
  bool ready = false;
  SSHClient? client;
  DateTime usedAt;

  Future<List<AgentSnapshot>> list(DateTime at, {Duration? within}) async {
    usedAt = at;
    _arm();
    final session = await _session;
    final listed = session.list();
    return within == null ? listed : listed.timeout(within);
  }

  void _arm() {
    _timer?.cancel();
    _timer = Timer(_idle, _expire);
  }

  void close() {
    _timer?.cancel();
    _session.then((session) => session.close(), onError: (_) {});
  }
}
