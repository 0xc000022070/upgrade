import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/platform/herdr_client.dart';
import 'package:dazzle/platform/herdr_pool.dart';
import 'package:dazzle/platform/host_keys.dart';
import 'package:dazzle/platform/ssh_settle.dart';

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
  _Client({this.refuse = false, this.slowAuth = false});

  final bool refuse;
  final bool slowAuth;
  final sessions = <_Session>[];
  var dials = 0;
  var settling = 0;

  @override
  Future<HerdrSession> connect({
    required String address,
    required int port,
    required String user,
    required String privateKey,
    HostKeyVerifier? verifier,
    void Function(Future<void> settled)? onSettling,
  }) async {
    dials++;
    if (refuse) throw const HerdrUnreachable('refused');
    if (slowAuth) {
      await Future<void>.delayed(const Duration(seconds: 10));
      settling++;
      onSettling?.call(
        Future<void>.delayed(sshLoginGrace).whenComplete(() => settling--),
      );
      throw const HerdrUnreachable('no answer in 10s');
    }
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

  test('a refused dial fails the fetch and nothing else', () async {
    final pool = HerdrSessionPool(_Client(refuse: true));
    await expectLater(_fetch(pool), throwsA(isA<HerdrUnreachable>()));
    await pumpEventQueue();
    pool.close();
  });

  testWidgets('a held session that stops answering is redialled in 5 s', (
    tester,
  ) async {
    final client = _Client();
    final pool = HerdrSessionPool(client);
    await _fetch(pool);
    final dead = client.sessions.single..gate = Completer();

    var answered = false;
    unawaited(_fetch(pool).then((_) => answered = true));
    await tester.pump(const Duration(seconds: 4, milliseconds: 999));
    expect(answered, isFalse);
    await tester.pump(const Duration(milliseconds: 1));

    expect(answered, isTrue);
    expect(client.sessions, hasLength(2));
    expect(dead.closed, isTrue);
    expect(client.sessions.last.closed, isFalse);
    pool.close();
  });

  testWidgets('no second dial goes out while the first is still settling', (
    tester,
  ) async {
    final client = _Client(slowAuth: true);
    final pool = HerdrSessionPool(client);
    final failures = <HerdrFailure>[];
    var polling = true;
    unawaited(() async {
      while (polling) {
        try {
          await _fetch(pool);
        } on HerdrFailure catch (failure) {
          failures.add(failure);
        }
        await Future<void>.delayed(const Duration(seconds: 10));
      }
    }());
    await tester.pump(const Duration(minutes: 2));

    expect(client.dials, 1);
    expect(client.settling, 1);
    expect(failures, isNotEmpty);
    expect(failures.every((failure) => failure is HerdrUnreachable), isTrue);

    await tester.pump(const Duration(seconds: 15));
    expect(client.settling, 0);
    expect(client.dials, 2);

    polling = false;
    pool.close();
    await tester.pump(sshLoginGrace + const Duration(seconds: 30));
  });

  group('a session idle past its window by the wall clock', () {
    late DateTime at;
    late _Client client;
    late HerdrSessionPool pool;

    setUp(() {
      at = DateTime(2026, 9, 24, 12);
      client = _Client();
      pool = HerdrSessionPool(client, now: () => at);
    });

    tearDown(() => pool.close());

    test('is dialled fresh on the first fetch after a sleep', () async {
      await _fetch(pool);
      at = at.add(const Duration(minutes: 5));
      await _fetch(pool);

      expect(client.sessions, hasLength(2));
      expect(client.sessions.first.closed, isTrue);
      expect(client.sessions.last.closed, isFalse);
    });

    test('is still shared inside its window', () async {
      await _fetch(pool);
      at = at.add(const Duration(seconds: 29));
      await _fetch(pool);
      at = at.add(const Duration(seconds: 29));
      await _fetch(pool);

      expect(client.sessions, hasLength(1));
      expect(client.sessions.single.closed, isFalse);
    });
  });
}
