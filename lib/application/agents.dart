import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/enums.dart';
import '../data/repositories/host_repository.dart';
import '../data/repositories/key_repository.dart';
import '../platform/herdr_client.dart';
import '../platform/herdr_pool.dart';
import '../platform/host_key_dial.dart';
import '../platform/host_keys.dart';
import 'agent_state.dart';
import 'reason_lines.dart';
import '../platform/keys.dart';

enum AgentOutcomeKind {
  snapshot,
  unreachable,
  unresolved,
  keyRejected,
  protocolMismatch,

  hostKeyUnverified,

  hostKeyChanged;

  /// sshd counts failed authentications per source and locks the client out for an hour;
  /// a refused credential is never knocked on again.
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

  final List<AgentSnapshot> agents;
  final DateTime? lastGoodAt;
  final int? protocol;

  bool get ok => kind == AgentOutcomeKind.snapshot;

  ReasonLine? get _line => switch (kind) {
    AgentOutcomeKind.snapshot => null,
    AgentOutcomeKind.unreachable => ReasonLine.unreachable,
    AgentOutcomeKind.unresolved => ReasonLine.unresolved,
    AgentOutcomeKind.keyRejected => ReasonLine.keyRejected,
    AgentOutcomeKind.protocolMismatch => ReasonLine.protocolMismatch,
    AgentOutcomeKind.hostKeyUnverified => ReasonLine.hostKeyUnverified,
    AgentOutcomeKind.hostKeyChanged => ReasonLine.hostKeyChanged,
  };

  String get reason {
    if (kind == AgentOutcomeKind.protocolMismatch) {
      return protocolLine(protocol);
    }
    return _line?.on(host.name) ?? '';
  }

  String get namedReason {
    final line = _line;
    if (line == null) return '';
    if (line.names) return line.on(host.name);
    return '${host.name.toLowerCase()} · $reason';
  }

  String get diagnostic => switch (kind) {
    AgentOutcomeKind.snapshot => 'agent integration available',
    AgentOutcomeKind.unreachable => 'HERDR check could not reach host',
    AgentOutcomeKind.unresolved => 'HERDR host name did not resolve',
    AgentOutcomeKind.keyRejected => 'check SSH key in HOSTS',
    AgentOutcomeKind.protocolMismatch => 'HERDR protocol is not supported',
    AgentOutcomeKind.hostKeyUnverified => 'verify host key in HOSTS',
    AgentOutcomeKind.hostKeyChanged => 'host key changed; verify in HOSTS',
  };
}

class AgentPanelState {
  const AgentPanelState(this.outcomes);

  const AgentPanelState.noHost() : outcomes = const [];

  final List<HostOutcome> outcomes;

  static const blockedLine = 'TURN HERDR ON IN A HOST';

  String get tally => agentTally(outcomes);

  bool get noHost => outcomes.isEmpty;

  List<AgentSnapshot> get agents => [
    for (final outcome in outcomes) ...outcome.agents,
  ];

