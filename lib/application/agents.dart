import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/enums.dart';
import '../data/repositories/host_repository.dart';
import '../data/repositories/key_repository.dart';
import '../platform/herdr_client.dart';
import '../platform/host_key_dial.dart';
import '../platform/host_keys.dart';
import 'reason_lines.dart';
import '../platform/keys.dart';

/// What one host answered on the last poll. Every host with
/// `HERDR` on is polled, so a failure is a property of a host and not of the
/// panel — one bad host contributes its own dim line while the others still
/// render rows.
enum AgentOutcomeKind {
  snapshot,
  unreachable,
  unresolved,
  keyRejected,
  protocolMismatch,

  /// The host has no key pinned. The poll never asks — the question belongs on
  /// a screen the user is looking at — so it refuses and says so, and HOSTS
  /// carries the `VERIFY` that answers it.
  hostKeyUnverified,

  /// The host answered with a key that is not the one pinned for it.
  hostKeyChanged;

  /// Whether a watcher that met this may knock again on a timer.
  ///
  /// The line is drawn at the credential. A host that refused the key refuses
  /// it again every time it is asked, and asking is not free: sshd counts
  /// failed authentications per source and answers what follows before it
  /// reaches a key at all, for an hour under its own defaults and for a day if
  /// the client keeps knocking. A watcher that retries one of these does not
  /// recover the host, it loses it, and it loses the shell and the screen with
  /// it. The app's own two refusals sit on this side of the line for a plainer
  /// reason: an unpinned key and a changed one are both answered on HOSTS, by
  /// the user, and a loop cannot be the one to answer them.
  ///
  /// Everything else costs the host nothing to be asked twice and can answer
  /// differently without anybody touching the phone: a route that is not there
  /// comes back, a name starts resolving, a herdr too old to understand is
  /// upgraded on the far side.
  bool get retryable => switch (this) {
    keyRejected || hostKeyUnverified || hostKeyChanged => false,
    _ => true,
  };
}

class HostOutcome {
  const HostOutcome({
    required this.host,
    required this.kind,
    this.agents = const [],
    this.lastGoodAt,
    this.protocol,
  });

  final Host host;
  final AgentOutcomeKind kind;

  /// The last good snapshot's agents, kept through a failure so a host that
  /// blinks does not empty the panel.
  final List<AgentSnapshot> agents;
  final DateTime? lastGoodAt;
  final int? protocol;

  bool get ok => kind == AgentOutcomeKind.snapshot;

  /// The words, exactly: `nyx unreachable`, `key rejected`, `protocol N`,
  /// and `nyx unresolved`. The two host-shaped lines name their host
  /// because that is how the spec writes them; [AgentsPanel] prefixes the
  /// others when more than one host is failing and the line would otherwise not
  /// say which.
  String get reason => switch (kind) {
    AgentOutcomeKind.snapshot => '',
    AgentOutcomeKind.unreachable => ReasonLine.unreachable.on(host.name),
    AgentOutcomeKind.unresolved => ReasonLine.unresolved.on(host.name),
    AgentOutcomeKind.keyRejected => ReasonLine.keyRejected.words,
    AgentOutcomeKind.protocolMismatch => protocolLine(protocol),
    AgentOutcomeKind.hostKeyUnverified => ReasonLine.hostKeyUnverified.words,
    AgentOutcomeKind.hostKeyChanged => ReasonLine.hostKeyChanged.words,
  };
}

/// The panel's whole answer: one outcome per host with `HERDR` on.
///
/// Reshaped from a single-host state (user ruling, 2026-09-02). A host is a
/// machine with integrations, there is no selected host, and the panel merges
/// rows across every host that answered.
class AgentPanelState {
  const AgentPanelState(this.outcomes);

  /// No host has `HERDR` on. The panel is blocked, one dim line, no
  /// rows and no footer, and nothing opens a connection. The empty set *is* the
  /// blocked state — there is no separate flag to keep in step with it.
  const AgentPanelState.noHost() : outcomes = const [];

  final List<HostOutcome> outcomes;

  static const blockedLine = 'NO HOST · SET IN SYS';

  /// What the agents are, counted: see [agentTally]. Only the hosts that
  /// answered this round. A failure report carries the last agents its host was
  /// seen with, so that a blink does not empty the panel, and counting those
  /// would be counting work the app has lost sight of.
  String get tally =>
      agentTally(outcomes.where((outcome) => outcome.ok).toList());

  bool get noHost => outcomes.isEmpty;

  /// Merged across hosts. Two hosts running the same agent name are two agents:
  /// they are different machines, and collapsing them would hide work.
  List<AgentSnapshot> get agents => [
    for (final outcome in outcomes) ...outcome.agents,
  ];

  List<HostOutcome> get failures =>
      outcomes.where((outcome) => !outcome.ok).toList();

