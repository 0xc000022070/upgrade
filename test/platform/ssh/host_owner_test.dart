import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:striked/data/repositories/host_repository.dart';
import 'package:striked/features/shell/session/shell_sessions.dart';
import 'package:striked/platform/ssh/host_keys.dart';
import 'package:striked/platform/ssh/host_links.dart';
import 'package:striked/platform/shell/shell_tunnel.dart';
import 'package:striked/platform/ssh/connection_supervisor.dart';
import 'package:striked/platform/ssh/ssh_settle.dart';

import '../../support/host_links.dart';
import '../../support/reasons.dart';
import '../../support/ssh_exec.dart';

final _vm = PinnedHostKey(
  type: 'ssh-ed25519',
  fingerprint: 'SHA256:vm',
  pinnedAt: DateTime(2026),
);

SshConnector _connector(HostLinks links) =>
    SshConnector(links: links, timeout: const Duration(seconds: 10));

Future<ConnectionSupervisor> _tab(SshConnector connector) =>
    connector.establish(
      address: '10.0.0.2',
      port: 22,
      user: 'dev',
      privateKey: 'key',
      verifier: HostKeyVerifier.pinnedOnly(_vm),
      reason: UserAction(testIntent()),
      startup: (supervisor) async => supervisor,
    );

Future<List<ConnectionSupervisor>> _tabs(SshConnector connector, int count) =>
    Future.wait([for (var i = 0; i < count; i++) _tab(connector)]);

Future<void> _closeAll(List<ConnectionSupervisor> tabs) =>
    Future.wait([for (final tab in tabs) tab.drop(UserClosed(testIntent()))]);

