import 'dart:async';

import 'herdr_client.dart';
import 'host_keys.dart';

class HerdrSessionPool {
  HerdrSessionPool(this._client, {this.idle = const Duration(seconds: 30)});

  final HerdrClient _client;
  final Duration idle;
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

    final held = _held[key];
    if (held != null) {
      try {
        return await held.list();
      } catch (_) {
        _drop(key, held);
        // Only a session that had worked is worth a second dial: a host that refused the
        // first one would just refuse it again, a beat later.
        if (!held.ready) rethrow;
      }
    }

    final fresh = _Held(
      _client.connect(
        address: address,
        port: port,
        user: user,
        privateKey: privateKey,
        verifier: verifier,
      ),
      idle,
      () => _drop(key, _held[key]),
    );
    _held[key] = fresh;
    try {
      return await fresh.list();
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
  _Held(this._session, this._idle, this._expire) {
    _session.then((_) => ready = true, onError: (_) {});
    _arm();
  }

  final Future<HerdrSession> _session;
  final Duration _idle;
  final void Function() _expire;
  Timer? _timer;
  bool ready = false;

  Future<List<AgentSnapshot>> list() async {
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
