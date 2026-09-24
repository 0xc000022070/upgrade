import 'dart:async';

import 'herdr_client.dart';
import 'host_keys.dart';

class HerdrSessionPool {
  HerdrSessionPool(
    this._client, {
    this.idle = const Duration(seconds: 30),
    this.reuse = const Duration(seconds: 5),
    this.now = DateTime.now,
  });

  final HerdrClient _client;
  final Duration idle;

  /// A live session lists in well under a second; one silent this long has lost its socket,
  /// and TCP takes minutes to say so. Half the poll's beat, so the redial lands in the next.
  final Duration reuse;

  // Wall time: timers run on the monotonic clock, which stops while the phone sleeps.
  final DateTime Function() now;
  final _held = <String, _Held>{};
  final _settling = <String, Future<void>>{};

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
      held = null;
    }
    if (held != null) {
      try {
        return await held.list(now(), within: reuse);
      } catch (_) {
        _drop(key, held);
        // Only a session that had worked is worth a second dial: a host that refused the
        // first one would just refuse it again, a beat later.
        if (!held.ready) rethrow;
      }
    }

    // A failed dial keeps authenticating until sshd lets go, and every one still open counts
    // against MaxStartups: a second dial while it settles is how the user's own gets dropped.
    if (_settling.containsKey(key)) {
      throw const HerdrUnreachable('an earlier dial is still settling');
    }
    late final _Held created;
    final fresh = _held[key] ??= created = _Held(
      _client.connect(
        address: address,
        port: port,
        user: user,
        privateKey: privateKey,
        verifier: verifier,
        onSettling: (settled) => _settle(key, settled),
      ),
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

  void _settle(String key, Future<void> settled) {
    _settling[key] = settled;
    settled.whenComplete(() {
      if (identical(_settling[key], settled)) _settling.remove(key);
    });
  }
}

class _Held {
  _Held(this._session, this._idle, this.usedAt, this._expire) {
    _session.then((_) {
      ready = true;
    }, onError: (_) {});
    _arm();
  }

  final Future<HerdrSession> _session;
  final Duration _idle;
  final void Function() _expire;
  Timer? _timer;
  bool ready = false;
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