  /// The most recent good snapshot across every host, which is the timestamp
  /// on the right of a failure line.
  DateTime? get lastGoodAt {
    DateTime? newest;
    for (final outcome in outcomes) {
      final at = outcome.lastGoodAt;
      if (at != null && (newest == null || at.isAfter(newest))) newest = at;
    }
    return newest;
  }
}

String agentSnapshotAge(DateTime now, DateTime timestamp) {
  final age = now.difference(timestamp);
  if (age.inSeconds < 60) return '${age.inSeconds.clamp(0, 59)}s ago';
  if (age.inMinutes < 60) return '${age.inMinutes}m ago';
  return '${age.inHours}h ago';
}

final keyRepositoryProvider = Provider<KeyRepository>(
  (ref) => InMemoryKeyRepository(),
);

final hostRepositoryProvider = Provider<HostRepository>(
  (ref) => InMemoryHostRepository(),
);

final privateKeyStoreProvider = Provider<PrivateKeyStore>(
  (ref) => const SecurePrivateKeyStore(),
);

final ed25519KeysProvider = Provider(
  (ref) => Ed25519Keys(ref.watch(privateKeyStoreProvider)),
);

final managedKeysProvider = StreamProvider<List<ManagedKey>>(
  (ref) => ref.watch(keyRepositoryProvider).watchAll(),
);

final hostsProvider = StreamProvider<List<Host>>(
  (ref) => ref.watch(hostRepositoryProvider).watchAll(),
);

/// The hosts the panel polls. Replaces the selected-host provider: there is no
/// selection any more, only the set of machines with the integration on.
final herdrHostsProvider = StreamProvider<List<Host>>(
  (ref) => ref
      .watch(hostRepositoryProvider)
      .watchWithIntegration(IntegrationKind.herdr),
);

/// What the host form renders its switches from.
final hostIntegrationsProvider =
    StreamProvider.family<Set<IntegrationKind>, String>(
      (ref, hostId) =>
          ref.watch(hostRepositoryProvider).watchIntegrations(hostId),
    );

final homeAgentsVisibleProvider = StateProvider<bool>((ref) => false);

