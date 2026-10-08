import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/platform/host_keys.dart';
import 'package:upgrade/platform/host_links.dart';
import 'package:upgrade/platform/ssh/connection_supervisor.dart';

import 'support/host_links.dart';
import 'support/ssh_exec.dart';

final _vm = PinnedHostKey(
  type: 'ssh-ed25519',
  fingerprint: 'SHA256:vm',
  pinnedAt: DateTime(2026),
);

SshConnector _connector(HostLinks links) => SshConnector(
  links: links,
  timeout: const Duration(seconds: 10),
  keepAlive: const Duration(seconds: 60),
);

Future<ConnectionSupervisor> _tab(SshConnector connector) =>
    connector.establish(
      address: '10.0.0.2',
      port: 22,
      user: 'dev',
      privateKey: 'key',
      verifier: HostKeyVerifier.pinnedOnly(_vm),
      reason: UserAction(UserIntent.fromGesture()),
      startup: (supervisor) async => supervisor,
    );

Future<List<ConnectionSupervisor>> _tabs(SshConnector connector, int count) =>
    Future.wait([for (var i = 0; i < count; i++) _tab(connector)]);

Future<void> _closeAll(List<ConnectionSupervisor> tabs) => Future.wait([
  for (final tab in tabs) tab.drop(UserClosed(UserIntent.fromGesture())),
]);

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
    await tabs.first.drop(UserClosed(UserIntent.fromGesture()));

    expect(dial.clients.single.isClosed, isFalse);
    expect(await tabs.last.open(UserAction(UserIntent.fromGesture())), isNotNull);
    expect(dial.dials, 1);
    await _closeAll(tabs.skip(1).toList());
    links.close();
  });

  test('asleep the isolate holds no link, and resuming tabs dial once', () async {
    final dial = FakeDial();
    final links = HostLinks(dial: dial.call);
    final tabs = await _tabs(_connector(links), 3);
    links.sleep();
    final suspended = AppSuspended(PlatformSignal.fromPlatform());
    await Future.wait([for (final tab in tabs) tab.drop(suspended)]);
    expect(links.open, 0);

    links.wake();
    final resumed = AppResumed(PlatformSignal.fromPlatform());
    final opened = await Future.wait([for (final tab in tabs) tab.open(resumed)]);
    expect(opened.every((channels) => channels != null), isTrue);
    expect(dial.dials, 2);
    expect(links.open, 1);
    await _closeAll(tabs);
    links.close();
  });

  test('a network change ends the link for every tab, and they redial once', () async {
    final dial = FakeDial();
    final links = HostLinks(dial: dial.call);
    final tabs = await _tabs(_connector(links), 3);
    final change = NetworkChanged(PlatformSignal.fromPlatform());
    for (final tab in tabs) {
      await tab.drop(change);
    }
    expect(dial.clients.first.isClosed, isTrue);

    final opened = await Future.wait([for (final tab in tabs) tab.open(change)]);
    expect(opened.every((channels) => channels != null), isTrue);
    expect(dial.dials, 2);
    expect(dial.clients.last.isClosed, isFalse);
    await _closeAll(tabs);
    links.close();
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
        for (final tab in tabs) tab.open(UserAction(UserIntent.fromGesture())),
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
      final connector = SshConnector(
        dial:
            ({
              required address,
              required port,
              required user,
              required privateKey,
              required timeout,
              required keepAlive,
              required verifier,
            }) async {
              if (dials++ == 0) return sshHostOver(FakeExecSocket(), client);
              throw refusal;
            },
        timeout: const Duration(seconds: 10),
        keepAlive: const Duration(seconds: 60),
      );
      final tab = await _tab(connector)
        ..reopenWhenHostDies();
      final links = <ControlLink>[];
      tab.controlLink.listen(links.add);
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
      await tab.drop(UserClosed(UserIntent.fromGesture()));
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
      await tab.drop(UserClosed(UserIntent.fromGesture()));
    });

    testWidgets('on a bug, instead of throwing in its timer', (tester) async {
      final (tab, client, links) = await revived(StateError('bug'));
      await client.close();
      await tester.pump();

      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(links.last, isA<ControlGaveUp>());
      await tab.drop(UserClosed(UserIntent.fromGesture()));
    });

    testWidgets('until a gesture holds the host again', (tester) async {
      final client = FakeLinkClient();
      var dials = 0;
      final connector = SshConnector(
        dial:
            ({
              required address,
              required port,
              required user,
              required privateKey,
              required timeout,
              required keepAlive,
              required verifier,
            }) async {
              if (dials++ == 1) throw SSHAuthFailError('no more methods');
              return sshHostOver(
                FakeExecSocket(),
                dials == 1 ? client : FakeLinkClient(),
              );
            },
        timeout: const Duration(seconds: 10),
        keepAlive: const Duration(seconds: 60),
      );
      final tab = await _tab(connector)
        ..reopenWhenHostDies();
      final links = <ControlLink>[];
      tab.controlLink.listen(links.add);
      await client.close();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(links.last, isA<ControlGaveUp>());

      expect(await tab.open(UserAction(UserIntent.fromGesture())), isNotNull);
      await tester.pump();
      expect(links.last, isA<ControlUp>());
      await tab.drop(UserClosed(UserIntent.fromGesture()));
    });
  });
}