  List<HostOutcome> get failures =>
      outcomes.where((outcome) => !outcome.ok).toList();

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

final herdrHostsProvider = StreamProvider<List<Host>>(
  (ref) => ref
      .watch(hostRepositoryProvider)
      .watchWithIntegration(IntegrationKind.herdr),
);

final hostIntegrationsProvider =
    StreamProvider.family<Set<IntegrationKind>, String>(
      (ref, hostId) =>
          ref.watch(hostRepositoryProvider).watchIntegrations(hostId),
    );

final homeAgentsVisibleProvider = StateProvider<bool>((ref) => false);

class AppLifecycleReading extends StateNotifier<bool>
    with WidgetsBindingObserver {
  AppLifecycleReading(this.reads)
    : super(reads(WidgetsBinding.instance.lifecycleState ?? _resumed)) {
    WidgetsBinding.instance.addObserver(this);
  }

  static const _resumed = AppLifecycleState.resumed;

  final bool Function(AppLifecycleState state) reads;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    this.state = reads(state);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

final appForegroundProvider = StateNotifierProvider<AppLifecycleReading, bool>(
  (ref) => AppLifecycleReading((state) => state == AppLifecycleState.resumed),
);

final appVisibleProvider = StateNotifierProvider<AppLifecycleReading, bool>(
  (ref) => AppLifecycleReading(
    (state) =>
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive,
  ),
);

typedef HerdrFetch = Future<List<AgentSnapshot>> Function({
  required String address,
  required int port,
  required String user,
  required String privateKey,
  HostKeyVerifier? verifier,
});

final herdrFetchProvider = Provider<HerdrFetch>((ref) {
  final pool = HerdrSessionPool(const HerdrClient());
  ref.onDispose(pool.close);
  return pool.fetch;
});

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

typedef AgentRetry = Future<HostOutcome> Function(Host host);

AgentRetry foregroundAgentRetry(Ref ref) {
  final fetch = ref.read(herdrFetchProvider);
  final keys = ref.read(ed25519KeysProvider);
  final cache = ref.read(_agentSnapshotCacheProvider);
  return (host) => _poll(fetch, keys, cache.forHost(host.id), host);
}

final agentRetryProvider = Provider<AgentRetry>(foregroundAgentRetry);

/// The default says nothing rather than emitting null: a first value would move
/// [agentsFeedProvider] off its first build and dial every host twice.
final watcherFeedProvider = StreamProvider<AgentPanelState?>(
  (ref) => const Stream.empty(),
);

/// The feed keeps its last value after the stream behind it is swapped for an empty
/// one, so every reader gates on this rather than on the value being non-null.
final agentsFeedLiveProvider = Provider<bool>((ref) {
  if (ref.watch(watcherFeedProvider).valueOrNull != null) return true;
  return ref.watch(homeAgentsVisibleProvider) && ref.watch(appVisibleProvider);
});

final agentsFeedProvider = StreamProvider<AgentPanelState>((ref) {
  final watched = ref.watch(watcherFeedProvider).valueOrNull;
  if (watched != null) return Stream.value(watched);
  if (!ref.watch(agentsFeedLiveProvider)) return const Stream.empty();
  final hosts = ref.watch(herdrHostsProvider);
  // Read before the generator body, which does not run until something listens: by
  // then watcherFeedProvider has emitted and the ref is outdated.
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

Stream<AgentPanelState> _pollHosts(
  HerdrFetch fetch,
  Ed25519Keys keys,
  _AgentSnapshotCache cache,
  List<Host> hosts,
) {
  // One loop per host: an outcome lands as its host answers, and a host still dialling
  // keeps the outcome it last reported rather than holding the others back.
  final latest = <String, HostOutcome>{};
  var live = true;
  late final StreamController<AgentPanelState> panel;
  Future<void> loop(Host host) async {
    try {
      while (live) {
        final outcome = await _poll(fetch, keys, cache.forHost(host.id), host);
        if (!live) return;
        latest[host.id] = outcome;
        panel.add(
          AgentPanelState([for (final host in hosts) ?latest[host.id]]),
        );
        await Future<void>.delayed(const Duration(seconds: 10));
      }
    } catch (error, stack) {
      if (live) panel.addError(error, stack);
    }
  }

  panel = StreamController(
    onListen: () {
      for (final host in hosts) {
        unawaited(loop(host));
      }
    },
    onCancel: () => live = false,
  );
  return panel.stream;
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

  // debugPrint rather than dart:developer: only the former reaches logcat.
  void log(Object error) => debugPrint('dazzle.herdr ${host.name}: $error');

  final privateKey = await keys.privateKey(host.keyId);
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

class AgentStates {
  const AgentStates({
    required this.blocked,
    required this.working,
    required this.done,
    required this.idle,
  });

  factory AgentStates.of(List<HostOutcome> outcomes) {
    var blocked = 0;
    var working = 0;
    var done = 0;
    var idle = 0;
    for (final outcome in outcomes) {
      if (!outcome.ok) continue;
      for (final agent in outcome.agents) {
        switch (agent.state) {
          case BlockedState():
            blocked++;
          case WorkingState():
            working++;
          case DoneState():
            done++;
          case IdleState():
            idle++;
          case UnknownState():
            break;
        }
      }
    }
    return AgentStates(
      blocked: blocked,
      working: working,
      done: done,
      idle: idle,
    );
  }

  final int blocked;
  final int working;
  final int done;
  final int idle;

  bool get news => blocked > 0 || working > 0 || done > 0;

  String get line => [
    if (blocked > 0) '$blocked BLOCKED',
    if (working > 0) '$working WORKING',
    if (done > 0) '$done DONE',
    if (idle > 0) '$idle IDLE',
  ].join(' · ');
}

String agentTally(List<HostOutcome> outcomes) {
  var blocked = 0;
  var working = 0;
  for (final outcome in outcomes) {
    if (!outcome.ok) continue;
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
