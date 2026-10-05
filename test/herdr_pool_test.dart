import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/platform/herdr_client.dart';
import 'package:upgrade/platform/herdr_pool.dart';
import 'package:upgrade/platform/host_keys.dart';
import 'package:upgrade/platform/host_links.dart';
import 'package:upgrade/platform/ssh_settle.dart';

import 'support/host_links.dart';

class _Session implements HerdrSession {
  _Session(this.lease);

  final HostLease lease;
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
  void close() {
    closed = true;
    lease.release();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final _pin = PinnedHostKey(
  type: 'ssh-ed25519',
  fingerprint: 'SHA256:vm',
  pinnedAt: DateTime(2026),
);

class _Rig {
  _Rig({FakeDial? dial, DateTime Function()? now}) : dial = dial ?? FakeDial() {
    links = HostLinks(dial: this.dial.call, now: now ?? DateTime.now);
    pool = HerdrSessionPool(
      links,
      borrow: (lease) {
        final session = _Session(lease);
        sessions.add(session);
        return session;
      },
      now: now ?? DateTime.now,
    );
  }

  final FakeDial dial;
  late final HostLinks links;
  late final HerdrSessionPool pool;
  final sessions = <_Session>[];

  Future<List<AgentSnapshot>> fetch() => pool.fetch(
    address: '10.0.0.2',
    port: 22,
    user: 'luisnquin',
    privateKey: 'key',
    verifier: HostKeyVerifier.pinnedOnly(_pin),
  );

  void close() {
    pool.close();
    links.close();
  }
}

void main() {
  test('two fetches failing on one session redial once between them', () async {
    final rig = _Rig();
    await rig.fetch();
    final first = rig.sessions.single..gate = Completer();

    final a = rig.fetch();
    final b = rig.fetch();
    await pumpEventQueue();
    first
      ..broken = true
      ..gate!.completeError(const HerdrUnreachable('dropped'));
    await Future.wait([a, b]);

    expect(rig.sessions, hasLength(2));
    expect(first.closed, isTrue);
    expect(rig.sessions.last.closed, isFalse);
    rig.close();
  });

  test('a refused dial fails the fetch and nothing else', () async {
    final rig = _Rig(dial: FakeDial(refuse: true));
    await expectLater(rig.fetch(), throwsA(isA<HerdrUnreachable>()));
    await pumpEventQueue();
    rig.close();
  });

  testWidgets(
    'a held session that stops answering on a dead link is redialled once the ping goes unanswered',
    (tester) async {
      final rig = _Rig();
      await rig.fetch();
      final dead = rig.sessions.single..gate = Completer();
      rig.dial.clients.single.pong = Completer();

      var answered = false;
      unawaited(rig.fetch().then((_) => answered = true));
      await tester.pump(const Duration(seconds: 6, milliseconds: 999));
      expect(answered, isFalse);
      await tester.pump(const Duration(milliseconds: 1));

      expect(answered, isTrue);
      expect(rig.dial.dials, 2);
      expect(rig.dial.clients.first.isClosed, isTrue);
      expect(dead.closed, isTrue);
      expect(rig.sessions.last.closed, isFalse);
      rig.close();
    },
  );

  testWidgets(
    'a held session that stops answering on a live link is replaced over the same link',
    (tester) async {
      final rig = _Rig();
      await rig.fetch();
      final dead = rig.sessions.single..gate = Completer();

      var answered = false;
      unawaited(rig.fetch().then((_) => answered = true));
      await tester.pump(const Duration(seconds: 5));

      expect(answered, isTrue);
      expect(rig.dial.dials, 1);
      expect(rig.dial.clients.single.isClosed, isFalse);
      expect(dead.closed, isTrue);
      expect(rig.sessions, hasLength(2));
      rig.close();
    },
  );

  testWidgets('a dial still settling fails the fetch without a second dial', (
    tester,
  ) async {
    final rig = _Rig(dial: FakeDial(slowAuth: true));
    final failures = <HerdrFailure>[];
    var polling = true;
    unawaited(() async {
      while (polling) {
        try {
          await rig.fetch();
        } on HerdrFailure catch (failure) {
          failures.add(failure);
        }
        await Future<void>.delayed(const Duration(seconds: 10));
      }
    }());
    await tester.pump(const Duration(minutes: 2));

    expect(rig.dial.dials, 1);
    expect(failures, isNotEmpty);
    expect(failures.every((failure) => failure is HerdrUnreachable), isTrue);

    polling = false;
    rig.close();
    await tester.pump(sshLoginGrace + const Duration(seconds: 30));
  });

  group('a session idle past its window by the wall clock', () {
    late DateTime at;
    late _Rig rig;

    setUp(() {
      at = DateTime(2026, 9, 24, 12);
      rig = _Rig(now: () => at);
    });

    tearDown(() => rig.close());

    test('is replaced on the first fetch after a sleep', () async {
      await rig.fetch();
      at = at.add(const Duration(minutes: 5));
      await rig.fetch();

      expect(rig.sessions, hasLength(2));
      expect(rig.sessions.first.closed, isTrue);
      expect(rig.sessions.last.closed, isFalse);
      expect(rig.dial.dials, 1);
      expect(rig.dial.clients.single.pings, 1);
      expect(rig.sessions.last.lease.client, same(rig.dial.clients.single));
    });

    testWidgets('waits out an unanswered ping, then dials once', (
      tester,
    ) async {
      await rig.fetch();
      rig.dial.clients.single.pong = Completer();
      at = at.add(const Duration(minutes: 5));
      var answered = false;
      unawaited(rig.fetch().then((_) => answered = true));

      await tester.pump(const Duration(seconds: 1, milliseconds: 999));
      expect(answered, isFalse);
      expect(rig.dial.dials, 1);
      await tester.pump(const Duration(milliseconds: 1));

      expect(answered, isTrue);
      expect(rig.dial.dials, 2);
      expect(rig.dial.clients.first.isClosed, isTrue);
      expect(rig.sessions.last.lease.client, same(rig.dial.clients.last));
      rig.close();
    });

    test('is dialled fresh when its link does not answer the ping', () async {
      await rig.fetch();
      rig.dial.clients.single.pingError = StateError('gone');
      at = at.add(const Duration(minutes: 5));
      await rig.fetch();

      expect(rig.dial.dials, 2);
      expect(rig.dial.clients.first.isClosed, isTrue);
      expect(rig.dial.clients.last.isClosed, isFalse);
    });

    test('is still shared inside its window', () async {
      await rig.fetch();
      at = at.add(const Duration(seconds: 29));
      await rig.fetch();
      at = at.add(const Duration(seconds: 29));
      await rig.fetch();

      expect(rig.sessions, hasLength(1));
      expect(rig.sessions.single.closed, isFalse);
    });
  });
}
