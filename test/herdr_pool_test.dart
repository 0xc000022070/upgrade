import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/platform/herdr_client.dart';
import 'package:dazzle/platform/herdr_pool.dart';
import 'package:dazzle/platform/host_keys.dart';

class _Session implements HerdrSession {
  _Session(this.id);

  final int id;
  bool broken = false;
  bool closed = false;
  Completer<List<AgentSnapshot>>? gate;

  @override
  Future<List<AgentSnapshot>> list() async {
    final pending = gate;
    if (pending != null) return pending.future;
    if (broken) throw const HerdrUnreachable('dropped');
    return const [];
  }

  @override
  Future<void> close() async => closed = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client extends HerdrClient {
  _Client();

  final sessions = <_Session>[];

  @override
  Future<HerdrSession> connect({
    required String address,
    required int port,
    required String user,
    required String privateKey,
    HostKeyVerifier? verifier,
  }) async {
    final session = _Session(sessions.length);
    sessions.add(session);
    return session;
  }
}

Future<List<AgentSnapshot>> _fetch(HerdrSessionPool pool) => pool.fetch(
  address: '10.0.0.2',
  port: 22,
  user: 'luisnquin',
  privateKey: 'key',
);

void main() {
  test('two fetches failing on one session redial once between them', () async {
    final client = _Client();
    final pool = HerdrSessionPool(client);
    await _fetch(pool);
    final first = client.sessions.single..gate = Completer();

    final a = _fetch(pool);
    final b = _fetch(pool);
    await pumpEventQueue();
    first
      ..broken = true
      ..gate!.completeError(const HerdrUnreachable('dropped'));
    await Future.wait([a, b]);

    expect(client.sessions, hasLength(2));
    expect(first.closed, isTrue);
    expect(client.sessions.last.closed, isFalse);
    pool.close();
  });
}
