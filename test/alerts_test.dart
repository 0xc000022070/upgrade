import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spectacle/application/agents.dart';
import 'package:spectacle/application/alerts.dart';
import 'package:spectacle/data/repositories/host_repository.dart';
import 'package:spectacle/platform/agent_watcher.dart';
import 'package:spectacle/platform/herdr_client.dart';
import 'package:spectacle/platform/host_keys.dart';
import 'package:spectacle/platform/keys.dart';

/// The alerts regression list.

/// A client that never dials: it keeps what it was handed to check the host
/// with, and reports the host as down so the loop backs off instead of
/// looping on it.
class RecordingHerdrClient extends HerdrClient {
  final verifiers = <HostKeyVerifier?>[];

  @override
  Future<HerdrSession> connect({
    required String address,
    required int port,
    required String user,
    required String privateKey,
    HostKeyVerifier? verifier,
  }) async {
    verifiers.add(verifier);
    throw const HerdrUnreachable('no machine behind a test');
  }
}

AgentSnapshot snapshot({
  String pane = 'wQ:p1',
  String agent = 'claude',
  String status = 'blocked',
  String title = 'ALLOW touch probe.txt?',
}) => AgentSnapshot(
  paneId: pane,
  agent: agent,
  agentStatus: status,
  terminalTitleStripped: title,
  workspaceId: pane.split(':').first,
  cwd: '/home/luisnquin/src',
  stateChangeSeq: 1,
);

const host = Host(
  id: 'h1',
  name: 'nyx',
  address: '100.64.0.1',
  port: 22,
  user: 'luisnquin',
  keyId: 'k1',
);