void main() {
  test('tabs on one host share one dial', () async {
    final dial = FakeDial();
    final links = HostLinks(dial: dial.call);
    final tabs = await _tabs(_connector(links), 3);

    expect(dial.dials, 1);
    expect(links.open, 1);
    await _closeAll(tabs);
    links.close();
  });

  test('one tab closing leaves the link to the others', () async {
    final dial = FakeDial();
    final links = HostLinks(dial: dial.call);
    final tabs = await _tabs(_connector(links), 3);
    await tabs.first.drop(UserClosed(testIntent()));

    expect(dial.clients.single.isClosed, isFalse);
    expect(await tabs.last.open(UserAction(testIntent())), isNotNull);
    expect(dial.dials, 1);
    await _closeAll(tabs.skip(1).toList());
    links.close();
  });

  test(
    'asleep the isolate holds no link, and resuming tabs dial once',
    () async {
      final dial = FakeDial();
      final links = HostLinks(dial: dial.call);
      final tabs = await _tabs(_connector(links), 3);
      links.sleep();
      final suspended = AppSuspended(testSignal());
      await Future.wait([for (final tab in tabs) tab.drop(suspended)]);
      expect(links.open, 0);

      links.wake();
      final resumed = AppResumed(testSignal());
      final opened = await Future.wait([
        for (final tab in tabs) tab.open(resumed),
      ]);
      expect(opened.every((channels) => channels != null), isTrue);
      expect(dial.dials, 2);
      expect(links.open, 1);
      await _closeAll(tabs);
      links.close();
    },
  );

  test(
    'a network change ends the link for every tab, and they redial once',
    () async {
      final dial = FakeDial();
      final links = HostLinks(dial: dial.call);
      final tabs = await _tabs(_connector(links), 3);
      final change = NetworkChanged(testSignal());
      for (final tab in tabs) {
        await tab.drop(change);
      }
      expect(dial.clients.first.isClosed, isTrue);

      final opened = await Future.wait([
        for (final tab in tabs) tab.open(change),
      ]);
      expect(opened.every((channels) => channels != null), isTrue);
      expect(dial.dials, 2);
      expect(dial.clients.last.isClosed, isFalse);
      await _closeAll(tabs);
      links.close();
    },
  );

  test('a gesture during a resume dial joins it on one lease', () async {
    final dial = FakeDial();
    final links = HostLinks(dial: dial.call);
    final tab = await _tab(_connector(links));
    links.sleep();
    await tab.drop(AppSuspended(testSignal()));
    links.wake();
    expect(links.open, 0);

    final gate = dial.gate = Completer<void>();
    final granted = links.granted;
    final resumed = tab.open(AppResumed(testSignal()));
    final gesture = tab.open(UserAction(testIntent()));
    await pumpEventQueue();
    gate.complete();
    final opened = await Future.wait([resumed, gesture]);

    expect(opened.first, isNotNull);
    expect(opened.last, same(opened.first));
    expect(dial.dials, 2);
    expect(links.granted - granted, 1);
    expect(links.held, 1);
    await _closeAll([tab]);
    links.close();
  });

  group('a dial that lands after its tab let go', () {
    Future<void> landsLate(DropReason reason) async {
      final dial = FakeDial();
      final links = HostLinks(dial: dial.call);
      final tab = await _tab(_connector(links));
      await dial.clients.single.close();
      await pumpEventQueue();
      expect(links.open, 0);

      final gate = dial.gate = Completer<void>();
      final opening = tab.open(UserAction(testIntent()));
      await pumpEventQueue();
      await tab.drop(reason);
      gate.complete();

      expect(await opening, isNull);
      await pumpEventQueue();
      expect(links.held, 0);
      expect(dial.dials, 2);
      await tab.drop(UserClosed(testIntent()));
      links.close();
    }

    test('is released by a retired tab', () async {
      await landsLate(UserClosed(testIntent()));
    });

    test('is released by a suspended tab', () async {
      await landsLate(AppSuspended(testSignal()));
    });
  });

  testWidgets('a host that dies is revived by every tab with one dial', (
    tester,
  ) async {
    final dial = FakeDial();
    final links = HostLinks(dial: dial.call);
    final tabs = await _tabs(_connector(links), 3);
    for (final tab in tabs) {
      tab.reopenWhenHostDies();
    }
    await dial.clients.single.close();
    await tester.pump();
    expect(links.open, 0);

    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(dial.dials, 2);
    expect(links.open, 1);
    expect(
      await Future.wait([
        for (final tab in tabs) tab.open(UserAction(testIntent())),
      ]),
      everyElement(isNotNull),
    );
    expect(dial.dials, 2);
    await _closeAll(tabs);
    links.close();
  });

  group('a revival that stops says so', () {
    Future<(ConnectionSupervisor, FakeLinkClient, List<ControlLink>)> revived(
      Object refusal,
    ) async {
      final client = FakeLinkClient();
      var dials = 0;
      final pool = HostLinks(
        keepAlive: const Duration(days: 1),
        dial:
            ({
              required address,
              required port,
              required user,
              required privateKey,
              required verifier,
              onSettling,
            }) async {
              if (dials++ == 0) {
                return (
                  socket: FakeExecSocket(),
                  client: client,
                  received: () => 0,
                );
              }
              throw refusal;
            },
      );
      final tab = await _tab(_connector(pool))
        ..reopenWhenHostDies();
      final links = <ControlLink>[];
      tab.controlLink.listen(links.add);
      addTearDown(pool.close);
      return (tab, client, links);
    }

    testWidgets('on a refused key', (tester) async {
      final (tab, client, links) = await revived(
        SSHAuthFailError('no more methods'),
      );
      await client.close();
      await tester.pump();
      expect(links, [isA<ControlReconnecting>()]);

      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(links, [
        isA<ControlReconnecting>(),
        isA<ControlGaveUp>().having(
          (link) => link.error,
          'error',
          isA<SSHAuthFailError>(),
        ),
      ]);
      await tab.drop(UserClosed(testIntent()));
    });

    testWidgets('once its schedule runs out', (tester) async {
      final (tab, client, links) = await revived(
        const SocketException('Connection refused'),
      );
      await client.close();
      await tester.pump();

      for (final seconds in [1, 2, 5, 10]) {
        await tester.pump(Duration(seconds: seconds));
        await tester.pump();
        expect(links, [isA<ControlReconnecting>()]);
      }
      await tester.pump(const Duration(seconds: 30));
      await tester.pump();
      expect(links, [
        isA<ControlReconnecting>(),
        isA<ControlGaveUp>().having(
          (link) => link.error,
          'error',
          isA<SocketException>(),
        ),
      ]);
      await tab.drop(UserClosed(testIntent()));
    });

    testWidgets('on a bug, instead of throwing in its timer', (tester) async {
      final (tab, client, links) = await revived(StateError('bug'));
      await client.close();
      await tester.pump();

      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(links.last, isA<ControlGaveUp>());
      await tab.drop(UserClosed(testIntent()));
    });

    testWidgets('until a gesture holds the host again', (tester) async {
      final client = FakeLinkClient();
      var dials = 0;
      final pool = HostLinks(
        keepAlive: const Duration(days: 1),
        dial:
            ({
              required address,
              required port,
              required user,
              required privateKey,
              required verifier,
              onSettling,
            }) async {
              if (dials++ == 1) throw SSHAuthFailError('no more methods');
              return (
                socket: FakeExecSocket(),
                client: dials == 1 ? client : FakeLinkClient(),
                received: () => 0,
              );
            },
      );
      addTearDown(pool.close);
      final tab = await _tab(_connector(pool))
        ..reopenWhenHostDies();
      final links = <ControlLink>[];
      tab.controlLink.listen(links.add);
      await client.close();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(links.last, isA<ControlGaveUp>());

      expect(await tab.open(UserAction(testIntent())), isNotNull);
      await tester.pump();
      expect(links.last, isA<ControlUp>());
      await tab.drop(UserClosed(testIntent()));
      pool.close();
    });
  });

  group('a dial refused while an earlier one settles', () {
    const grace = Duration(seconds: 120);

    Future<(ConnectionSupervisor, HostLinks, FakeLinkClient, List<int>)>
    settling({Duration settle = grace}) async {
      final first = FakeLinkClient();
      final dials = [0];
      final links = HostLinks(
        dial:
            ({
              required address,
              required port,
              required user,
              required privateKey,
              required verifier,
              onSettling,
            }) async {
              if (++dials[0] == 2) {
                onSettling?.call(Future<void>.delayed(settle));
                throw TimeoutException('auth stalled');
              }
              return (
                socket: FakeExecSocket(),
                client: dials[0] == 1 ? first : FakeLinkClient(),
                received: () => 0,
              );
            },
      );
      return (await _tab(_connector(links)), links, first, dials);
    }

    Future<void> failedDial(
      ConnectionSupervisor tab,
      FakeLinkClient first,
    ) async {
      await first.close();
      await expectLater(
        tab.open(UserAction(testIntent())),
        throwsA(isA<TimeoutException>()),
      );
    }

    ({HostChannels? opened, Object? failed, bool done}) Function() watch(
      Future<HostChannels?> opening,
    ) {
      HostChannels? opened;
      Object? failed;
      var done = false;
      unawaited(
        opening.then(
          (channels) {
            opened = channels;
            done = true;
          },
          onError: (Object error) {
            failed = error;
            done = true;
          },
        ),
      );
      return () => (opened: opened, failed: failed, done: done);
    }

    testWidgets('waits for the settle, and revival dials again after it', (
      tester,
    ) async {
      final (tab, links, first, dials) = await settling();
      tab.reopenWhenHostDies();
      final events = <ControlLink>[];
      tab.controlLink.listen(events.add);
      await first.close();
      await tester.pump();

      for (final seconds in [1, 2, 5, 10, 30, 60]) {
        await tester.pump(Duration(seconds: seconds));
        await tester.pump();
      }
      expect(dials.single, 2);
      expect(events, [isA<ControlReconnecting>()]);

      await tester.pump(const Duration(seconds: 15));
      await tester.pump();
      expect(dials.single, 3);
      expect(events, [isA<ControlReconnecting>(), isA<ControlUp>()]);
      await tab.drop(UserClosed(testIntent()));
      links.close();
    });

    testWidgets('a gesture whose settle lifts inside a dial timeout dials '
        'then', (tester) async {
      const settle = Duration(seconds: 8);
      final (tab, links, first, dials) = await settling(settle: settle);
      await failedDial(tab, first);

      final outcome = watch(tab.open(UserAction(testIntent())));
      await tester.pump();
      expect(dials.single, 2);
      expect(outcome().done, isFalse);

      await tester.pump(settle);
      await tester.pump();
      expect(dials.single, 3);
      expect(outcome().failed, isNull);
      expect(outcome().opened, isNotNull);
      await tab.drop(UserClosed(testIntent()));
      links.close();
    });

    testWidgets('a gesture whose settle outlasts a dial timeout fails on the '
        'host at that timeout', (tester) async {
      final (tab, links, first, dials) = await settling();
      await failedDial(tab, first);

      final outcome = watch(tab.open(UserAction(testIntent())));
      await tester.pump(const Duration(seconds: 9));
      expect(outcome().done, isFalse);

      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(
        outcome().failed,
        isA<DialSettling>().having(isHostFailure, 'host failure', isTrue),
      );
      expect(dials.single, 2);
      await tab.drop(UserClosed(testIntent()));
      links.close();
      await tester.pump(grace);
    });

    testWidgets('a tab a gesture opens while a settle outlasts a dial timeout '
        'fails on the host at that timeout', (tester) async {
      final (tab, links, first, dials) = await settling();
      await failedDial(tab, first);

      Reconnect? retry;
      final outcome = watch(
        _connector(links)
            .establish(
              address: '10.0.0.2',
              port: 22,
              user: 'dev',
              privateKey: 'key',
              verifier: HostKeyVerifier.pinnedOnly(_vm),
              reason: UserAction(testIntent()),
              startup: (supervisor) async => supervisor,
              failed: (reconnect) => retry = reconnect,
            )
            .then((_) => null),
      );
      await tester.pump(const Duration(seconds: 9));
      expect(outcome().done, isFalse);

      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(outcome().failed, isA<DialSettling>());
      expect(retry, isNotNull);
      expect(dials.single, 2);
      await tab.drop(UserClosed(testIntent()));
      links.close();
      await tester.pump(grace);
    });

    testWidgets('a resume inside the window waits, then dials', (tester) async {
      final (tab, links, first, dials) = await settling();
      final events = <ControlLink>[];
      tab.controlLink.listen(events.add);
      await first.close();
      await tester.pump();
      await expectLater(
        tab.open(UserAction(testIntent())),
        throwsA(isA<TimeoutException>()),
      );
      await tab.drop(AppSuspended(testSignal()));

      HostChannels? opened;
      Object? failed;
      unawaited(
        tab
            .open(AppResumed(testSignal()))
            .then(
              (channels) => opened = channels,
              onError: (Object e) {
                failed = e;
              },
            ),
      );
      await tester.pump();
      expect(dials.single, 2);
      expect(failed, isNull);

      await tester.pump(const Duration(seconds: 30));
      expect(failed, isNull);
      expect(opened, isNull);

      await tester.pump(grace);
      await tester.pump();
      expect(dials.single, 3);
      expect(failed, isNull);
      expect(opened, isNotNull);
      expect(events.last, isA<ControlUp>());
      await tab.drop(UserClosed(testIntent()));
      links.close();
    });

    testWidgets('a resume whose wait spans a suspend stays suspended', (
      tester,
    ) async {
      final (tab, links, first, dials) = await settling();
      final events = <ControlLink>[];
      tab.controlLink.listen(events.add);
      await first.close();
      await tester.pump();
      await expectLater(
        tab.open(UserAction(testIntent())),
        throwsA(isA<TimeoutException>()),
      );
      await tab.drop(AppSuspended(testSignal()));

      HostChannels? opened;
      Object? failed;
      var settled = false;
      unawaited(
        tab
            .open(AppResumed(testSignal()))
            .then(
              (channels) {
                opened = channels;
                settled = true;
              },
              onError: (Object e) {
                failed = e;
              },
            ),
      );
      await tester.pump();
      await tab.drop(AppSuspended(testSignal()));
      final suspended = events.length;

      await tester.pump(grace);
      await tester.pump();
      expect(failed, isNull);
      expect(settled, isTrue);
      expect(opened, isNull);
      expect(dials.single, 2);
      expect(events.skip(suspended), isEmpty);
      await tab.drop(UserClosed(testIntent()));
      links.close();
    });

    testWidgets('a second tab on a network change its first tab already '
        'renounced waits out that tab\'s settle, then dials', (tester) async {
      final first = FakeLinkClient();
      final dials = [0];
      final links = HostLinks(
        dial:
            ({
              required address,
              required port,
              required user,
              required privateKey,
              required verifier,
              onSettling,
            }) async {
              if (++dials[0] == 2) {
                onSettling?.call(Future<void>.delayed(grace));
                throw TimeoutException('auth stalled');
              }
              return (
                socket: FakeExecSocket(),
                client: dials[0] == 1 ? first : FakeLinkClient(),
                received: () => 0,
              );
            },
      );
      final tabs = await _tabs(_connector(links), 2);
      final change = NetworkChanged(testSignal());

      await tabs.first.drop(change);
      await expectLater(
        tabs.first.open(change),
        throwsA(isA<TimeoutException>()),
      );
      await tabs.last.drop(change);
      HostChannels? opened;
      Object? failed;
      unawaited(
        tabs.last
            .open(change)
            .then(
              (channels) => opened = channels,
              onError: (Object e) {
                failed = e;
              },
            ),
      );
      await tester.pump();
      expect(dials.single, 2);
      expect(failed, isNull);

      await tester.pump(grace);
      await tester.pump();
      expect(failed, isNull);
      expect(opened, isNotNull);
      expect(dials.single, 3);
      await _closeAll(tabs);
      links.close();
    });

    testWidgets('a tab whose login settles keeps its schedule and is never '
        'parked in WAITING', (tester) async {
      var dials = 0;
      final links = HostLinks(
        dial:
            ({
              required address,
              required port,
              required user,
              required privateKey,
              required verifier,
              onSettling,
            }) async {
              dials++;
              // A login sshd never answered: the socket keeps authenticating for
              // sshLoginGrace after the dial gives up on it.
              onSettling?.call(Future<void>.delayed(sshLoginGrace));
              throw TimeoutException('login', const Duration(seconds: 10));
            },
      );
      final sessions = ShellSessions(
        readPrivateKey: (_) async => 'PEM',
        pinHostKey: (_, _) async {},
        open: ShellTunnel(links: links).open,
      );
      const host = Host(
        id: 'h1',
        name: 'vm',
        address: '10.0.0.2',
        port: 22,
        user: 'dev',
        keyId: 'key-1',
      );
      final session = sessions.open(intent: testIntent(), host)!;
      final waited = <Duration>[];
      for (var second = 1; second <= 125; second++) {
        await tester.pump(const Duration(seconds: 1));
        if (session.state is ShellWaiting) {
          waited.add(Duration(seconds: second));
        }
      }

      expect(waited, isEmpty);
      expect(dials, greaterThan(1));

      await sessions.close(intent: testIntent(), host.id, session);
      links.close();
      await tester.pump(sshLoginGrace);
    });
  });

  group('a check on the held link', () {
    testWidgets('ends a link that misses it, for every tab on it', (
      tester,
    ) async {
      final dial = FakeDial();
      final links = HostLinks(dial: dial.call);
      final tabs = await _tabs(_connector(links), 2);
      final client = dial.clients.single..pong = Completer<void>();

      unawaited(tabs.first.check());
      await tester.pump(links.answer);
      await tester.pump();

      expect(client.isClosed, isTrue);
      expect(links.open, 0);
      for (final tab in tabs) {
        expect(
          await tab.exec('true', timeout: const Duration(seconds: 1)),
          isNull,
        );
      }
      await _closeAll(tabs);
      links.close();
    });

    testWidgets('keeps a link that answers', (tester) async {
      final dial = FakeDial();
      final links = HostLinks(dial: dial.call);
      final tabs = await _tabs(_connector(links), 2);
      final client = dial.clients.single;

      await Future.wait([for (final tab in tabs) tab.check()]);
      await tester.pump(links.answer);

      expect(client.pings, greaterThan(0));
      expect(client.isClosed, isFalse);
      expect(links.open, 1);
      expect(dial.dials, 1);
      await _closeAll(tabs);
      links.close();
    });
  });

  test('channels from an earlier hold answer null once the tab holds the host '
      'again, even on a lease of the same link', () async {
    final dial = FakeDial()
      ..prepare = (client) =>
          client.reply = (_) => (stdout: '', stderr: '', exitCode: 0);
    final links = HostLinks(
      dial: dial.call,
      keepAlive: const Duration(days: 1),
    );
    final tab = await _tab(_connector(links));
    final before = await tab.open(UserAction(testIntent()));
    expect(await before?.exec('true', timeout: _deadline), isNotNull);

    await tab.drop(AppSuspended(testSignal()));
    final after = await tab.open(AppResumed(testSignal()));

    expect(after, isNotNull);
    expect(await before?.exec('true', timeout: _deadline), isNull);
    expect(await after?.exec('true', timeout: _deadline), isNotNull);
    expect(dial.dials, 1);
    expect(dial.clients.single.commands, ['true', 'true']);
    await tab.drop(UserClosed(testIntent()));
    links.close();
  });
}

const _deadline = Duration(seconds: 1);
