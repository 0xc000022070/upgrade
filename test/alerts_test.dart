import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/application/agent_state.dart';
import 'package:dazzle/application/agents.dart';
import 'package:dazzle/application/alerts.dart';
import 'package:dazzle/application/pin_alerts.dart';
import 'package:dazzle/data/repositories/host_repository.dart';
import 'package:dazzle/platform/agent_watcher.dart';
import 'package:dazzle/platform/herdr_client.dart';
import 'package:dazzle/platform/host_links.dart';
import 'package:dazzle/platform/herdr_socket.dart';
import 'package:dazzle/platform/host_keys.dart';
import 'package:dazzle/platform/keys.dart';

import 'support/herdr_link.dart';

/// Never dials: it keeps what it was handed to check the host with, and reports the host
/// as down so the loop backs off instead of looping on it.
class RecordingHerdrClient extends HerdrClient {
  RecordingHerdrClient({this.failures = const {}}) : super(links: HostLinks());

  final Map<String, HerdrFailure> failures;

  final verifiers = <HostKeyVerifier?>[];
  final dials = <String>[];

  @override
  Future<HerdrSession> connect({
    required String address,
    required int port,
    required String user,
    required String privateKey,
    HostKeyVerifier? verifier,
    void Function(Future<void> settled)? onSettling,
  }) async {
    verifiers.add(verifier);
    dials.add(address);
    throw failures[address] ??
        const HerdrUnreachable('no machine behind a test');
  }
}

class _PinRecorder implements PinNotifier {
  final raised = <String>[];

  @override
  Future<void> raise({
    required String hostId,
    required String askId,
    required String text,
  }) async => raised.add(hostId);

  @override
  Future<void> withdraw(String hostId) async {}
}

class _NoWatchSession implements HerdrSession {
  _NoWatchSession(this.listing);

  final String listing;
  final _agents = StreamController<List<AgentSnapshot>>();
  var asked = 0;

  @override
  Stream<List<AgentSnapshot>> watch() => _agents.stream;

  @override
  Stream<String> pinRequestChanges() => const Stream.empty();

  @override
  Future<String> openPinRequests({Duration within = pinWatchInterval}) async {
    asked++;
    return listing;
  }

  @override
  void close() => unawaited(_agents.close());

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _EngineSession extends _NoWatchSession {
  _EngineSession(super.listing);

  final _held = Completer<Object?>();

  @override
  Future<Object?> engine(Map<String, Object?> request, {Duration? within}) =>
      _held.future;

  @override
  void close() {
    _held.future.ignore();
    if (!_held.isCompleted) {
      _held.completeError(const HerdrUnreachable('closed'));
    }
    super.close();
  }
}

class _FreshSessionClient extends HerdrClient {
  _FreshSessionClient(this.next) : super(links: HostLinks());

  final HerdrSession Function() next;

  @override
  Future<HerdrSession> connect({
    required String address,
    required int port,
    required String user,
    required String privateKey,
    HostKeyVerifier? verifier,
    void Function(Future<void> settled)? onSettling,
  }) async => next();
}

class _SessionClient extends HerdrClient {
  _SessionClient(this.session) : super(links: HostLinks());

  final HerdrSession session;