void main() {
  group('the blocked edge', () {
    test('fires once per episode, and again after an unblock', () {
      final edges = BlockedEdges();

      final first = edges.apply('h1', [snapshot()]);
      expect(first.entered.map((agent) => agent.paneId), ['wQ:p1']);
      expect(first.left, isEmpty);

      final second = edges.apply('h1', [snapshot()]);
      expect(second.isEmpty, isTrue);

      final unblocked = edges.apply('h1', [snapshot(status: 'working')]);
      expect(unblocked.entered, isEmpty);
      expect(unblocked.left, ['wQ:p1']);

      final again = edges.apply('h1', [snapshot()]);
      expect(again.entered.map((agent) => agent.paneId), ['wQ:p1']);
    });

    test('counts every blocked pane as new on the service\'s first snapshot', () {
      // Amended: the "new" moment is the service starting, and a fresh
      // service is a fresh [BlockedEdges] on its handler. Nothing to difference
      // against, so every pane already showing blocked is an edge.
      final edges = BlockedEdges();
      final first = edges.apply('h1', [snapshot(), snapshot(pane: 'wQ:p2')]);
      expect(first.entered, hasLength(2));
      expect(first.left, isEmpty);
    });

    test('a reconnect keeps the set, so nothing still blocked re-enters', () {
      // The A6 review flag, and the reason the rule was amended. The loop used
      // to call `edges.reset` on every connect; a pane the user had already
      // answered came back out of `apply` as an edge, which reposted the alert
      // with YES/NO restored and threw away its `SENT · YES` line.
      final edges = BlockedEdges();
      expect(edges.apply('h1', [snapshot()]).entered, hasLength(1));

      // The link drops and comes back inside one service life. `_HostLoop`
      // reconnects and the next snapshot lands on the same set.
      final rejoined = edges.apply('h1', [snapshot()]);
      expect(rejoined.entered, isEmpty, reason: 'no re-alert, no sound');
      expect(rejoined.left, isEmpty);
      expect(edges.blockedOn('h1'), {'wQ:p1'});
    });

    test('what changed while the link was down still reads as an edge', () {
      final edges = BlockedEdges();
      edges.apply('h1', [snapshot(), snapshot(pane: 'wQ:p2')]);

      // Down and back: p1 unblocked meanwhile, p2 is still blocked, and p3
      // blocked while nobody was watching.
      final rejoined = edges.apply('h1', [
        snapshot(pane: 'wQ:p2'),
        snapshot(pane: 'wQ:p3'),
      ]);
      expect(rejoined.left, ['wQ:p1'], reason: 'its notification is cancelled');
      expect(rejoined.entered.map((agent) => agent.paneId), ['wQ:p3']);

      // And once only: the next snapshot after that is quiet again.
      expect(
        edges.apply('h1', [
          snapshot(pane: 'wQ:p2'),
          snapshot(pane: 'wQ:p3'),
        ]).isEmpty,
        isTrue,
      );
    });

    test('reset is what a host going away does, and it alone makes panes new', () {
      // `_HostLoop.stop()` — the host was removed or its address, port, user or
      // key changed, so the next loop is watching a different machine. Nothing
      // else calls it any more.
      final edges = BlockedEdges();
      edges.apply('h1', [snapshot()]);
      expect(edges.apply('h1', [snapshot()]).entered, isEmpty);

      edges.reset('h1');
      expect(edges.blockedOn('h1'), isEmpty);
      expect(edges.apply('h1', [snapshot()]).entered, hasLength(1));
    });

    test('a pane that disappears leaves blocked', () {
      final edges = BlockedEdges();
      edges.apply('h1', [snapshot()]);
      expect(edges.apply('h1', const []).left, ['wQ:p1']);
    });

    test('two hosts blocking the same pane id are two episodes', () {
      final edges = BlockedEdges();
      expect(edges.apply('h1', [snapshot()]).entered, hasLength(1));
      expect(edges.apply('h2', [snapshot()]).entered, hasLength(1));
      expect(edges.blockedOn('h1'), {'wQ:p1'});
    });
  });

  group('notification ids', () {
    test('are stable per host and pane, and never the watcher\'s', () {
      expect(
        alertNotificationId('h1', 'wQ:p1'),
        alertNotificationId('h1', 'wQ:p1'),
      );
      expect(
        alertNotificationId('h1', 'wQ:p1'),
        isNot(alertNotificationId('h2', 'wQ:p1')),
      );
      expect(
        alertNotificationId('h1', 'wQ:p1'),
        isNot(alertNotificationId('h1', 'wQ:p2')),
      );
      expect(alertNotificationId('h1', 'wQ:p1'), isNot(watcherNotificationId));
      expect(alertNotificationId('h1', 'wQ:p1'), lessThan(1 << 31));
    });

    test('an alert target carries its own id', () {
      final target = AlertTarget.forHost(host, snapshot());
      expect(target.notificationId, alertNotificationId('h1', 'wQ:p1'));
    });
  });

  group('the key table', () {
    test('answers each kind the way its prompt reads', () {
      expect(answerKeys('claude', yes: true), ['enter']);
      expect(answerKeys('claude', yes: false), ['esc']);
      expect(answerKeys('codex', yes: true), ['y']);
      expect(answerKeys('codex', yes: false), ['n']);
    });

    test('an unknown kind answers the way most TUIs do', () {
      expect(answerKeys('aider', yes: true), ['enter']);
      expect(answerKeys('', yes: false), ['esc']);
    });

    test('the kind is matched without case', () {
      expect(answerKeys('Codex', yes: true), ['y']);
    });
  });

  group('the watcher runs', () {
    ProviderContainer containerWith({
      required bool alerts,
      required List<Host> hosts,
      bool denied = false,
    }) {
      final container = ProviderContainer(
        overrides: [
          alertsEnabledProvider.overrideWith((ref) => Stream.value(alerts)),
          herdrHostsProvider.overrideWith((ref) => Stream.value(hosts)),
          if (denied) alertsDeniedProvider.overrideWith((ref) => true),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    Future<AlertsRow> row(ProviderContainer container) async {
      await container.read(alertsEnabledProvider.future);
      await container.read(herdrHostsProvider.future);
      return container.read(alertsRowProvider);
    }

    test('only with the toggle on and a HERDR host', () async {
      final on = containerWith(alerts: true, hosts: const [host]);
      expect(await row(on), AlertsRow.on);
      expect(on.read(watcherWantedProvider), isTrue);

      final off = containerWith(alerts: false, hosts: const [host]);
      expect(await row(off), AlertsRow.off);
      expect(off.read(watcherWantedProvider), isFalse);

      final hostless = containerWith(alerts: true, hosts: const []);
      expect(await row(hostless), AlertsRow.noHost);
      expect(hostless.read(watcherWantedProvider), isFalse);
    });

    test('never while the OS has refused notifications', () async {
      final denied = containerWith(
        alerts: true,
        hosts: const [host],
        denied: true,
      );
      expect(await row(denied), AlertsRow.denied);
      expect(denied.read(watcherWantedProvider), isFalse);
    });

    test('the row says which of the two is missing', () {
      expect(AlertsRow.noHost.subtitle, 'NO HOST');
      expect(AlertsRow.denied.subtitle, 'NOTIFICATIONS DENIED');
      expect(AlertsRow.on.subtitle, isNull);
      expect(AlertsRow.noHost.interactive, isFalse);
    });
  });

  group('the reconnect schedule', () {
    test('doubles from 5 s and stops at 60 s', () {
      final backoff = WatcherBackoff();
      final seen = <int>[];
      for (var attempt = 0; attempt < 6; attempt++) {
        seen.add(backoff.current.inSeconds);
        backoff.advance();
      }
      expect(seen, [5, 10, 20, 40, 60, 60]);
    });

    test('a snapshot puts the next outage back at the start', () {
      final backoff = WatcherBackoff()
        ..advance()
        ..advance()
        ..advance();
      expect(backoff.current, const Duration(seconds: 40));

      // What a connection that carried a snapshot does: an outage after hours
      // of quiet retries in 5 s, not in whatever the last bad night reached.
      backoff.reset();
      expect(backoff.current, watcherMinBackoff);
      backoff.advance();
      expect(backoff.current, const Duration(seconds: 10));
    });
  });

  group('the watcher feed', () {
    Future<void> pump() => Future<void>.delayed(Duration.zero);

    String report(AgentOutcomeKind kind) => jsonEncode(
      WatcherReport(
        hostId: host.id,
        kind: kind,
        retryIn: const Duration(seconds: 5),
      ).toJson(),
    );

    test('drops the service\'s last word once the service is gone', () async {
      final hosts = StreamController<List<Host>>();
      final data = StreamController<Object>();
      final running = StreamController<bool>();
      addTearDown(hosts.close);
      addTearDown(data.close);
      addTearDown(running.close);

      final seen = <AgentPanelState?>[];
      final subscription = AgentWatcher.feed(
        hosts.stream,
        data: data.stream,
        running: running.stream,
      ).listen(seen.add);
      addTearDown(subscription.cancel);

      hosts.add(const [host]);
      data.add(report(AgentOutcomeKind.unreachable));
      await pump();
      expect(seen.last?.outcomes.single.kind, AgentOutcomeKind.unreachable);

      // The toggle going off hands Home straight back to its own poll.
      // Holding the last report would freeze the panel on `nyx unreachable ·
      // retry 5s` for a host that is fine.
      running.add(false);
      await pump();
      expect(seen.last, isNull);

      data.add(report(AgentOutcomeKind.snapshot));
      await pump();
      expect(seen.last?.outcomes.single.kind, AgentOutcomeKind.snapshot);
    });
  });

  group('the remote commands', () {
    test('run Herdr in the configured session through sh', () {
      expect(HerdrCommands.list(), contains('HERDR_SESSION='));
      expect(HerdrCommands.list(), contains('hub'));
      expect(HerdrCommands.list(), contains('herdr agent list'));
      expect(HerdrCommands.watch(), contains('sleep 2'));
      expect(HerdrCommands.read('wQ:p1'), contains('agent read'));
      expect(
        HerdrCommands.keys('wQ:p1', const ['enter']),
        contains('agent send-keys'),
      );
    });
  });

  test('a watch stream of one JSON document per line parses', () async {
    String line(String status, int seq) => jsonEncode({
      'id': 'cli:agent:list',
      'result': {
        'type': 'agent_list',
        'agents': [
          {
            'agent': 'claude',
            'agent_status': status,
            'cwd': '/home/luisnquin/src',
            'pane_id': 'wQ:p1',
            'state_change_seq': seq,
            'terminal_title_stripped': 'spectacle',
            'workspace_id': 'wQ',
          },
        ],
      },
    });

    final working = line('working', 1);
    final blocked = line('blocked', 2);
    final stream = '$working\n$blocked\n';
    // The remote loop writes whole lines, but tcp may cut them anywhere, so the
    // split has to be the line terminator's job and not the packet's.
    final cut = working.length + 12;
    final bytes = Stream<List<int>>.fromIterable([
      utf8.encode(stream.substring(0, cut)),
      utf8.encode(stream.substring(cut)),
    ]);
    final frames = await HerdrClient.parseWatchStream(bytes).toList();

    expect(frames, hasLength(2));
    expect(frames.first.single.agentStatus, 'working');
    expect(frames.first.single.blocked, isFalse);
    expect(frames.last.single.agentStatus, 'blocked');
    expect(frames.last.single.blocked, isTrue);
  });

  group('the notification body', () {
    test('is the agent uppercased over the stripped title', () {
      expect(alertTitle(snapshot()), 'CLAUDE BLOCKED');
      expect(alertText(snapshot()), 'ALLOW touch probe.txt?');
    });

    test('reads an empty agent as ?', () {
      expect(alertTitle(snapshot(agent: '')), '? BLOCKED');
      expect(alertTitle(snapshot(agent: '  ')), '? BLOCKED');
    });

    test('carries the action states', () {
      expect(alertSentLine(yes: true), 'SENT · YES');
      expect(alertSentLine(yes: false), 'SENT · NO');
      expect(alertFailedLine('UNREACHABLE'), 'FAILED · UNREACHABLE');
      expect(alertFailureReason(const HerdrKeyRejected()), 'KEY REJECTED');
      expect(
        alertFailureReason(const HerdrProtocolMismatch(20)),
        'PROTOCOL 20',
      );
      expect(alertFailureReason(const HerdrUnreachable()), 'UNREACHABLE');
    });

    test(
      'the persistent line counts hosts, or names the first that is down',
      () {
        expect(
          watcherNotificationText([
            const HostOutcome(host: host, kind: AgentOutcomeKind.snapshot),
          ]),
          'WATCHING 1 HOST',
        );
        expect(
          watcherNotificationText(const [
            HostOutcome(host: host, kind: AgentOutcomeKind.snapshot),
            HostOutcome(host: host, kind: AgentOutcomeKind.snapshot),
          ]),
          'WATCHING 2 HOSTS',
        );
        expect(
          watcherNotificationText(
            const [HostOutcome(host: host, kind: AgentOutcomeKind.unreachable)],
            retries: const {'h1': Duration(seconds: 30)},
          ),
          'NYX UNREACHABLE · RETRY 30S',
        );
      },
    );
  });

  test('an alert target survives the trip through a notification payload', () {
    final target = AlertTarget.forHost(host, snapshot());
    final decoded = AlertTarget.decode(target.encode())!;

    expect(decoded.address, '100.64.0.1');
    expect(decoded.port, 22);
    expect(decoded.user, 'luisnquin');
    expect(decoded.keyId, 'k1');
    expect(decoded.paneId, 'wQ:p1');
    expect(decoded.agent, 'claude');
    expect(decoded.text, 'ALLOW touch probe.txt?');
    expect(decoded.title, 'CLAUDE BLOCKED');
    // The secret is not on the notification: only the id that finds it.
    expect(target.encode(), isNot(contains('PRIVATE KEY')));
    expect(AlertTarget.decode(null), isNull);
    expect(AlertTarget.decode('{'), isNull);
  });

  test('a watcher report round-trips between the isolates', () {
    final report = WatcherReport(
      hostId: 'h1',
      kind: AgentOutcomeKind.unreachable,
      agents: [snapshot()],
      lastGoodAt: DateTime.fromMillisecondsSinceEpoch(1750000000000),
      retryIn: const Duration(seconds: 20),
    );
    final decoded = WatcherReport.fromJson(
      jsonDecode(jsonEncode(report.toJson())) as Map<String, Object?>,
    )!;

    expect(decoded.kind, AgentOutcomeKind.unreachable);
    expect(decoded.agents.single.paneId, 'wQ:p1');
    expect(decoded.lastGoodAt, report.lastGoodAt);
    expect(decoded.retryIn, const Duration(seconds: 20));
    expect(decoded.toOutcome(host).reason, 'nyx unreachable');
  });

  test(
    'the watcher dials with a verifier that refuses an unpinned host',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final store = MemoryPrivateKeyStore();
      await store.write('k1', 'PRIVATE KEY');
      final client = RecordingHerdrClient();
      final handler = AgentWatcherHandler(
        keys: Ed25519Keys(store),
        client: client,
      );

      // `host` has no key pinned to it, which is the state a host is in until
      // someone stands in front of a fingerprint and says yes.
      await handler.setHosts(const [host]);
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (client.verifiers.isEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await handler.onDestroy(DateTime.now(), false);

      final verifier = client.verifiers.single!;
      // A service in a notification tray has nobody to ask, so the host is not
      // trusted for the first time here: it is left for a route the user is
      // looking at.
      expect(verifier.prompt, isNull);
      expect(
        await verifier.verifyFingerprint('ssh-ed25519', 'SHA256:whatever'),
        isFalse,
      );
      expect(verifier.refusal, HostKeyRefusal.unverified);
    },
  );

  test('a pinned host key survives the trip into the service', () {
    final pinned = Host(
      id: host.id,
      name: host.name,
      address: host.address,
      port: host.port,
      user: host.user,
      keyId: host.keyId,
      hostKey: PinnedHostKey(
        type: 'ssh-ed25519',
        fingerprint: 'SHA256:nyx',
        pinnedAt: DateTime.fromMillisecondsSinceEpoch(1750000000000),
      ),
    );

    final decoded = decodeWatcherHosts(encodeWatcherHosts([pinned])).single;

    expect(decoded.hostKey?.type, 'ssh-ed25519');
    expect(decoded.hostKey?.fingerprint, 'SHA256:nyx');
    expect(decoded.hostKey?.pinnedAt, pinned.hostKey!.pinnedAt);
    expect(
      decodeWatcherHosts(encodeWatcherHosts([host])).single.hostKey,
      isNull,
    );
  });

  test('the watcher dials a pinned host with the pin it was given', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final store = MemoryPrivateKeyStore();
    await store.write('k1', 'PRIVATE KEY');
    final client = RecordingHerdrClient();
    final handler = AgentWatcherHandler(
      keys: Ed25519Keys(store),
      client: client,
    );

    // The state the user is actually in: a key trusted from a route months
    // ago. Without the pin the service refuses this host on every tick, and
    // the row it draws says `host key unverified` about a host nobody can
    // verify any harder.
    final pinned = Host(
      id: host.id,
      name: host.name,
      address: host.address,
      port: host.port,
      user: host.user,
      keyId: host.keyId,
      hostKey: PinnedHostKey(
        type: 'ssh-ed25519',
        fingerprint: 'SHA256:nyx',
        pinnedAt: DateTime.fromMillisecondsSinceEpoch(1750000000000),
      ),
    );
    await handler.setHosts([pinned]);
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (client.verifiers.isEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await handler.onDestroy(DateTime.now(), false);

    final verifier = client.verifiers.single!;
    expect(
      await verifier.verifyFingerprint('ssh-ed25519', 'SHA256:nyx'),
      isTrue,
    );
    expect(verifier.refusal, isNull);
    // The machine answering with something else is still refused, and still
    // without a prompt: the service has nobody to ask.
    expect(
      await verifier.verifyFingerprint('ssh-ed25519', 'SHA256:someone-else'),
      isFalse,
    );
    expect(verifier.refusal, HostKeyRefusal.changed);
  });
}
