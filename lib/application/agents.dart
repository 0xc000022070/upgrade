import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/enums.dart';
import '../data/repositories/host_repository.dart';
import '../data/repositories/key_repository.dart';
import '../platform/herdr_client.dart';
import '../platform/keys.dart';

/// What one host answered on the last poll. SPEC.md §39.20: every host with
/// `HERDR` on is polled, so a failure is a property of a host and not of the
/// panel — one bad host contributes its own dim line while the others still
/// render rows.
enum AgentOutcomeKind {
  snapshot,
  unreachable,
  unresolved,
  keyRejected,
  protocolMismatch,
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

  /// §39.20's words, exactly: `nyx unreachable`, `key rejected`, `protocol N`,
  /// and §39.29's `nyx unresolved`. The two host-shaped lines name their host
  /// because that is how the spec writes them; [AgentsPanel] prefixes the
  /// others when more than one host is failing and the line would otherwise not
  /// say which.
  String get reason => switch (kind) {
    AgentOutcomeKind.snapshot => '',
    AgentOutcomeKind.unreachable => '${host.name.toLowerCase()} unreachable',
    AgentOutcomeKind.unresolved => '${host.name.toLowerCase()} unresolved',
    AgentOutcomeKind.keyRejected => 'key rejected',
    AgentOutcomeKind.protocolMismatch => 'protocol ${protocol ?? '?'}',
  };
}

/// The panel's whole answer: one outcome per host with `HERDR` on.
///
/// Reshaped from a single-host state (user ruling, 2026-09-02). A host is a
/// machine with integrations, there is no selected host, and the panel merges
/// rows across every host that answered.
class AgentPanelState {
  const AgentPanelState(this.outcomes);

  /// No host has `HERDR` on. §39.20: the panel is blocked, one dim line, no
  /// rows and no footer, and nothing opens a connection. The empty set *is* the
  /// blocked state — there is no separate flag to keep in step with it.
  const AgentPanelState.noHost() : outcomes = const [];

  final List<HostOutcome> outcomes;

  static const blockedLine = 'NO HOST · SET IN SYS';

  bool get noHost => outcomes.isEmpty;

  /// Merged across hosts. Two hosts running the same agent name are two agents:
  /// they are different machines, and collapsing them would hide work.
  List<AgentSnapshot> get agents => [
    for (final outcome in outcomes) ...outcome.agents,
  ];

  List<HostOutcome> get failures =>
      outcomes.where((outcome) => !outcome.ok).toList();

  /// The most recent good snapshot across every host, which is the timestamp
  /// §39.20 puts on the right of a failure line.
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

/// The hosts §39.20 polls. Replaces the selected-host provider: there is no
/// selection any more, only the set of machines with the integration on.
final herdrHostsProvider = StreamProvider<List<Host>>(
  (ref) => ref
      .watch(hostRepositoryProvider)
      .watchWithIntegration(IntegrationKind.herdr),
);

/// What the host form renders its §16c.3 switches from.
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

/// §39.21: nothing outside this typedef's implementation names a transport.
/// Today it is ssh; a backend proxying herdr replaces [HerdrClient] and no host,
/// integration row or provider above changes.
typedef HerdrFetch = Future<List<AgentSnapshot>> Function({
  required String address,
  required int port,
  required String user,
  required String privateKey,
});

final herdrFetchProvider = Provider<HerdrFetch>((ref) {
  const client = HerdrClient();
  return client.fetch;
});

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

final agentsFeedProvider = StreamProvider<AgentPanelState>((ref) {
  final visible = ref.watch(homeAgentsVisibleProvider);
  final foreground = ref.watch(appForegroundProvider);
  // §39.20: never in the background, and never while Home is off screen. The
  // guard is here rather than in the poll loop so a hidden panel holds no ssh
  // connection open at all.
  if (!visible || !foreground) return const Stream.empty();
  final hosts = ref.watch(herdrHostsProvider);
  return hosts.when(
    data: (list) => list.isEmpty
        ? Stream.value(const AgentPanelState.noHost())
        : _pollHosts(ref, list),
    loading: () => const Stream.empty(),
    error: (_, _) => const Stream.empty(),
  );
});

/// One tick polls every host at once and emits a single state. Sequential polls
/// would make the panel's refresh interval the sum of the hosts' timeouts — two
/// unreachable hosts alone would push it past §39.20's 10s cadence.
Stream<AgentPanelState> _pollHosts(Ref ref, List<Host> hosts) async* {
  final fetch = ref.read(herdrFetchProvider);
  final keys = ref.read(ed25519KeysProvider);
  final cache = ref.read(_agentSnapshotCacheProvider);
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

  // §39.29: every failure leaves a line in the debug log naming the host and
  // what the transport said, so a report from a handset can be read without
  // guessing which of the four the dim line came from. debugPrint rather than
  // dart:developer: only the former reaches logcat on a handset.
  void log(Object error) => debugPrint('hotline.herdr ${host.name}: $error');

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
    };
  }
}
