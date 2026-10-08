import 'dart:async';

import 'package:upgrade/platform/herdr_client.dart';
import 'package:upgrade/platform/host_keys.dart';
import 'package:upgrade/platform/host_links.dart';
import 'package:upgrade/platform/ssh_settle.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/host_links.dart';

PinnedHostKey _key(String fingerprint) => PinnedHostKey(
  type: 'ssh-ed25519',
  fingerprint: fingerprint,
  pinnedAt: DateTime(2026),
);

final _vm = _key('SHA256:vm');

Future<HostLease> _lease(HostLinks links, [HostKeyVerifier? verifier]) =>
    links.lease(
      address: '10.0.0.2',
      port: 22,
      user: 'dev',
      privateKey: 'key',
      verifier: verifier ?? HostKeyVerifier.pinnedOnly(_vm),
      caller: 'test',
    );

void main() {
  test('two leases asked for while one dial is out share it', () async {
    final dial = FakeDial()..gate = Completer();
    final links = HostLinks(dial: dial.call);
    final a = _lease(links);
    final b = _lease(links);
    await pumpEventQueue();
    dial.gate!.complete();

    final leases = await Future.wait([a, b]);
    expect(dial.dials, 1);
    expect(identical(leases.first.client, leases.last.client), isTrue);
    links.close();
  });

  testWidgets('a link let go lingers thirty seconds, then closes', (
    tester,
  ) async {
    final dial = FakeDial();
    final links = HostLinks(dial: dial.call);
    (await _lease(links)).release();
    await tester.pump(const Duration(seconds: 29));
    final again = await _lease(links);
    expect(dial.dials, 1);
    again.release();

    await tester.pump(const Duration(seconds: 29));
    expect(dial.clients.single.isClosed, isFalse);
    await tester.pump(const Duration(seconds: 1));
    expect(dial.clients.single.isClosed, isTrue);

    await _lease(links);
    expect(dial.dials, 2);
    links.close();
  });

  test('a link let go before a sleep is dialled fresh after it', () async {
    var at = DateTime(2026, 10, 3, 12);
    final dial = FakeDial();
    final links = HostLinks(dial: dial.call, now: () => at);
    (await _lease(links)).release();
    at = at.add(const Duration(seconds: 31));

    await _lease(links);
    expect(dial.dials, 2);
    expect(dial.clients.first.isClosed, isTrue);
    links.close();
  });

  testWidgets('a held link outlives the linger', (tester) async {
    final dial = FakeDial();
    final links = HostLinks(dial: dial.call);
    final held = await _lease(links);
    (await _lease(links)).release();
    await tester.pump(const Duration(minutes: 2));

    expect(dial.clients.single.isClosed, isFalse);
    held.release();
    links.close();
  });

  test('another pin on the same host gets its own link', () async {
    final dial = FakeDial();
    final links = HostLinks(dial: dial.call);
    final vm = await _lease(links);
    final other = await _lease(
      links,
      HostKeyVerifier.pinnedOnly(_key('SHA256:other')),
    );
    expect(dial.dials, 2);
    expect(identical(vm.client, other.client), isFalse);
    links.close();
  });

  test('an asking verifier under the same pin joins the link', () async {
    final dial = FakeDial();
    final links = HostLinks(dial: dial.call);
    final quiet = await _lease(links);
    final asking = await _lease(
      links,
      HostKeyVerifier(pinned: _vm, prompt: (_, _) async => true),
    );
    expect(dial.dials, 1);
    expect(identical(quiet.client, asking.client), isTrue);
    links.close();
  });

  test(
    'an unpinned dial is never joined, then files under the key it pinned',
    () async {
      final dial = FakeDial()..accept = _vm;
      final links = HostLinks(dial: dial.call);
      HostKeyVerifier asking() =>
          HostKeyVerifier(prompt: (_, _) async => true, pin: (_) async {});

      final first = await _lease(links, asking());
      final second = await _lease(links, asking());
      expect(dial.dials, 2);
      expect(identical(first.client, second.client), isFalse);

      final pinned = await _lease(links);
      expect(dial.dials, 2);
      expect(identical(pinned.client, first.client), isTrue);

      second.release();
      expect(dial.clients.last.isClosed, isTrue);
      links.close();
    },
  );

  test('a dropped link is dialled once for everyone, and old leases leave the new one be', () async {
    final dial = FakeDial();
    final links = HostLinks(dial: dial.call);
    final old = await _lease(links);
    await dial.clients.single.close();
    await pumpEventQueue();

    final fresh = await Future.wait([
      _lease(links),
      _lease(links),
      _lease(links),
    ]);
    expect(dial.dials, 2);
    expect(
      fresh.every((lease) => identical(lease.client, fresh.first.client)),
      isTrue,
    );

    old.release();
    expect(dial.clients.last.isClosed, isFalse);
    links.close();
  });

  testWidgets('no second dial goes out while the first is still settling', (
    tester,
  ) async {
    final dial = FakeDial(slowAuth: true);
    final links = HostLinks(dial: dial.call);
    final failures = <Object>[];
    var polling = true;
    unawaited(() async {
      while (polling) {
        try {
          await _lease(links);
        } catch (error) {
          failures.add(error);
        }
        await Future<void>.delayed(const Duration(seconds: 10));
      }
    }());
    await tester.pump(const Duration(minutes: 2));

    expect(dial.dials, 1);
    expect(dial.settling, 1);
    expect(failures, isNotEmpty);
    expect(failures.every((failure) => failure is HerdrUnreachable), isTrue);

    await tester.pump(const Duration(seconds: 15));
    expect(dial.settling, 0);
    expect(dial.dials, 2);

    polling = false;
    links.close();
    await tester.pump(sshLoginGrace + const Duration(seconds: 30));
  });

  test('a refused dial fails every lease waiting on it, and the next one dials again', () async {
    final dial = FakeDial(refuse: true)..gate = Completer();
    final links = HostLinks(dial: dial.call);
    final a = _lease(links);
    final b = _lease(links);
    await pumpEventQueue();
    dial.gate!.complete();

    await expectLater(a, throwsA(isA<HerdrUnreachable>()));
    await expectLater(b, throwsA(isA<HerdrUnreachable>()));
    expect(dial.dials, 1);

    await expectLater(_lease(links), throwsA(isA<HerdrUnreachable>()));
    expect(dial.dials, 2);
    links.close();
  });

  group('a link vouched for', () {
    test('stays when the ping answers', () async {
      final dial = FakeDial();
      final links = HostLinks(dial: dial.call);
      final lease = await _lease(links);
      await links.vouch(lease.client);
      expect(dial.clients.single.isClosed, isFalse);
      links.close();
    });

    testWidgets('closes when the ping goes unanswered', (tester) async {
      final dial = FakeDial();
      final links = HostLinks(dial: dial.call);
      final lease = await _lease(links);
      dial.clients.single.pong = Completer();
      unawaited(links.vouch(lease.client));
      await tester.pump(const Duration(seconds: 2));

      expect(dial.clients.single.isClosed, isTrue);
      await _lease(links);
      expect(dial.dials, 2);
      links.close();
    });

    testWidgets('stays when bytes arrive while the ping is queued', (
      tester,
    ) async {
      final dial = FakeDial();
      final links = HostLinks(dial: dial.call);
      final lease = await _lease(links);
      final client = dial.clients.single..pong = Completer();
      var settled = false;
      unawaited(lease.suspect().then((_) => settled = true));
      await tester.pump(const Duration(seconds: 1));
      client.received += 4096;
      await tester.pump(const Duration(seconds: 1));

      expect(settled, isTrue);
      expect(client.isClosed, isFalse);
      expect(client.closes, 0);
      links.close();
    });

    testWidgets('under steady traffic answers in one window, once', (
      tester,
    ) async {
      final dial = FakeDial();
      final links = HostLinks(dial: dial.call);
      final lease = await _lease(links);
      final client = dial.clients.single..pong = Completer();
      unawaited(lease.suspect());

      HostLease? next;
      for (var tick = 1; tick <= 15; tick++) {
        await tester.pump(const Duration(milliseconds: 200));
        client.received += 1024;
        if (tick == 2) {
          await tester.pump(const Duration(milliseconds: 100));
          unawaited(_lease(links).then((lease) => next = lease));
        }
        if (tick < 10) expect(next, isNull);
        if (tick == 10) expect(next?.client, same(client));
      }

      expect(client.pings, 1);
      expect(dial.dials, 1);
      links.close();
    });

    test('closes when the ping fails', () async {
      final dial = FakeDial();
      final links = HostLinks(dial: dial.call);
      final lease = await _lease(links);
      dial.clients.single.pingError = StateError('gone');
      await links.vouch(lease.client);
      expect(dial.clients.single.isClosed, isTrue);
      links.close();
    });

    test('is left alone once nothing files it', () async {
      final dial = FakeDial()..accept = _vm;
      final links = HostLinks(dial: dial.call);
      HostKeyVerifier asking() =>
          HostKeyVerifier(prompt: (_, _) async => true, pin: (_) async {});
      await _lease(links, asking());
      final unfiled = await _lease(links, asking());
      dial.clients.last.pingError = StateError('gone');

      await links.vouch(unfiled.client);
      await links.vouch(FakeLinkClient());
      expect(dial.clients.last.pings, 0);
      expect(dial.clients.last.isClosed, isFalse);
      links.close();
    });

    test('a closed link is ended without a ping', () async {
      final dial = FakeDial();
      final links = HostLinks(dial: dial.call);
      final lease = await _lease(links);
      dial.clients.single.gone.complete();

      await links.vouch(lease.client);
      expect(dial.clients.single.pings, 0);
      await _lease(links);
      expect(dial.dials, 2);
      links.close();
    });
  });

  group('a link suspected', () {
    test('twice makes one ping', () async {
      final dial = FakeDial();
      final links = HostLinks(dial: dial.call);
      final lease = await _lease(links);
      dial.clients.single.pong = Completer();
      lease
        ..suspect()
        ..suspect();
      await pumpEventQueue();
      expect(dial.clients.single.pings, 1);
      links.close();
    });

    testWidgets('holds a lease until the ping settles, then redials once', (
      tester,
    ) async {
      final dial = FakeDial();
      final links = HostLinks(dial: dial.call);
      final lease = await _lease(links);
      dial.clients.single.pong = Completer();
      lease.suspect();

      HostLease? next;
      unawaited(_lease(links).then((lease) => next = lease));
      await tester.pump(const Duration(seconds: 1, milliseconds: 999));
      expect(next, isNull);
      await tester.pump(const Duration(milliseconds: 1));

      expect(next?.client, same(dial.clients.last));
      expect(dial.dials, 2);
      expect(dial.clients.first.isClosed, isTrue);
      links.close();
    });

    testWidgets('by an engine call that timed out is dialled fresh', (
      tester,
    ) async {
      final dial = FakeDial();
      final links = HostLinks(dial: dial.call);
      final session = HerdrSession.borrowed(await _lease(links));
      dial.clients.single.pong = Completer();

      Object? failure;
      unawaited(
        session
            .engine(const {}, within: const Duration(seconds: 15))
            .then((_) {}, onError: (Object error) => failure = error),
      );
      await tester.pump(const Duration(seconds: 15));
      expect(failure, isA<TimeoutException>());
      expect(dial.clients.single.pings, 1);
      session.close();

      await tester.pump(const Duration(seconds: 10));
      final next = await _lease(links);
      expect(dial.dials, 2);
      expect(next.client, same(dial.clients.last));
      links.close();
    });
  });

  testWidgets('a lease let go twice counts once', (tester) async {
    final dial = FakeDial();
    final links = HostLinks(dial: dial.call);
    final held = await _lease(links);
    final twice = await _lease(links);
    twice
      ..release()
      ..release();
    await tester.pump(const Duration(minutes: 1));

    expect(dial.clients.single.isClosed, isFalse);
    held.release();
    links.close();
  });

  test('closing closes every link', () async {
    final dial = FakeDial();
    final links = HostLinks(dial: dial.call);
    await _lease(links);
    await _lease(links, HostKeyVerifier.pinnedOnly(_key('SHA256:other')));
    links.close();
    expect(dial.clients.every((client) => client.isClosed), isTrue);
  });
}