  @override
  Future<HerdrSession> connect({
    required String address,
    required int port,
    required String user,
    required String privateKey,
    HostKeyVerifier? verifier,
    void Function(Future<void> settled)? onSettling,
  }) async => session;
}

AgentSnapshot snapshot({
  String pane = 'wQ:p1',
  String agent = 'claude',
  String status = 'blocked',
  String title = 'ALLOW touch probe.txt?',
  String session = 'default',
  String? approval,
}) => AgentSnapshot(
  session: session,
  approval: approval == null
      ? null
      : AgentApproval(id: approval, tool: 'Bash', summary: 'rm -rf build'),
  paneId: pane,
  agent: agent,
  state: AgentState.of(status),
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

const other = Host(
  id: 'h2',
  name: 'rose',
  address: '100.64.0.2',
  port: 22,
  user: 'luisnquin',
  keyId: 'k1',
);

void main() {
  group('the blocked edge', () {
    AgentEdges blockedEdges() => AgentEdges(AlertKind.blocked);

    test('fires once per episode, and again after an unblock', () {
      final edges = blockedEdges();

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

    test(
      'counts every blocked pane as new on the service\'s first snapshot',
      () {
        final edges = blockedEdges();
        final first = edges.apply('h1', [snapshot(), snapshot(pane: 'wQ:p2')]);
        expect(first.entered, hasLength(2));
        expect(first.left, isEmpty);
      },
    );

    test('a reconnect keeps the set, so nothing still blocked re-enters', () {
      final edges = blockedEdges();
      expect(edges.apply('h1', [snapshot()]).entered, hasLength(1));

      final rejoined = edges.apply('h1', [snapshot()]);
      expect(rejoined.entered, isEmpty, reason: 'no re-alert, no sound');
      expect(rejoined.left, isEmpty);
      expect(edges.panesOn('h1'), {'wQ:p1'});
    });

    test('what changed while the link was down still reads as an edge', () {
      final edges = blockedEdges();
      edges.apply('h1', [snapshot(), snapshot(pane: 'wQ:p2')]);

      final rejoined = edges.apply('h1', [
        snapshot(pane: 'wQ:p2'),
        snapshot(pane: 'wQ:p3'),
      ]);
      expect(rejoined.left, ['wQ:p1'], reason: 'its notification is cancelled');
      expect(rejoined.entered.map((agent) => agent.paneId), ['wQ:p3']);

      expect(
        edges.apply('h1', [
          snapshot(pane: 'wQ:p2'),
          snapshot(pane: 'wQ:p3'),
        ]).isEmpty,
        isTrue,
      );
    });

    test(
      'reset is what a host going away does, and it alone makes panes new',
      () {
        final edges = blockedEdges();
        edges.apply('h1', [snapshot()]);
        expect(edges.apply('h1', [snapshot()]).entered, isEmpty);

        edges.reset('h1');
        expect(edges.panesOn('h1'), isEmpty);
        expect(edges.apply('h1', [snapshot()]).entered, hasLength(1));
      },
    );

    test('a pane that disappears leaves blocked', () {
      final edges = blockedEdges();
      edges.apply('h1', [snapshot()]);
      expect(edges.apply('h1', const []).left, ['wQ:p1']);
    });

    test('two hosts blocking the same pane id are two episodes', () {
      final edges = blockedEdges();
      expect(edges.apply('h1', [snapshot()]).entered, hasLength(1));
      expect(edges.apply('h2', [snapshot()]).entered, hasLength(1));
      expect(edges.panesOn('h1'), {'wQ:p1'});
    });

    test('an approval running out settles quietly into the question', () {
      final edges = blockedEdges();
      expect(
        edges.apply('h1', [snapshot(approval: 'a1')]).entered,
        hasLength(1),
      );

      final expired = edges.apply('h1', [snapshot()]);
      expect(expired.left, ['wQ:p1#a1']);
      expect(expired.entered.map((agent) => agent.edgeId), ['wQ:p1']);
      expect(expired.quiet, {'wQ:p1'}, reason: 'nothing new happened');
    });

    test('a new approval on the same pane still alerts', () {
      final edges = blockedEdges();
      edges.apply('h1', [snapshot(approval: 'a1')]);

      final next = edges.apply('h1', [snapshot(approval: 'a2')]);
      expect(next.entered.map((agent) => agent.edgeId), ['wQ:p1#a2']);
      expect(next.quiet, isEmpty);

      edges.apply('h1', [snapshot()]);
      final asked = edges.apply('h1', [snapshot(approval: 'a3')]);
      expect(asked.entered.map((agent) => agent.edgeId), ['wQ:p1#a3']);
      expect(asked.quiet, isEmpty);
    });
  });

  group('the finished edge', () {
    AgentEdges doneEdges() => AgentEdges(AlertKind.done);

    test('fires when the pane stops working, not while it is at rest', () {
      final edges = doneEdges();
      expect(edges.apply('h1', [snapshot(status: 'working')]).isEmpty, isTrue);

      final finished = edges.apply('h1', [snapshot(status: 'done')]);
      expect(finished.entered.map((agent) => agent.paneId), ['wQ:p1']);

      expect(edges.apply('h1', [snapshot(status: 'done')]).isEmpty, isTrue);
    });

    test('an agent picked back up leaves done, and can finish again', () {
      final edges = doneEdges();
      edges.apply('h1', [snapshot(status: 'done')]);

      final resumed = edges.apply('h1', [snapshot(status: 'working')]);
      expect(resumed.left, ['wQ:p1'], reason: 'its notification is cancelled');

      expect(
        edges.apply('h1', [snapshot(status: 'done')]).entered,
        hasLength(1),
      );
    });

    test('idle is not finished, and neither is blocked', () {
      final edges = doneEdges();
      expect(edges.apply('h1', [snapshot(status: 'idle')]).isEmpty, isTrue);
      expect(edges.apply('h1', [snapshot()]).isEmpty, isTrue);
      expect(edges.panesOn('h1'), isEmpty);
    });

    test('the two kinds read the same snapshot apart', () {
      const finished = [
        AgentSnapshot(
          session: 'default',
          paneId: 'wQ:p1',
          agent: 'claude',
          state: DoneState(),
          terminalTitleStripped: 'wrote the migration',
          workspaceId: 'wQ',
          cwd: '/home/luisnquin/src',
          stateChangeSeq: 4,
        ),
      ];
      expect(AlertKind.blocked.holds(finished.single), isFalse);
      expect(AlertKind.done.holds(finished.single), isTrue);
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
      expect(
        target.notificationIdFor(AlertKind.done),
        kindNotificationId(AlertKind.done, 'h1', 'wQ:p1'),
      );
    });

    test('a pane that blocked and then finished posts under two of them', () {
      final blocked = kindNotificationId(AlertKind.blocked, 'h1', 'wQ:p1');
      final done = kindNotificationId(AlertKind.done, 'h1', 'wQ:p1');

      expect(blocked, isNot(done));
      expect(done, isNot(watcherNotificationId));
      expect(done, lessThan(1 << 31));
      expect(done, greaterThan(0));
      expect(blocked, alertNotificationId('h1', 'wQ:p1'));
    });

    test('a kind never collides across hosts or panes', () {
      expect(
        kindNotificationId(AlertKind.done, 'h1', 'wQ:p1'),
        isNot(kindNotificationId(AlertKind.done, 'h2', 'wQ:p1')),
      );
      expect(
        kindNotificationId(AlertKind.done, 'h1', 'wQ:p1'),
        isNot(kindNotificationId(AlertKind.done, 'h1', 'wQ:p2')),
      );
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
      Set<AlertKind> alerts = const {},
      required List<Host> hosts,
      Set<AlertKind> denied = const {},
    }) {
      final container = ProviderContainer(
        overrides: [
          alertsEnabledProvider.overrideWith(
            (ref, kind) => Stream.value(alerts.contains(kind)),
          ),
          agentChannelsProvider.overrideWith(
            (ref) => Stream.value([
              for (final host in hosts) (host: host, source: AgentSource.herdr),
            ]),
          ),
          if (denied.isNotEmpty)
            alertsDeniedProvider.overrideWith((ref) => denied),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    Future<AlertsRow> row(ProviderContainer container, AlertKind kind) async {
      await container.read(alertsEnabledProvider(kind).future);
      await container.read(agentChannelsProvider.future);
      return container.read(alertsRowProvider(kind));
    }

    test('only with a toggle on and a HERDR host', () async {
      final on = containerWith(
        alerts: {AlertKind.blocked},
        hosts: const [host],
      );
      expect(await row(on, AlertKind.blocked), AlertsRow.on);
      expect(on.read(watcherWantedProvider), isTrue);

      final off = containerWith(hosts: const [host]);
      expect(await row(off, AlertKind.blocked), AlertsRow.off);
      expect(off.read(watcherWantedProvider), isFalse);

      final hostless = containerWith(
        alerts: {AlertKind.blocked},
        hosts: const [],
      );
      expect(await row(hostless, AlertKind.blocked), AlertsRow.noHost);
      expect(hostless.read(watcherWantedProvider), isFalse);
    });

    test('for either row on its own, and for both together', () async {
      final finished = containerWith(
        alerts: {AlertKind.done},
        hosts: const [host],
      );
      expect(await row(finished, AlertKind.blocked), AlertsRow.off);
      expect(await row(finished, AlertKind.done), AlertsRow.on);
      expect(finished.read(alertsWantedProvider), {AlertKind.done});
      expect(finished.read(watcherWantedProvider), isTrue);

      final both = containerWith(
        alerts: AlertKind.values.toSet(),
        hosts: const [host],
      );
      for (final kind in AlertKind.values) {
        expect(await row(both, kind), AlertsRow.on);
      }
      expect(both.read(alertsWantedProvider), AlertKind.values.toSet());
    });

    test('never while the OS has refused notifications', () async {
      final denied = containerWith(
        alerts: AlertKind.values.toSet(),
        hosts: const [host],
        denied: {AlertKind.blocked},
      );
      expect(await row(denied, AlertKind.blocked), AlertsRow.denied);
      expect(await row(denied, AlertKind.done), AlertsRow.on);
      expect(denied.read(alertsWantedProvider), {AlertKind.done});
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

      backoff.reset();
      expect(backoff.current, watcherMinBackoff);
      backoff.advance();
      expect(backoff.current, const Duration(seconds: 10));
    });

    test('a refused credential is not among the failures it knocks on', () {
      expect(AgentOutcomeKind.unreachable.retryable, isTrue);
      expect(AgentOutcomeKind.unresolved.retryable, isTrue);
      expect(AgentOutcomeKind.protocolMismatch.retryable, isTrue);

      expect(AgentOutcomeKind.keyRejected.retryable, isFalse);
      expect(AgentOutcomeKind.hostKeyUnverified.retryable, isFalse);
      expect(AgentOutcomeKind.hostKeyChanged.retryable, isFalse);
    });

    test('the loop stands on a refusal and knocks on a bad route', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final store = MemoryPrivateKeyStore();
      await store.write('k1', 'PRIVATE KEY');
      final client = RecordingHerdrClient(
        failures: {host.address: const HerdrKeyRejected('key rejected')},
      );
      final handler = AgentWatcherHandler(
        keys: Ed25519Keys(store),
        client: client,
      );

      await handler.setHosts(const [host, other]);
      await Future<void>.delayed(
        watcherMinBackoff + const Duration(seconds: 1),
      );
      await handler.onDestroy(DateTime.now(), false);

      expect(
        client.dials.where((address) => address == host.address),
        hasLength(1),
      );
      expect(
        client.dials.where((address) => address == other.address).length,
        greaterThan(1),
      );
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
      final hosts = StreamController<List<AgentChannel>>();
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

      hosts.add(const [(host: host, source: AgentSource.herdr)]);
      data.add(report(AgentOutcomeKind.unreachable));
      await pump();
      expect(seen.last?.outcomes.single.kind, AgentOutcomeKind.unreachable);

      running.add(false);
      await pump();
      expect(seen.last, isNull);

      data.add(report(AgentOutcomeKind.snapshot));
      await pump();
      expect(seen.last?.outcomes.single.kind, AgentOutcomeKind.snapshot);
    });

    testWidgets('asks after the service only while the app is seen', (
      tester,
    ) async {
      final visible = StreamController<bool>();
      addTearDown(visible.close);
      var asked = 0;
      final subscription = AgentWatcher.serviceLiveness(
        visible: visible.stream,
        isRunning: () async {
          asked++;
          return true;
        },
      ).listen((_) {});
      addTearDown(subscription.cancel);

      visible.add(false);
      await tester.pump(watcherLivenessPeriod * 6);
      expect(asked, 0);

      visible.add(true);
      await tester.pump();
      expect(asked, 1);
      await tester.pump(watcherLivenessPeriod * 2);
      expect(asked, 3);

      visible.add(false);
      await tester.pump(watcherLivenessPeriod * 6);
      expect(asked, 3);
    });
  });

  group('the remote surface', () {
    const pane = (session: 'lab', pane: 'wQ:p1');

    test('a pane is watched for its own status changes', () {
      expect(HerdrRequests.paneStatus(pane), [
        {'type': 'pane.agent_status_changed', 'pane_id': 'wQ:p1'},
      ]);
      expect(
        HerdrRequests.paneSet.map((subscription) => subscription['type']),
        isNot(contains('pane.agent_status_changed')),
      );
      expect(
        () => HerdrRequests.paneStatus((session: 'lab', pane: 'wQ:p1; reboot')),
        throwsA(isA<HerdrProtocolMismatch>()),
      );
    });

    test('a read and a send name the pane and nothing else', () {
      expect(HerdrRequests.read(pane).params, {
        'target': 'wQ:p1',
        'source': 'visible',
        'lines': 8,
        'format': 'text',
      });
      expect(HerdrRequests.sendKeys(pane, const ['enter']).params, {
        'target': 'wQ:p1',
        'keys': ['enter'],
      });
    });
  });

  test('a status event wakes a list that reads the pane as blocked', () async {
    final watching = FakeHerdrLink();
    final listing = FakeHerdrLink();
    addTearDown(watching.dispose);
    addTearDown(listing.dispose);

    final events = HerdrApi(
      () async => watching.link,
    ).subscribe(HerdrRequests.paneStatus((session: 'default', pane: 'wQ:p1')));
    final woken = events.first;
    watching.say(const {
      'id': 'dazzle:0',
      'result': {'type': 'subscription_started'},
    });
    watching.say(const {
      'event': 'pane.agent_status_changed',
      'data': {'pane_id': 'wQ:p1'},
    });

    expect((await woken).kind, 'pane_agent_status_changed');

    final reply = HerdrApi(() async => listing.link).call('agent.list');
    listing.say(
      herdrResult(agentListResult('wQ:p1', status: 'blocked', seq: 2)),
    );
    final agents = HerdrClient.parseSessionAgents(
      await reply,
      session: 'default',
    );

    expect(agents.single.state.word, 'blocked');
    expect(agents.single.blocked, isTrue);
    expect(agents.single.session, 'default');
    expect(listing.sent.single['method'], 'agent.list');
    expect(watching.sent.single['params'], {
      'subscriptions': [
        {'type': 'pane.agent_status_changed', 'pane_id': 'wQ:p1'},
      ],
    });
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

    test('a finished agent says so, over the same stripped title', () {
      expect(AlertKind.done.title('claude'), 'CLAUDE DONE');
      expect(AlertKind.done.title(' codex '), 'CODEX DONE');
      expect(AlertKind.done.title(''), '? DONE');
      expect(AlertKind.blocked.label, 'BLOCKED AGENTS');
      expect(AlertKind.done.label, 'FINISHED AGENTS');
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
      'the persistent line counts hosts when nothing is happening on them',
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

    test('the persistent line says what the agents are doing', () {
      expect(
        watcherNotificationText([
          HostOutcome(
            host: host,
            kind: AgentOutcomeKind.snapshot,
            agents: [
              snapshot(pane: 'wQ:p1', status: 'working'),
              snapshot(pane: 'wQ:p2', status: 'working'),
              snapshot(pane: 'wQ:p3'),
              snapshot(pane: 'wQ:p4', status: 'idle'),
            ],
          ),
        ]),
        '1 BLOCKED · 2 WORKING',
      );
    });

    test('the tally counts across every host, and drops what is zero', () {
      expect(
        watcherNotificationText([
          HostOutcome(
            host: host,
            kind: AgentOutcomeKind.snapshot,
            agents: [snapshot(pane: 'wQ:p1', status: 'working')],
          ),
          HostOutcome(
            host: other,
            kind: AgentOutcomeKind.snapshot,
            agents: [snapshot(pane: 'wR:p1', status: 'working')],
          ),
        ]),
        '2 WORKING',
      );
    });

    test('agents at rest leave the line to the host count', () {
      expect(
        watcherNotificationText([
          HostOutcome(
            host: host,
            kind: AgentOutcomeKind.snapshot,
            agents: [
              snapshot(pane: 'wQ:p1', status: 'done'),
              snapshot(pane: 'wQ:p2', status: 'idle'),
              snapshot(pane: 'wQ:p3', status: 'compacting'),
            ],
          ),
        ]),
        'WATCHING 1 HOST',
      );
    });

    test('the count leaves out the agents a failed host left behind', () {
      expect(
        agentTally([
          HostOutcome(
            host: host,
            kind: AgentOutcomeKind.unreachable,
            agents: [
              snapshot(pane: 'wQ:p1', status: 'working'),
              snapshot(pane: 'wQ:p2'),
            ],
          ),
          HostOutcome(
            host: other,
            kind: AgentOutcomeKind.snapshot,
            agents: [snapshot(pane: 'wR:p1', status: 'working')],
          ),
        ]),
        '1 WORKING',
      );
    });

    test('a host that is down takes the line from the tally', () {
      expect(
        watcherNotificationText([
          HostOutcome(
            host: host,
            kind: AgentOutcomeKind.snapshot,
            agents: [snapshot(pane: 'wQ:p1', status: 'working')],
          ),
          const HostOutcome(host: other, kind: AgentOutcomeKind.unreachable),
        ]),
        'ROSE UNREACHABLE',
      );
    });
  });

  test('an alert target survives the trip through a notification payload', () {
    final target = AlertTarget.forHost(host, snapshot(session: 'lab'));
    final decoded = AlertTarget.decode(target.encode())!;

    expect(decoded.address, '100.64.0.1');
    expect(decoded.session, 'lab');
    expect(decoded.pane, (session: 'lab', pane: 'wQ:p1'));
    expect(decoded.port, 22);
    expect(decoded.user, 'luisnquin');
    expect(decoded.keyId, 'k1');
    expect(decoded.paneId, 'wQ:p1');
    expect(decoded.agent, 'claude');
    expect(decoded.text, 'ALLOW touch probe.txt?');
    expect(decoded.title, 'CLAUDE BLOCKED');
    expect(target.encode(), isNot(contains('PRIVATE KEY')));
    expect(AlertTarget.decode(null), isNull);
    expect(AlertTarget.decode('{'), isNull);
  });

  test('a herdr alert carries the pin its answer is dialled against', () {
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
    final target = AlertTarget.forHost(pinned, snapshot(), channel: host.id);
    final decoded = AlertTarget.decode(target.encode())!;

    expect(decoded.engine, isFalse);
    expect(decoded.hostKey?.fingerprint, 'SHA256:nyx');
  });

  test('a watcher report round-trips between the isolates', () {
    final report = WatcherReport(
      hostId: 'h1',
      kind: AgentOutcomeKind.unreachable,
      agents: [snapshot()],
      lastGoodAt: DateTime.fromMillisecondsSinceEpoch(1750000000000),
      retryIn: const Duration(seconds: 20),
      requestId: 'request-1',
    );
    final decoded = WatcherReport.fromJson(
      jsonDecode(jsonEncode(report.toJson())) as Map<String, Object?>,
    )!;

    expect(decoded.kind, AgentOutcomeKind.unreachable);
    expect(decoded.agents.single.paneId, 'wQ:p1');
    expect(decoded.lastGoodAt, report.lastGoodAt);
    expect(decoded.retryIn, const Duration(seconds: 20));
    expect(decoded.requestId, 'request-1');
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

      await handler.setHosts(const [host]);
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (client.verifiers.isEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await handler.onDestroy(DateTime.now(), false);

      final verifier = client.verifiers.single!;
      expect(verifier.prompt, isNull);
      expect(
        await verifier.verifyFingerprint('ssh-ed25519', 'SHA256:whatever'),
        isFalse,
      );
      expect(verifier.refusal, HostKeyRefusal.unverified);
    },
  );

  test('a pin watch that ends falls back to asking', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final store = MemoryPrivateKeyStore();
    await store.write('k1', 'PRIVATE KEY');
    final payload = base64Encode(
      utf8.encode(jsonEncode({'mode': 'pin', 'desc': 'the key'})),
    );
    final session = _NoWatchSession('0123456789abcdef $payload\n');
    final pins = _PinRecorder();
    final handler = AgentWatcherHandler(
      keys: Ed25519Keys(store),
      client: _SessionClient(session),
      pins: pins,
    );

    await handler.setHosts(const [host]);
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (pins.raised.isEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await handler.onDestroy(DateTime.now(), false);

    expect(session.asked, 1);
    expect(pins.raised, [host.id]);
  });

  test('a host watched through the engine lists the pinentry, once', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final store = MemoryPrivateKeyStore();
    await store.write('k1', 'PRIVATE KEY');
    final payload = base64Encode(
      utf8.encode(jsonEncode({'mode': 'pin', 'desc': 'the key'})),
    );
    final sessions = <_EngineSession>[];
    final pins = _PinRecorder();
    final handler = AgentWatcherHandler(
      keys: Ed25519Keys(store),
      client: _FreshSessionClient(() {
        final session = _EngineSession('0123456789abcdef $payload\n');
        sessions.add(session);
        return session;
      }),
      pins: pins,
    );

    await handler.setHosts(
      const [host],
      sources: {
        host.id: {AgentSource.herdr, AgentSource.engine},
      },
    );
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (pins.raised.isEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await handler.setHosts(
      const [host],
      sources: {
        host.id: {AgentSource.engine},
      },
    );
    final again = DateTime.now().add(const Duration(seconds: 5));
    while (pins.raised.length < 2 && DateTime.now().isBefore(again)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await handler.onDestroy(DateTime.now(), false);

    expect(sessions.fold(0, (sum, session) => sum + session.asked), 2);
    expect(pins.raised, [host.id, host.id]);
  });

  test('a host retry interrupts its backoff', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final store = MemoryPrivateKeyStore();
    await store.write('k1', 'PRIVATE KEY');
    final client = RecordingHerdrClient();
    final handler = AgentWatcherHandler(
      keys: Ed25519Keys(store),
      client: client,
    );
    await handler.setHosts(const [host]);
    final first = DateTime.now().add(const Duration(seconds: 2));
    while (client.dials.isEmpty && DateTime.now().isBefore(first)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    handler.retryHost(host.id, 'request-1');
    final second = DateTime.now().add(const Duration(seconds: 2));
    while (client.dials.length < 2 && DateTime.now().isBefore(second)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await handler.onDestroy(DateTime.now(), false);

    expect(client.dials, hasLength(2));
  });

  test('the wanted kinds survive the trip into the service', () {
    expect(decodeWatcherKinds(encodeWatcherKinds({AlertKind.done})), {
      AlertKind.done,
    });
    expect(
      decodeWatcherKinds(encodeWatcherKinds(AlertKind.values.toSet())),
      AlertKind.values.toSet(),
    );
    expect(decodeWatcherKinds(encodeWatcherKinds(const {})), isEmpty);
    expect(decodeWatcherKinds(null), isEmpty);
    expect(decodeWatcherKinds('{'), isEmpty);
    expect(decodeWatcherKinds('["failed"]'), isEmpty);
  });

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
    expect(
      await verifier.verifyFingerprint('ssh-ed25519', 'SHA256:someone-else'),
      isFalse,
    );
    expect(verifier.refusal, HostKeyRefusal.changed);
  });
}