class AppForegroundNotifier extends StateNotifier<bool>
    with WidgetsBindingObserver {
  AppForegroundNotifier()
    : super(
        WidgetsBinding.instance.lifecycleState == null ||
            WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
      ) {
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    this.state = state == AppLifecycleState.resumed;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

final appForegroundProvider =
    StateNotifierProvider<AppForegroundNotifier, bool>(
      (ref) => AppForegroundNotifier(),
    );

/// Nothing outside this typedef's implementation names a transport.
/// Today it is ssh; a backend proxying herdr replaces [HerdrClient] and no host,
/// integration row or provider above changes.
typedef HerdrFetch = Future<List<AgentSnapshot>> Function({
  required String address,
  required int port,
  required String user,
  required String privateKey,
  HostKeyVerifier? verifier,
});

final herdrFetchProvider = Provider<HerdrFetch>((ref) {
  const client = HerdrClient();
  return client.fetch;
});

/// The dial `VERIFY` makes, which opens nothing: it exists to put the host's
/// key in front of the user. Injectable for the same reason every other
/// transport here is.
final hostKeyDialProvider = Provider<HostKeyDial>((ref) => dialHostKey);

class _AgentSnapshotCache {
  final Map<String, _CachedSnapshot> _hosts = {};

  _CachedSnapshot forHost(String hostId) =>
      _hosts.putIfAbsent(hostId, _CachedSnapshot.new);
}

class _CachedSnapshot {
  List<AgentSnapshot> agents = const [];
  DateTime? receivedAt;
}

final _agentSnapshotCacheProvider = Provider((ref) => _AgentSnapshotCache());

/// The watcher's own view of the hosts, or null while no
/// foreground service is running.
///
/// Declared here and overridden in `main()` the way [databaseProvider] is: the
/// implementation reaches the notification plugin and the foreground service,
/// which no widget test can start.
///
/// The default is a stream that says nothing rather than one that emits `null`:
/// a first value would move [agentsFeedProvider] off its own first build, and
/// the rebuild would dial every host a second time before the panel had drawn
/// once. A process with no service never leaves this state, and its reader
/// treats it exactly as it treats `null`.
final watcherFeedProvider = StreamProvider<AgentPanelState?>(
  (ref) => const Stream.empty(),
);

final agentsFeedProvider = StreamProvider<AgentPanelState>((ref) {
  // "While the watcher runs, Home reads its snapshots and its own
  // 10 s poll pauses, so the host sees one connection per phone." Read before
  // the visibility gate, because the watcher's state is what Home shows even
  // while that poll would not be running at all.
  final watched = ref.watch(watcherFeedProvider).valueOrNull;
  if (watched != null) return Stream.value(watched);
  final visible = ref.watch(homeAgentsVisibleProvider);
  final foreground = ref.watch(appForegroundProvider);
  // Never in the background, and never while Home is off screen. The
  // guard is here rather than in the poll loop so a hidden panel holds no ssh
  // connection open at all.
  if (!visible || !foreground) return const Stream.empty();
  final hosts = ref.watch(herdrHostsProvider);
  // The three collaborators are read here rather than inside the generator:
  // the generator's body does not run until something listens, and the
  // watcherFeedProvider emits its first value in between, which leaves the ref
  // outdated and makes any read from it an assertion.
  final fetch = ref.read(herdrFetchProvider);
  final keys = ref.read(ed25519KeysProvider);
  final cache = ref.read(_agentSnapshotCacheProvider);
  return hosts.when(
    data: (list) => list.isEmpty
        ? Stream.value(const AgentPanelState.noHost())
        : _pollHosts(fetch, keys, cache, list),
    loading: () => const Stream.empty(),
    error: (_, _) => const Stream.empty(),
  );
});

/// One tick polls every host at once and emits a single state. Sequential polls
/// would make the panel's refresh interval the sum of the hosts' timeouts — two
/// unreachable hosts alone would push it past the 10s cadence.
Stream<AgentPanelState> _pollHosts(
  HerdrFetch fetch,
  Ed25519Keys keys,
  _AgentSnapshotCache cache,
  List<Host> hosts,
) async* {
  while (true) {
    yield AgentPanelState(
      await Future.wait([
        for (final host in hosts)
          _poll(fetch, keys, cache.forHost(host.id), host),
      ]),
    );
    await Future<void>.delayed(const Duration(seconds: 10));
  }
}

Future<HostOutcome> _poll(
  HerdrFetch fetch,
  Ed25519Keys keys,
  _CachedSnapshot cache,
  Host host,
) async {
  HostOutcome failure(AgentOutcomeKind kind, {int? protocol}) => HostOutcome(
    host: host,
    kind: kind,
    agents: cache.agents,
    lastGoodAt: cache.receivedAt,
    protocol: protocol,
  );

  // Every failure leaves a line in the debug log naming the host and
  // what the transport said, so a report from a handset can be read without
  // guessing which of the four the dim line came from. debugPrint rather than
  // dart:developer: only the former reaches logcat on a handset.
  void log(Object error) => debugPrint('spectacle.herdr ${host.name}: $error');

  final privateKey = await keys.privateKey(host.keyId);
  // The key row survives but its secret does not: the host names a key the
  // keystore no longer has. That is a rejected key from the panel's side, and
  // saying so beats a blank line.
  if (privateKey == null) {
    log('no private key stored for ${host.keyId}');
    return failure(AgentOutcomeKind.keyRejected);
  }
  try {
    final agents = await fetch(
      address: host.address,
      port: host.port,
      user: host.user,
      privateKey: privateKey,
      // The poll runs behind whatever screen is in front. It cannot put a
      // question on it, so an unpinned host is refused here and verified from
      // its HOSTS panel instead.
      verifier: HostKeyVerifier.pinnedOnly(host.hostKey),
    );
    cache
      ..agents = agents
      ..receivedAt = DateTime.now();
    return HostOutcome(
      host: host,
      kind: AgentOutcomeKind.snapshot,
      agents: agents,
      lastGoodAt: cache.receivedAt,
    );
  } on HerdrFailure catch (error) {
    log(error.detail ?? error);
    return switch (error) {
      HerdrKeyRejected() => failure(AgentOutcomeKind.keyRejected),
      HerdrProtocolMismatch() => failure(
        AgentOutcomeKind.protocolMismatch,
        protocol: error.protocol,
      ),
      HerdrUnresolved() => failure(AgentOutcomeKind.unresolved),
      HerdrUnreachable() => failure(AgentOutcomeKind.unreachable),
      HerdrHostKeyUnverified() => failure(AgentOutcomeKind.hostKeyUnverified),
      HerdrHostKeyChanged() => failure(AgentOutcomeKind.hostKeyChanged),
    };
  }
}

/// `1 BLOCKED · 3 WORKING`, across every host, blocked first.
///
/// Only the states that earn a row on the AGENTS panel are counted, and for the
/// same reason: an agent at rest is the night going the way it was meant to,
/// and a surface that says so once a minute is a surface that stops being read.
/// Empty when nothing is active, which is what lets each of the places this is
/// drawn say the quieter thing it has instead.
String agentTally(List<HostOutcome> outcomes) {
  var blocked = 0;
  var working = 0;
  for (final outcome in outcomes) {
    for (final agent in outcome.agents) {
      if (agent.state.blocked) {
        blocked++;
      } else if (agent.state.active) {
        working++;
      }
    }
  }
  return [
    if (blocked > 0) '$blocked BLOCKED',
    if (working > 0) '$working WORKING',
  ].join(' · ');
}
