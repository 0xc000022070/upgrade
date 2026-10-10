import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:upgrade/application/agent_kind.dart';
import 'package:upgrade/application/agents.dart';
import 'package:upgrade/application/plugin_hosts.dart';
import 'package:upgrade/application/reason_lines.dart';
import 'package:upgrade/data/enums.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/platform/devices/device_link.dart';
import 'package:upgrade/platform/herdr_client.dart';
import 'package:upgrade/platform/host_keys.dart';
import 'package:upgrade/platform/host_links.dart';
import 'package:upgrade/platform/keys.dart';
import 'package:upgrade/platform/plugins/manifest.dart';
import 'package:upgrade/platform/vnc/vnc_tunnel.dart';
import 'package:upgrade/platform/workspace/workspace_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/host_links.dart';
import 'support/ssh_exec.dart';
import 'support/vnc_channel.dart';

final _pin = PinnedHostKey(
  type: 'ssh-ed25519',
  fingerprint: 'SHA256:vm',
  pinnedAt: DateTime(2026),
);

HostKeyVerifier get _pinned => HostKeyVerifier.pinnedOnly(_pin);

final _host = Host(
  id: 'h1',
  name: 'NYX',
  address: '10.0.0.2',
  port: 22,
  user: 'dev',
  keyId: 'k1',
  hostKey: _pin,
);

Future<HostLease> _lease(HostLinks links) => links.lease(
  address: '10.0.0.2',
  port: 22,
  user: 'dev',
  privateKey: 'key',
  verifier: _pinned,
  use: HostUse.send,
);

FakeRunReply _ok(String _) => (exitCode: 0, stdout: '', stderr: '');

FakeRunReply _engine(String _) =>
    (exitCode: 0, stdout: '{"ok":true,"result":{"done":1}}', stderr: '');

final _busy = SSHChannelOpenError(2, 'open failed');

void _ended(FakeLinkClient client) {
  for (final session in client.sessions) {
    expect(session.destroyed, greaterThan(0));
    expect(session.signals, contains(SSHSignal.TERM));
  }
}

Future<ProviderContainer> _scheduler(HostLinks links) async {
  final keys = MemoryPrivateKeyStore();
  await keys.write('k1', 'key');
  return ProviderContainer(
    overrides: [
      privateKeyStoreProvider.overrideWithValue(keys),
      hostLinksProvider.overrideWithValue(links),
    ],
  );
}

Future<Map<String, Object?>> _schedule(ProviderContainer container) =>
    container.read(schedulerTransportProvider)(_host, 'scope', 'list', {});

