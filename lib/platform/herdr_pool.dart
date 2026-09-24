import 'dart:async';

import 'herdr_client.dart';
import 'host_keys.dart';

class HerdrSessionPool {
  HerdrSessionPool(
    this._client, {
    this.idle = const Duration(seconds: 30),
    this.now = DateTime.now,
  });

  final HerdrClient _client;
  final Duration idle;

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
      held = null;
    }
    if (held != null) {
      try {
        return await held.list(now());
      } catch (_) {
        _drop(key, held);
        // Only a session that had worked is worth a second dial: a host that refused the
        // first one would just refuse it again, a beat later.
        if (!held.ready) rethrow;
      }
    }

    late final _Held created;
    final fresh = _held[key] ??= created = _Held(
      _client.connect(
        address: address,
        port: port,
        user: user,
        privateKey: privateKey,
        verifier: verifier,
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

  Future<List<AgentSnapshot>> list(DateTime at) async {
    usedAt = at;
    _arm();
    return (await _session).list();
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
