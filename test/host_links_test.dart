import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:upgrade/platform/herdr_client.dart';
import 'package:upgrade/platform/host_keys.dart';
import 'package:upgrade/platform/host_links.dart';
import 'package:upgrade/platform/ssh_settle.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/host_links.dart';
import 'support/ssh_exec.dart';

PinnedHostKey _key(String fingerprint) => PinnedHostKey(
  type: 'ssh-ed25519',
  fingerprint: fingerprint,
  pinnedAt: DateTime(2026),
);

final _vm = _key('SHA256:vm');

Future<HostLease> _lease(HostLinks links, [HostKeyVerifier? verifier]) =>
    _leaseAs(links, HostUse.send, verifier);

Future<HostLease> _leaseAs(
  HostLinks links,
  HostUse use, [
  HostKeyVerifier? verifier,
]) => links.lease(
  address: '10.0.0.2',
  port: 22,
  user: 'dev',
  privateKey: 'key',
  verifier: verifier ?? HostKeyVerifier.pinnedOnly(_vm),
  use: use,
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

  testWidgets(
    'the settling gate throws a refusal that says when the settle ends',
    (tester) async {
      final dial = FakeDial(slowAuth: true);
      final links = HostLinks(dial: dial.call);
      Future<HostLease> claim() => links.claim(
        address: '10.0.0.2',
        port: 22,
        user: 'dev',
        privateKey: 'key',
        verifier: HostKeyVerifier.pinnedOnly(_vm),
        use: HostUse.send,
      );
      unawaited(claim().then((_) {}, onError: (Object _) {}));
      await tester.pump(const Duration(seconds: 10));

      Object? refused;
      try {
        await claim();
      } catch (error) {
        refused = error;
      }
      expect(refused, isA<DialSettling>());
      var settled = false;
      unawaited((refused! as DialSettling).settled.then((_) => settled = true));
      await tester.pump(sshLoginGrace);
      expect(settled, isTrue);
      expect(dial.dials, 1);

      links.close();
    },
  );

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

  group('the reuse check', () {
    late DateTime at;
    late FakeDial dial;
    late HostLinks links;

    setUp(() {
      at = DateTime(2026);
      dial = FakeDial();
      links = HostLinks(dial: dial.call, now: () => at);
    });

    tearDown(() => links.close());

    Future<void> idle() async {
      (await _lease(links)).release();
      at = at.add(links.quiet);
    }

    testWidgets(
      'never pings a held link for a use nobody waits on, however long it stays quiet',
      (tester) async {
        links.close();
        links = HostLinks(
          dial: dial.call,
          now: () => at,
          keepAlive: const Duration(days: 1),
        );
        final held = await _lease(links);
        dial.clients.single.pong = Completer();
        at = at.add(const Duration(hours: 1));
        await tester.pump(const Duration(hours: 1));
        final beside = await _leaseAs(links, HostUse.herdrPoll);

        expect(dial.clients.single.pings, 0);
        expect(dial.dials, 1);
        expect(held.closed || beside.closed, isFalse);
        links.close();
      },
    );

    test('checks a quiet held link before a use someone waits on, and reuses it on an answer', () async {
      final held = await _lease(links);
      at = at.add(links.quiet);
      final beside = await _leaseAs(links, HostUse.tab);

      expect(dial.clients.single.pings, 1);
      expect(dial.dials, 1);
      expect(held.closed || beside.closed, isFalse);
    });

    test(
      'trusts a held link heard within quiet for a use someone waits on',
      () async {
        final held = await _lease(links);
        at = at.add(links.quiet - const Duration(seconds: 1));
        final soon = await _leaseAs(links, HostUse.tab);

        expect(dial.clients.single.pings, 0);
        expect(dial.dials, 1);
        expect(held.closed || soon.closed, isFalse);
      },
    );

    testWidgets(
      'checks a held link that received bytes but was not heard within quiet',
      (tester) async {
        final held = await _lease(links);
        dial.clients.single.received += 512;
        at = at.add(const Duration(minutes: 3));
        dial.clients.single.pong = Completer();
        final beside = _leaseAs(links, HostUse.send);
        await tester.pump(links.answer);

        final fresh = await beside;
        expect(dial.clients.first.pings, 1);
        expect(dial.dials, 2);
        expect(identical(fresh.client, dial.clients.last), isTrue);
        expect(held.closed, isFalse);
        links.close();
      },
    );

    testWidgets(
      'dials beside a held link a use someone waits on finds silent, and leaves it to its holder',
      (tester) async {
        final held = await _leaseAs(links, HostUse.herdrPoll);
        dial.clients.single.pong = Completer();
        at = at.add(links.quiet);
        final beside = _leaseAs(links, HostUse.alertAction);
        await tester.pump(links.answer);

        final fresh = await beside;
        expect(held.closed, isFalse);
        expect(dial.clients.first.isClosed, isFalse);
        expect(dial.dials, 2);
        expect(identical(fresh.client, dial.clients.last), isTrue);

        final next = await _leaseAs(links, HostUse.herdrPoll);
        expect(identical(next.client, fresh.client), isTrue);
        expect(dial.dials, 2);

        held.release();
        expect(dial.clients.first.isClosed, isTrue);
        expect(fresh.closed, isFalse);
        links.close();
      },
    );

    testWidgets(
      'a lease that asks whether a silent link answers sets it aside without ending it',
      (tester) async {
        final held = await _leaseAs(links, HostUse.herdrPoll);
        dial.clients.single.pong = Completer();
        final answered = held.answers();
        await tester.pump(links.answer);

        expect(await answered, isFalse);
        expect(held.closed, isFalse);
        await _leaseAs(links, HostUse.herdrPoll);
        expect(dial.dials, 2);

        final checked = held.check();
        await tester.pump(links.answer);
        expect(await checked, isFalse);
        expect(held.closed, isTrue);
        links.close();
      },
    );

    test(
      'pings a quiet link nobody holds and reuses it on an answer',
      () async {
        await idle();
        await _lease(links);

        expect(dial.clients.single.pings, 1);
        expect(dial.dials, 1);
      },
    );

    test('measures quiet from the release of a link that spoke', () async {
      final held = await _lease(links);
      dial.clients.single.received += 512;
      at = at.add(const Duration(minutes: 5));
      held.release();

      at = at.add(links.quiet - const Duration(seconds: 1));
      (await _lease(links)).release();
      expect(dial.clients.single.pings, 0);

      at = at.add(const Duration(seconds: 1));
      await _lease(links);
      expect(dial.clients.single.pings, 1);
      expect(dial.dials, 1);
    });

    test('still pings a link that stayed silent while held', () async {
      final held = await _lease(links);
      at = at.add(const Duration(minutes: 5));
      held.release();
      await _lease(links);

      expect(dial.clients.single.pings, 1);
      expect(dial.dials, 1);
    });

    test('does not ping a link nobody holds that spoke since', () async {
      await idle();
      dial.clients.single.received += 1024;
      await _lease(links);

      expect(dial.clients.single.pings, 0);
      expect(dial.dials, 1);
    });

    testWidgets(
      'ends a link nobody holds when its ping goes unanswered, and every waiting lease shares one redial',
      (tester) async {
        await idle();
        dial.clients.single.pong = Completer();
        final waiting = [_lease(links), _lease(links)];
        await tester.pump(links.answer);
        final leases = await Future.wait(waiting);

        expect(dial.dials, 2);
        expect(dial.clients.first.isClosed, isTrue);
        expect(
          leases.every((lease) => lease.client == dial.clients.last),
          isTrue,
        );
        links.close();
      },
    );

    testWidgets('keeps a link whose bytes arrive while the ping is out', (
      tester,
    ) async {
      await idle();
      final client = dial.clients.single..pong = Completer();
      final next = _lease(links);
      await tester.pump();
      client.received += 4096;
      await tester.pump(links.answer);

      expect((await next).client, same(client));
      expect(client.isClosed, isFalse);
      expect(dial.dials, 1);
      links.close();
    });

    test('ends a link nobody holds whose ping fails', () async {
      await idle();
      dial.clients.single.pingError = StateError('gone');
      await _lease(links);

      expect(dial.clients.first.isClosed, isTrue);
      expect(dial.dials, 2);
    });

    test('ends a closed link without a ping', () async {
      await _lease(links);
      dial.clients.single.gone.complete();
      await pumpEventQueue();

      await _lease(links);
      expect(dial.clients.first.pings, 0);
      expect(dial.dials, 2);
    });
  });

  group('the keepalive', () {
    late FakeDial dial;
    late HostLinks links;

    setUp(() {
      dial = FakeDial();
      links = HostLinks(dial: dial.call);
    });

    tearDown(() => links.close());

    testWidgets('ends a held link after three probes go unanswered', (
      tester,
    ) async {
      final held = await _lease(links);
      final client = dial.clients.single..pong = Completer();

      await tester.pump(links.keepAlive * 3);
      expect(client.pings, 3);
      expect(held.closed, isFalse);

      await tester.pump(links.keepAlive);
      expect(held.closed, isTrue);
      expect(client.isClosed, isTrue);
    });

    testWidgets('counts no miss while any bytes arrive', (tester) async {
      final held = await _lease(links);
      final client = dial.clients.single..pong = Completer();

      for (var probe = 0; probe < 10; probe++) {
        await tester.pump(links.keepAlive);
        client.received += 64;
      }
      expect(held.closed, isFalse);

      await tester.pump(links.keepAlive * 3);
      expect(held.closed, isFalse);
      await tester.pump(links.keepAlive);
      expect(held.closed, isTrue);
    });

    testWidgets('keeps a link whose one answer comes late', (tester) async {
      final held = await _lease(links);
      final client = dial.clients.single..pong = Completer();

      await tester.pump(links.keepAlive * 3 + links.keepAlive ~/ 2);
      client.pong!.complete();
      client.pong = null;
      await tester.pump(links.keepAlive * 6);

      expect(held.closed, isFalse);
      expect(client.isClosed, isFalse);
      links.close();
    });

    testWidgets(
      'raises nothing when its unanswered pings fail as the link ends',
      (tester) async {
        final errors = <Object>[];
        await runZonedGuarded(() async {
          final held = await _lease(links);
          final client = dial.clients.single..pong = Completer();
          await tester.pump(links.keepAlive * 4);
          expect(held.closed, isTrue);
          expect(client.pings, 3);

          client.pong!.completeError(SSHStateError('Transport is closed'));
          await tester.pump();
        }, (error, _) => errors.add(error));
        expect(errors, isEmpty);
      },
    );

    testWidgets('stops probing once the link ends', (tester) async {
      await _lease(links);
      final client = dial.clients.single;
      await tester.pump(links.keepAlive);
      expect(client.pings, 1);

      await client.close();
      await tester.pump();
      await tester.pump(links.keepAlive * 5);
      expect(client.pings, 1);
      expect(links.open, 0);
    });
  });

  group('one owner per host', () {
    Future<HostLease> as(HostLinks links, HostUse use) => links.lease(
      address: '10.0.0.2',
      port: 22,
      user: 'dev',
      privateKey: 'key',
      verifier: HostKeyVerifier.pinnedOnly(_vm),
      use: use,
    );

    test('every use but vnc and the device dock rides the control lane', () {
      expect(
        {for (final use in HostUse.values) use: use.lane},
        {
          for (final use in HostUse.values)
            use: use == HostUse.vnc || use == HostUse.deviceDock
                ? HostLane.screen
                : HostLane.control,
        },
      );
    });

    test('every control use shares one dial', () async {
      final dial = FakeDial();
      final links = HostLinks(dial: dial.call);
      final leases = await Future.wait([
        for (final use in HostUse.values)
          if (use.lane == HostLane.control) as(links, use),
      ]);
      expect(dial.dials, 1);
      expect(links.open, 1);
      expect(
        leases.every((lease) => identical(lease.client, leases.first.client)),
        isTrue,
      );
      links.close();
    });

    test(
      'vnc and the device dock share one screen link apart from control',
      () async {
        final dial = FakeDial();
        final links = HostLinks(dial: dial.call);
        final tab = await as(links, HostUse.tab);
        final vnc = await as(links, HostUse.vnc);
        final dock = await as(links, HostUse.deviceDock);

        expect(dial.dials, 2);
        expect(identical(vnc.client, dock.client), isTrue);
        expect(identical(vnc.client, tab.client), isFalse);
        links.close();
      },
    );

    testWidgets('a screen link let go closes after a short linger', (
      tester,
    ) async {
      final dial = FakeDial();
      final links = HostLinks(dial: dial.call);
      (await as(links, HostUse.vnc)).release();
      await tester.pump(const Duration(seconds: 4));
      expect(dial.clients.single.isClosed, isFalse);
      await tester.pump(const Duration(seconds: 1));
      expect(dial.clients.single.isClosed, isTrue);
      links.close();
    });

    test('one holder letting go leaves the link to the rest', () async {
      final dial = FakeDial();
      final links = HostLinks(dial: dial.call);
      final a = await as(links, HostUse.tab);
      final b = await as(links, HostUse.tab);
      a.release();
      expect(b.closed, isFalse);
      expect(dial.clients.single.isClosed, isFalse);
      links.close();
    });

    test(
      'a network change ends the control link once for every holder',
      () async {
        final dial = FakeDial();
        final links = HostLinks(dial: dial.call);
        final tab = await as(links, HostUse.tab);
        final screen = await as(links, HostUse.vnc);
        final change = Object();
        void renounce() => links.renounce(
          address: '10.0.0.2',
          port: 22,
          user: 'dev',
          privateKey: 'key',
          change: change,
        );
        renounce();
        expect(tab.closed, isTrue);
        expect(screen.closed, isFalse);

        final fresh = await as(links, HostUse.tab);
        renounce();
        expect(fresh.closed, isFalse);
        expect(dial.dials, 3);
        links.close();
      },
    );

    test('asleep, nothing that yields is held or dialled', () async {
      final dial = FakeDial();
      final links = HostLinks(dial: dial.call);
      await as(links, HostUse.herdrPoll);
      await as(links, HostUse.vnc);
      links.sleep();

      expect(links.open, 0);
      await expectLater(as(links, HostUse.herdrPoll), throwsA(anything));
      expect(dial.dials, 2);
      links.close();
    });

    test('asleep, a terminal keeps its link, and only uses that wake lease beside it', () async {
      final dial = FakeDial();
      final links = HostLinks(dial: dial.call);
      final tab = await as(links, HostUse.tab);
      links.sleep();

      await expectLater(as(links, HostUse.herdrPoll), throwsA(anything));
      await expectLater(as(links, HostUse.workspace), throwsA(anything));
      final send = await as(links, HostUse.send);
      expect(send.client, same(tab.client));
      expect(tab.closed, isFalse);
      expect(dial.dials, 1);
      expect(links.open, 1);
      links.close();
    });

    test('asleep, a tab let go ends its link at once', () async {
      final dial = FakeDial();
      final links = HostLinks(dial: dial.call);
      final tab = await as(links, HostUse.tab);
      links.sleep();
      expect(links.open, 1);
      tab.release();
      expect(links.open, 0);

      links.wake();
      await as(links, HostUse.herdrPoll);
      expect(links.open, 1);
      links.close();
    });

    test(
      'a session refused for the host limit opens one overflow link',
      () async {
        final dial = FakeDial();
        final links = HostLinks(dial: dial.call);
        final lease = await as(links, HostUse.tab);
        dial.clients.single.execError = SSHChannelOpenError(1, 'prohibited');

        final first = await lease.execute('true');
        final second = await lease.execute('true');
        expect(dial.dials, 2);
        expect(links.open, 2);
        expect(dial.clients.last.sessions, hasLength(2));

        (first as FakeExecSession).exited.complete();
        (second as FakeExecSession).exited.complete();
        await pumpEventQueue();
        expect(dial.clients.last.isClosed, isTrue);
        expect(links.open, 1);
        links.close();
      },
    );

    test(
      'an overflow that refuses for the limit too opens no second overflow',
      () async {
        final dial = FakeDial()
          ..prepare = (client) =>
              client.execError = SSHChannelOpenError(1, 'prohibited');
        final links = HostLinks(dial: dial.call);
        final lease = await as(links, HostUse.tab);

        await expectLater(
          lease.execute('true'),
          throwsA(isA<SSHChannelOpenError>()),
        );
        expect(dial.dials, 2);
        expect(links.open, 1);
        links.close();
      },
    );

    test(
      'a session spilled as the overflow empties lands on a live overflow',
      () async {
        for (var turns = 0; turns < 12; turns++) {
          var dialled = 0;
          final dial = FakeDial()
            ..prepare = (client) {
              if (dialled++ == 0) {
                client.execError = SSHChannelOpenError(1, 'prohibited');
              }
            };
          final links = HostLinks(dial: dial.call);
          final lease = await as(links, HostUse.tab);
          final first = await lease.execute('true') as FakeExecSession;
          final next = lease.execute('true');
          for (var turn = 0; turn < turns; turn++) {
            await Future<void>.microtask(() {});
          }
          first.exited.complete();
          final session = await next;

          final carrier = dial.clients.singleWhere(
            (client) => client.sessions.contains(session),
          );
          expect(carrier.isClosed, isFalse, reason: 'after $turns turns');
          links.close();
        }
      },
    );

    testWidgets(
      'an overflow that fails to log in leaves the main identity free to dial',
      (tester) async {
        final dial = FakeDial();
        final links = HostLinks(dial: dial.call);
        final lease = await as(links, HostUse.tab);
        dial.clients.single.execError = SSHChannelOpenError(1, 'prohibited');
        dial.slowAuth = true;
        final spilled = lease
            .execute('true')
            .then<Object?>((_) => null, onError: (Object error) => error);
        await tester.pump(const Duration(seconds: 10));
        expect(await spilled, isA<HerdrUnreachable>());
        expect(dial.settling, 1);

        dial.slowAuth = false;
        await dial.clients.single.close();
        await tester.pump();
        final fresh = await as(links, HostUse.tab);
        expect(fresh.closed, isFalse);
        expect(dial.dials, 3);
        links.close();
        await tester.pump(sshLoginGrace);
      },
    );

    test('a session refused for another cause is not overflowed', () async {
      final dial = FakeDial();
      final links = HostLinks(dial: dial.call);
      final lease = await as(links, HostUse.tab);
      dial.clients.single.execError = SSHChannelOpenError(2, 'failed');

      await expectLater(
        lease.execute('true'),
        throwsA(isA<SSHChannelOpenError>()),
      );
      expect(dial.dials, 1);
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

  test(
    'every lease on a link hears it end, and a release alone ends nothing',
    () async {
      final dial = FakeDial();
      final links = HostLinks(dial: dial.call);
      final kept = await _lease(links);
      final let = await _lease(links);
      final heard = <String>[];
      unawaited(kept.ended.then((_) => heard.add('kept')));
      unawaited(let.ended.then((_) => heard.add('let')));

      let.release();
      await pumpEventQueue();
      expect(heard, isEmpty);

      await dial.clients.single.close();
      await pumpEventQueue();
      expect(heard, ['kept', 'let']);
      links.close();
    },
  );

  test('a link not logged in by its timeout fails, and is closed once its login settles', () async {
    final client = _SlowLogin();
    final settles = <Future<void>>[];
    final linking = authenticatedLink(
      FakeExecSocket(),
      client,
      () => 0,
      verifier: HostKeyVerifier.pinnedOnly(_vm),
      timeout: const Duration(milliseconds: 20),
      onSettling: settles.add,
    );

    await expectLater(linking, throwsA(isA<TimeoutException>()));
    expect(settles, hasLength(1));
    expect(client.closes, 0);

    client.login.complete();
    await settles.single;
    expect(client.closes, 1);
  });

  test('a link that logs in inside its timeout is handed over open', () async {
    final client = _SlowLogin()..login.complete();
    final link = await authenticatedLink(
      FakeExecSocket(),
      client,
      () => 7,
      verifier: HostKeyVerifier.pinnedOnly(_vm),
      timeout: const Duration(milliseconds: 20),
    );

    expect(link.client, same(client));
    expect(link.received(), 7);
    expect(client.closes, 0);
  });

  test('closing closes every link', () async {
    final dial = FakeDial();
    final links = HostLinks(dial: dial.call);
    await _lease(links);
    await _lease(links, HostKeyVerifier.pinnedOnly(_key('SHA256:other')));
    links.close();
    expect(dial.clients.every((client) => client.isClosed), isTrue);
  });

  group('a network change', () {
    Future<HostLease> tab(HostLinks links, [String address = '10.0.0.2']) =>
        links.claim(
          address: address,
          port: 22,
          user: 'dev',
          privateKey: 'key',
          verifier: HostKeyVerifier.pinnedOnly(_vm),
          use: HostUse.tab,
        );
    void renounce(HostLinks links, [String address = '10.0.0.2']) =>
        links.renounce(
          address: address,
          port: 22,
          user: 'dev',
          privateKey: 'key',
          change: Object(),
        );
    Future<Object?> outcome(Future<HostLease> claim) =>
        claim.then<Object?>((lease) => lease, onError: (Object error) => error);

    testWidgets(
      'lifts a settle from the old network, so the next claim dials',
      (tester) async {
        final dial = FakeDial(slowAuth: true);
        final links = HostLinks(dial: dial.call);
        final first = outcome(tab(links));
        await tester.pump(const Duration(seconds: 10));
        expect(await first, isA<HerdrUnreachable>());

        final refused = await outcome(tab(links));
        expect(refused, isA<DialSettling>());
        var lifted = false;
        unawaited(
          (refused! as DialSettling).settled.then((_) => lifted = true),
        );
        renounce(links);
        await tester.pump();
        expect(lifted, isTrue);

        dial.slowAuth = false;
        final lease = await tab(links);
        expect(lease.closed, isFalse);
        expect(dial.dials, 2);
        links.close();
        await tester.pump(sshLoginGrace);
      },
    );

    testWidgets('leaves the settle of another host', (tester) async {
      final dial = FakeDial(slowAuth: true);
      final links = HostLinks(dial: dial.call);
      final first = outcome(tab(links));
      await tester.pump(const Duration(seconds: 10));
      await first;
      renounce(links, '10.0.0.3');

      expect(await outcome(tab(links)), isA<DialSettling>());
      expect(dial.dials, 1);
      links.close();
      await tester.pump(sshLoginGrace);
    });

    test('fails the claim whose own dial it renounced on the host, and the claim that joined it dials once more', () async {
      final dial = FakeDial()..gate = Completer();
      final links = HostLinks(dial: dial.call);
      final own = outcome(tab(links));
      final joined = outcome(tab(links));
      await pumpEventQueue();
      renounce(links);
      dial.gate!.complete();

      expect(await own, isA<SocketException>());
      final fresh = await joined;
      expect(fresh, isA<HostLease>());
      expect((fresh! as HostLease).closed, isFalse);
      expect(dial.clients.first.isClosed, isTrue);
      expect(dial.dials, 2);
      links.close();
    });
  });

  group('the check', () {
    late FakeDial dial;
    late HostLinks links;

    setUp(() {
      dial = FakeDial();
      links = HostLinks(dial: dial.call);
    });

    tearDown(() => links.close());

    testWidgets(
      'ends a held link whose peer stopped answering within the answer window',
      (tester) async {
        final held = await _lease(links);
        final beside = await _lease(links);
        final client = dial.clients.single..pong = Completer();
        final checked = held.check();

        await tester.pump(links.answer - const Duration(seconds: 1));
        expect(held.closed, isFalse);
        await tester.pump(const Duration(seconds: 1));
        expect(await checked, isFalse);
        expect(held.closed || beside.closed, isTrue);
        expect(beside.closed, isTrue);
        expect(client.isClosed, isTrue);
        expect(links.open, 0);
      },
    );

    testWidgets('keeps a held link that answers', (tester) async {
      final held = await _lease(links);
      expect(await held.check(), isTrue);
      await tester.pump(links.answer * 2);

      expect(dial.clients.single.pings, 1);
      expect(held.closed, isFalse);
      links.close();
    });

    testWidgets('keeps a held link whose bytes arrive while the ping is out', (
      tester,
    ) async {
      final held = await _lease(links);
      final client = dial.clients.single..pong = Completer();
      final checked = held.check();
      await tester.pump(const Duration(seconds: 1));
      client.received += 64;
      await tester.pump(links.answer);

      expect(await checked, isTrue);
      expect(held.closed, isFalse);
      expect(client.isClosed, isFalse);
      links.close();
    });

    testWidgets('joins a check already out, and the keepalive beside it', (
      tester,
    ) async {
      final held = await _lease(links);
      final client = dial.clients.single..pong = Completer();
      await tester.pump(links.keepAlive - const Duration(seconds: 2));
      final checks = [held.check(), held.check()];
      final all = links.recheckAll();
      expect(client.pings, 1);

      await tester.pump(links.answer);
      expect(client.pings, 2);
      expect(await checks.first, isFalse);
      expect(await checks.last, isFalse);
      await all;
      expect(held.closed, isTrue);
      await tester.pump(links.keepAlive * 3);
      expect(client.pings, 2);
    });

    test('of a lease let go reports it gone and pings nothing', () async {
      final held = await _lease(links);
      final kept = await _leaseAs(links, HostUse.herdrPoll);
      held.release();

      expect(await held.check(), isFalse);
      expect(dial.clients.single.pings, 0);
      expect(kept.closed, isFalse);
    });

    testWidgets(
      'of every link ends the silent ones, held or let go, and keeps the rest',
      (tester) async {
        final silent = await _lease(links);
        final idle = await _lease(
          links,
          HostKeyVerifier.pinnedOnly(_key('SHA256:idle')),
        );
        final live = await _lease(
          links,
          HostKeyVerifier.pinnedOnly(_key('SHA256:live')),
        );
        idle.release();
        dial.clients[0].pong = Completer();
        dial.clients[1].pong = Completer();

        final all = links.recheckAll();
        await tester.pump(links.answer);
        await all;

        expect(silent.closed, isTrue);
        expect(dial.clients[1].isClosed, isTrue);
        expect(live.closed, isFalse);
        expect(links.open, 1);
        links.close();
      },
    );
  });
}

final class _SlowLogin implements SSHClient {
  final login = Completer<void>();
  var closes = 0;

  @override
  Future<void> get authenticated => login.future;

  @override
  Future<void> close() async => closes++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