void main() {
  group('one-shots', () {
    test('paths, models and launch targets share one link', () async {
      final dial = FakeDial()..prepare = (client) => client.reply = _ok;
      final links = HostLinks(
        dial: dial.call,
        linger: const Duration(milliseconds: 20),
      );
      final herdr = HerdrClient(links: links, use: HostUse.send);

      await herdr.fetchPaths(
        address: '10.0.0.2',
        port: 22,
        user: 'dev',
        privateKey: 'key',
        verifier: _pinned,
      );
      await herdr.fetchModels(
        address: '10.0.0.2',
        port: 22,
        user: 'dev',
        privateKey: 'key',
        kind: AgentKind.all.first,
        verifier: _pinned,
      );
      await herdr.fetchLaunchTargets(
        address: '10.0.0.2',
        port: 22,
        user: 'dev',
        privateKey: 'key',
        verifier: _pinned,
      );

      final client = dial.clients.single;
      expect(dial.dials, 1);
      expect(client.sessions, hasLength(3));
      _ended(client);
      expect(client.closes, 0);

      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(client.isClosed, isTrue);
    });

    for (final dead in [false, true]) {
      testWidgets(
        'a send past its deadline leaves the link to the keepalive (${dead ? 'dead' : 'alive'})',
        (tester) async {
          final dial = FakeDial()
            ..prepare = (client) {
              client.execGate = Completer();
              if (dead) client.pingError = StateError('gone');
            };
          final links = HostLinks(dial: dial.call);
          final sent = HerdrClient(links: links, use: HostUse.send).send(
            address: '10.0.0.2',
            port: 22,
            user: 'dev',
            privateKey: 'key',
            kind: AgentKind.all.first,
            directory: '/tmp',
            prompt: 'hi',
            verifier: _pinned,
          );
          await tester.pump();
          await tester.pump(spawnDeadline);

          final result = await sent;
          final client = dial.clients.single;
          expect(result, isA<SpawnRefused>());
          expect(client.pings, 0);
          expect(client.isClosed, isFalse);
          links.close();
        },
      );
    }

    for (final what in ['paths', 'models']) {
      testWidgets('$what on a hung exec gives up at its deadline', (
        tester,
      ) async {
        final dial = FakeDial();
        final links = HostLinks(dial: dial.call);
        final session = HerdrSession.borrowed(await _lease(links));
        const within = Duration(seconds: 3);
        final asked = what == 'paths'
            ? session.paths(within: within)
            : session.models(AgentKind.all.first, within: within);
        Object? failure;
        unawaited(asked.then((_) {}, onError: (Object e) => failure = e));
        await tester.pump(within);
        await tester.pump();

        final client = dial.clients.single;
        expect(failure, isA<HerdrUnreachable>());
        expect(client.pings, 0);
        session.close();
        _ended(client);
        expect(client.sessions, hasLength(1));
        links.close();
      });
    }
  });

  group('workspace', () {
    test('a borrowed run ends its command and leaves the link', () async {
      final dial = FakeDial()..prepare = (client) => client.reply = _ok;
      final links = HostLinks(dial: dial.call);
      final runner = WorkspaceSsh.borrowed(await _lease(links));

      expect((await runner.run('ls')).ok, isTrue);
      final client = dial.clients.single;
      _ended(client);
      await runner.close();
      expect(client.closes, 0);
      links.close();
    });

    testWidgets('closing with a run in flight ends it and lets go', (
      tester,
    ) async {
      final dial = FakeDial();
      final links = HostLinks(dial: dial.call);
      final runner = WorkspaceSsh.borrowed(await _lease(links));
      Object? failure;
      unawaited(
        runner.run('sleep').then((_) {}, onError: (Object e) => failure = e),
      );
      await tester.pump();

      await runner.close();
      final client = dial.clients.single;
      _ended(client);
      final session = client.sessions.single;
      await session.out.close();
      await session.err.close();
      session.exited.complete();
      await tester.pump();
      expect(failure, isA<HerdrUnreachable>());
      expect(client.closes, 0);
      await tester.pump(links.linger);
      expect(client.isClosed, isTrue);
    });

    testWidgets('a command that never opens fails without doubting the link', (
      tester,
    ) async {
      final gate = Completer<void>();
      final dial = FakeDial()..prepare = (client) => client.execGate = gate;
      final links = HostLinks(dial: dial.call);
      final runner = WorkspaceSsh.borrowed(await _lease(links));
      Object? failure;
      unawaited(
        runner.run('ls').then((_) {}, onError: (Object e) => failure = e),
      );
      await tester.pump(WorkspaceSsh.timeout);
      await tester.pump();

      final client = dial.clients.single;
      expect(failure, isA<HerdrUnreachable>());
      expect(client.pings, 0);

      gate.complete();
      await tester.pump();
      expect(client.sessions.single.destroyed, greaterThan(0));
      expect(client.closes, 0);
      await runner.close();
      links.close();
    });

    testWidgets('a command hung past its answer is ended, the link kept', (
      tester,
    ) async {
      final dial = FakeDial();
      final links = HostLinks(dial: dial.call);
      final runner = WorkspaceSsh.borrowed(await _lease(links));
      Object? failure;
      unawaited(
        runner.run('ls').then((_) {}, onError: (Object e) => failure = e),
      );
      await tester.pump(WorkspaceSsh.answer);
      await tester.pump();

      final client = dial.clients.single;
      expect(failure, isA<HerdrUnreachable>());
      expect(client.pings, 0);
      _ended(client);
      await runner.close();
      links.close();
    });

    test('a run after the shared link closed is unreachable', () async {
      final dial = FakeDial();
      final links = HostLinks(dial: dial.call);
      final runner = WorkspaceSsh.borrowed(await _lease(links));
      await dial.clients.single.close();

      await expectLater(runner.run('ls'), throwsA(isA<HerdrUnreachable>()));
      await runner.close();
      links.close();
    });
  });

  group('scheduler', () {
    test('a call ends its exec and leaves the link', () async {
      final dial = FakeDial()..prepare = (client) => client.reply = _engine;
      final links = HostLinks(dial: dial.call);
      final container = await _scheduler(links);

      expect(await _schedule(container), {'done': 1});
      final client = dial.clients.single;
      _ended(client);
      expect(client.closes, 0);
      container.dispose();
      links.close();
    });

    testWidgets('a hung exchange fails without doubting the link', (
      tester,
    ) async {
      final dial = FakeDial();
      final links = HostLinks(dial: dial.call);
      final container = await _scheduler(links);
      Object? failure;
      unawaited(
        _schedule(container).then((_) {}, onError: (Object e) => failure = e),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 45));
      await tester.pump();

      final client = dial.clients.single;
      expect(failure, isA<TimeoutException>());
      expect(client.pings, 0);
      _ended(client);
      container.dispose();
      links.close();
    });

    testWidgets('an engine that opens late is ended on arrival', (
      tester,
    ) async {
      final gate = Completer<void>();
      final dial = FakeDial()..prepare = (client) => client.execGate = gate;
      final links = HostLinks(dial: dial.call);
      final container = await _scheduler(links);
      Object? failure;
      unawaited(
        _schedule(container).then((_) {}, onError: (Object e) => failure = e),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 10));
      await tester.pump();

      expect(failure, isA<TimeoutException>());
      gate.complete();
      await tester.pump();
      final client = dial.clients.single;
      _ended(client);
      expect(client.sessions, hasLength(1));
      expect(client.closes, 0);
      container.dispose();
      links.close();
    });
  });

  group('sharing', () {
    test(
      'every control borrower on one host rides one dial, the screen its own',
      () async {
        final dial = FakeDial()..prepare = (client) => client.reply = _engine;
        final links = HostLinks(dial: dial.call);
        final container = await _scheduler(links);

        final herdr = await HerdrClient(links: links, use: HostUse.send)
            .connect(
              address: '10.0.0.2',
              port: 22,
              user: 'dev',
              privateKey: 'key',
              verifier: _pinned,
            );
        final screen = VncTunnel(links).open(
          address: '10.0.0.2',
          port: 22,
          user: 'dev',
          privateKey: 'key',
          verifier: _pinned,
        );
        await pumpEventQueue();
        dial.clients.last.forwards.single.wire.feed(serverHandshake());
        final connection = await screen;
        final workspace = WorkspaceSsh.borrowed(await _lease(links));
        await _schedule(container);
        await HerdrClient(links: links, use: HostUse.send).fetchPaths(
          address: '10.0.0.2',
          port: 22,
          user: 'dev',
          privateKey: 'key',
          verifier: _pinned,
        );

        expect(dial.dials, 2);
        expect(dial.clients.first.forwards, isEmpty);
        herdr.close();
        await connection.close();
        await workspace.close();
        expect(dial.clients.every((client) => client.closes == 0), isTrue);
        container.dispose();
        links.close();
      },
    );

    test(
      'a refused channel is busy where it was asked for, nowhere else',
      () async {
        final dial = FakeDial();
        final links = HostLinks(dial: dial.call);
        final container = await _scheduler(links);
        final held = await _lease(links);
        final client = dial.clients.single..execError = _busy;

        final herdr = HerdrSession.borrowed(await _lease(links));
        await expectLater(herdr.paths(), throwsA(isA<HerdrBusy>()));
        herdr.close();

        final devices = DeviceSsh.leasing((_) => _lease(links));
        await expectLater(devices.list(), throwsA(isA<HerdrBusy>()));
        await devices.close();

        final workspace = WorkspaceSsh.borrowed(await _lease(links));
        await expectLater(workspace.run('ls'), throwsA(isA<HerdrBusy>()));
        await workspace.close();

        await expectLater(
          _schedule(container),
          throwsA(
            isA<PluginException>().having(
              (e) => e.message,
              'message',
              'Host busy',
            ),
          ),
        );

        expect(client.pings, 0);
        expect(client.closes, 0);

        client
          ..execError = null
          ..reply = _ok;
        final again = WorkspaceSsh.borrowed(await _lease(links));
        expect((await again.run('ls')).ok, isTrue);
        await again.close();
        held.release();
        expect(dial.dials, 1);
        expect(ReasonLine.hostBusy.on('NYX'), 'host busy');
        container.dispose();
        links.close();
      },
    );

    test('a busy host reads as busy in the agents, not unreachable', () async {
      final dial = FakeDial()..prepare = (client) => client.execError = _busy;
      final links = HostLinks(dial: dial.call);
      final hosts = InMemoryHostRepository();
      await hosts.save(_host);
      await hosts.setIntegration(_host.id, IntegrationKind.herdr, true);
      final keys = MemoryPrivateKeyStore();
      await keys.write('k1', 'key');
      final container = ProviderContainer(
        overrides: [
          hostRepositoryProvider.overrideWithValue(hosts),
          privateKeyStoreProvider.overrideWithValue(keys),
          hostLinksProvider.overrideWithValue(links),
          homeAgentsVisibleProvider.overrideWith((ref) => true),
        ],
      );
      final states = <AgentPanelState>[];
      await container.read(agentChannelsProvider.future);
      final subscription = container.listen(
        agentsFeedProvider,
        (_, next) => next.whenData(states.add),
        fireImmediately: true,
      );

      HostOutcome? busy() => states
          .expand((state) => state.failures)
          .where((outcome) => outcome.kind == AgentOutcomeKind.busy)
          .firstOrNull;
      for (var i = 0; i < 200 && busy() == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(busy()?.reason, 'host busy');
      final client = dial.clients.single;
      expect(client.pings, 0);
      expect(client.closes, 0);

      client
        ..execError = null
        ..reply = (_) => (exitCode: 0, stdout: '{"sessions":[]}', stderr: '');
      final agents = await container.read(herdrFetchProvider)(
        address: _host.address,
        port: _host.port,
        user: _host.user,
        privateKey: 'key',
        verifier: _pinned,
      );
      expect(agents, isEmpty);
      expect(dial.dials, 1);

      subscription.close();
      container.dispose();
      links.close();
    });
  });
}
