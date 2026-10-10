import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/enums.dart';
import '../data/repositories/host_repository.dart';
import '../data/repositories/key_repository.dart';
import '../platform/engine_agents.dart';
import '../platform/herdr_client.dart';
import '../platform/herdr_pool.dart';
import '../platform/host_links.dart';
import '../platform/host_key_dial.dart';
import '../platform/host_keys.dart';
import 'agent_state.dart';
import 'reason_lines.dart';
import 'watcher_backoff.dart';
import '../platform/keys.dart';

enum AgentOutcomeKind {
  snapshot,
  unreachable,
  unresolved,
  keyRejected,
  protocolMismatch,
  noEngine,
  noHerdr,

  hostKeyUnverified,

  hostKeyChanged,

  busy;

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
    this.source = AgentSource.herdr,
  });

  final Host host;
  final AgentOutcomeKind kind;
  final AgentSource source;

  String get key => channelKey(host.id, source);

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
    AgentOutcomeKind.noEngine => ReasonLine.noEngine,
    AgentOutcomeKind.noHerdr => ReasonLine.noHerdr,
    AgentOutcomeKind.hostKeyUnverified => ReasonLine.hostKeyUnverified,
    AgentOutcomeKind.hostKeyChanged => ReasonLine.hostKeyChanged,
    AgentOutcomeKind.busy => ReasonLine.hostBusy,
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

  String get _word => source == AgentSource.herdr ? 'HERDR' : 'AGENTS';

  String get diagnostic => switch (kind) {
    AgentOutcomeKind.snapshot => 'agent integration available',
    AgentOutcomeKind.unreachable => '$_word check could not reach host',
    AgentOutcomeKind.unresolved => '$_word host name did not resolve',
    AgentOutcomeKind.keyRejected => 'check SSH key in MACHINES',
    AgentOutcomeKind.protocolMismatch => '$_word protocol is not supported',
    AgentOutcomeKind.noEngine => 'install upgraded on the host',
    AgentOutcomeKind.noHerdr => 'install herdr on the host',
    AgentOutcomeKind.hostKeyUnverified => 'verify host key in MACHINES',
    AgentOutcomeKind.hostKeyChanged => 'host key changed; verify in MACHINES',
    AgentOutcomeKind.busy => ReasonLine.hostBusy.on(host.name),
  };
}

typedef AgentChannel = ({Host host, AgentSource source});

String channelKey(String hostId, AgentSource source) =>
    source == AgentSource.herdr ? hostId : '$hostId/${source.name}';

List<HostOutcome> linkAgents(List<HostOutcome> outcomes) {
  final claimed = <String, Set<String>>{};
  final panes = <String, Map<String, PaneRef>>{};
  for (final outcome in outcomes) {
    if (outcome.source != AgentSource.herdr) continue;
    final byPane = panes.putIfAbsent(outcome.host.id, () => {});
    for (final agent in outcome.agents) {
      byPane[agent.paneId] = agent.pane;
    }
  }
  for (final outcome in outcomes) {
    if (outcome.source != AgentSource.engine) continue;
    for (final agent in outcome.agents) {
      final pane = agent.herdrPane;
      if (pane != null && panes[outcome.host.id]?[pane] != null) {
        claimed.putIfAbsent(outcome.host.id, () => {}).add(pane);
      }
    }
  }
  if (claimed.isEmpty) return outcomes;
  return [
    for (final outcome in outcomes)
      HostOutcome(
        host: outcome.host,
        kind: outcome.kind,
        source: outcome.source,
        lastGoodAt: outcome.lastGoodAt,
        protocol: outcome.protocol,
        agents: switch (outcome.source) {
          AgentSource.herdr => [
            for (final agent in outcome.agents)
              if (!(claimed[outcome.host.id]?.contains(agent.paneId) ?? false))
                agent,
          ],
          AgentSource.engine => [
            for (final agent in outcome.agents)
              agent.linkedTo(panes[outcome.host.id]?[agent.herdrPane]),
          ],
        },
      ),
  ];
}

class AgentPanelState {
  const AgentPanelState(this.outcomes);

  AgentPanelState.linked(List<HostOutcome> outcomes)
    : outcomes = linkAgents(outcomes);

  const AgentPanelState.noHost() : outcomes = const [];

  final List<HostOutcome> outcomes;

  static const blockedLine = 'TURN AGENTS ON IN A HOST';

  String get tally => agentTally(outcomes);

  bool get noHost => outcomes.isEmpty;

  List<AgentSnapshot> get agents => [
    for (final outcome in outcomes) ...outcome.agents,
  ];

  /// One per host and line: herdr and the engine are two channels to one machine, and a
  /// machine that is down fails both in the same words.
  List<HostOutcome> get failures {
    final byLine = <(String, String), HostOutcome>{};
    for (final outcome in outcomes) {
      if (outcome.ok) continue;
      final key = (outcome.host.id, outcome.namedReason);
      final kept = byLine[key];
      final at = outcome.lastGoodAt;
      if (kept == null ||
          (at != null && (kept.lastGoodAt?.isBefore(at) ?? true))) {
        byLine[key] = outcome;
      }
    }
    return byLine.values.toList();
  }

  bool get answered => outcomes.any((outcome) => outcome.ok);

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
  (ref) => CachingPrivateKeyStore(const SecurePrivateKeyStore()),
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

final engineHostsProvider = StreamProvider<List<Host>>(
  (ref) => ref
      .watch(hostRepositoryProvider)
      .watchWithIntegration(IntegrationKind.agents),
);

final deviceHostsProvider = StreamProvider<List<Host>>(
  (ref) => ref
      .watch(hostRepositoryProvider)
      .watchWithIntegration(IntegrationKind.devices),
);

final vncHostsProvider = StreamProvider<List<Host>>(
  (ref) => ref
      .watch(hostRepositoryProvider)
      .watchWithIntegration(IntegrationKind.vnc),
);

class ScreenHost {
  const ScreenHost(this.host, {required this.desktop, required this.devices});

  final Host host;
  final bool desktop;
  final bool devices;
}

final screenHostsProvider = Provider<List<ScreenHost>?>((ref) {
  final desktops = ref.watch(vncHostsProvider).valueOrNull;
  final devices = ref.watch(deviceHostsProvider).valueOrNull;
  if (desktops == null || devices == null) return null;
  final desktopIds = {for (final host in desktops) host.id};
  final deviceIds = {for (final host in devices) host.id};
  final hosts = {
    for (final host in [...desktops, ...devices]) host.id: host,
  }.values.toList()..sort((a, b) => a.name.compareTo(b.name));
  return [
    for (final host in hosts)
      ScreenHost(
        host,
        desktop: desktopIds.contains(host.id),
        devices: deviceIds.contains(host.id),
      ),
  ];
});

Stream<List<AgentChannel>> watchAgentChannels(HostRepository repository) {
  late final StreamController<List<AgentChannel>> controller;
  final subscriptions = <StreamSubscription<List<Host>>>[];
  List<Host>? herdr;
  List<Host>? engine;
  void emit() {
    if (herdr == null || engine == null) return;
    controller.add([
      for (final host in herdr!) (host: host, source: AgentSource.herdr),
      for (final host in engine!) (host: host, source: AgentSource.engine),
    ]);
  }

  controller = StreamController(
    onListen: () {
      subscriptions
        ..add(
          repository.watchWithIntegration(IntegrationKind.herdr).listen((
            hosts,
          ) {
            herdr = hosts;
            emit();
          }, onError: controller.addError),
        )
        ..add(
          repository.watchWithIntegration(IntegrationKind.agents).listen((
            hosts,
          ) {
            engine = hosts;
            emit();
          }, onError: controller.addError),
        );
    },
    onCancel: () {
      for (final subscription in subscriptions) {
        unawaited(subscription.cancel());
      }
    },
  );
  return controller.stream;
}

final agentChannelsProvider = StreamProvider<List<AgentChannel>>(
  (ref) => watchAgentChannels(ref.watch(hostRepositoryProvider)),
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

  Stream<bool> get readings async* {
    yield state;
    yield* stream;
  }

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
  required HostKeyVerifier verifier,
});

final hostLinksProvider = Provider<HostLinks>((ref) {
  final links = HostLinks();
  ref.onDispose(links.close);
  return links;
});

final herdrFetchProvider = Provider<HerdrFetch>((ref) {
  final pool = HerdrSessionPool(ref.read(hostLinksProvider));
  ref.onDispose(pool.close);
  return pool.fetch;
});

final engineFetchProvider = Provider<HerdrFetch>((ref) {
  final links = ref.read(hostLinksProvider);
  return ({
    required address,
    required port,
    required user,
    required privateKey,
    required verifier,
  }) async {
    final session = HerdrSession.borrowed(
      await links.lease(
        address: address,
        port: port,
        user: user,
        privateKey: privateKey,
        verifier: verifier,
        use: HostUse.engineFetch,
      ),
    );
    try {
      return (await EngineAgents(session, owner: user).watch()).agents;
    } finally {
      session.close();
    }
  };
});

typedef EngineOpen = Future<EngineAgents> Function(Host host);

final engineOpenProvider = Provider<EngineOpen>((ref) {
  final links = ref.read(hostLinksProvider);
  final keys = ref.read(ed25519KeysProvider);
  return (host) async {
    final privateKey = await keys.privateKey(host.keyId);
    if (privateKey == null) {
      throw HerdrKeyRejected('no private key stored for ${host.keyId}');
    }
    final session = HerdrSession.borrowed(
      await links.lease(
        address: host.address,
        port: host.port,
        user: host.user,
        privateKey: privateKey,
        verifier: HostKeyVerifier.pinnedOnly(host.hostKey),
        use: HostUse.engineOpen,
      ),
    );
    return EngineAgents(session, owner: host.user);
  };
});

final hostKeyDialProvider = Provider<HostKeyDial>((ref) => HostLinks.probe);

class _AgentSnapshotCache {
  final Map<String, _CachedSnapshot> _hosts = {};

  _CachedSnapshot forChannel(String key) =>
      _hosts.putIfAbsent(key, _CachedSnapshot.new);
}

class _CachedSnapshot {
  List<AgentSnapshot> agents = const [];
  DateTime? receivedAt;
}

final _agentSnapshotCacheProvider = Provider((ref) => _AgentSnapshotCache());

typedef AgentRetry = Future<HostOutcome> Function(
  Host host, {
  AgentSource source,
});

typedef _Fetches = ({HerdrFetch herdr, HerdrFetch engine});

_Fetches _fetches(Ref ref) => (
  herdr: ref.read(herdrFetchProvider),
  engine: ref.read(engineFetchProvider),
);

AgentRetry foregroundAgentRetry(Ref ref) {
  final fetches = _fetches(ref);
  final keys = ref.read(ed25519KeysProvider);
  final cache = ref.read(_agentSnapshotCacheProvider);
  return (host, {source = AgentSource.herdr}) =>
      _poll(fetches, keys, cache, (host: host, source: source));
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

/// Bumped on resume and network arrival to redial refused hosts. Visibility cannot stand in:
/// it flips back before any frame rebuilds the feed.
final agentsWakeProvider = StateProvider<int>((ref) => 0);

final agentsFeedProvider = StreamProvider<AgentPanelState>((ref) {
  final watched = ref.watch(watcherFeedProvider).valueOrNull;
  if (watched != null) return Stream.value(watched);
  if (!ref.watch(agentsFeedLiveProvider)) return const Stream.empty();
  ref.watch(agentsWakeProvider);
  final channels = ref.watch(agentChannelsProvider);
  // Read before the generator body, which does not run until something listens: by
  // then watcherFeedProvider has emitted and the ref is outdated.
  final fetches = _fetches(ref);
  final keys = ref.read(ed25519KeysProvider);
  final cache = ref.read(_agentSnapshotCacheProvider);
  return channels.when(
    data: (list) => list.isEmpty
        ? Stream.value(const AgentPanelState.noHost())
        : _pollHosts(fetches, keys, cache, list),
    loading: () => const Stream.empty(),
    error: (_, _) => const Stream.empty(),
  );
});

Stream<AgentPanelState> _pollHosts(
  _Fetches fetches,
  Ed25519Keys keys,
  _AgentSnapshotCache cache,
  List<AgentChannel> channels,
) {
  // One loop per host: an outcome lands as its host answers, and a host still dialling
  // keeps the outcome it last reported rather than holding the others back.
  final latest = <String, HostOutcome>{};
  var live = true;
  late final StreamController<AgentPanelState> panel;
  Future<void> loop(AgentChannel channel) async {
    final backoff = WatcherBackoff();
    try {
      while (live) {
        final outcome = await _poll(fetches, keys, cache, channel);
        if (!live) return;
        latest[outcome.key] = outcome;
        panel.add(
          AgentPanelState.linked([
            for (final channel in channels)
              ?latest[channelKey(channel.host.id, channel.source)],
          ]),
        );
        if (!outcome.kind.retryable) return;
        final unanswered = switch (outcome.kind) {
          AgentOutcomeKind.unreachable ||
          AgentOutcomeKind.unresolved ||
          AgentOutcomeKind.busy => true,
          _ => false,
        };
        if (unanswered) {
          backoff.advance();
          await Future<void>.delayed(backoff.current);
        } else {
          backoff.reset();
          await Future<void>.delayed(const Duration(seconds: 10));
        }
      }
    } catch (error, stack) {
      if (live) panel.addError(error, stack);
    }
  }

  panel = StreamController(
    onListen: () {
      for (final channel in channels) {
        unawaited(loop(channel));
      }
    },
    onCancel: () => live = false,
  );
  return panel.stream;
}

Future<HostOutcome> _poll(
  _Fetches fetches,
  Ed25519Keys keys,
  _AgentSnapshotCache caches,
  AgentChannel channel,
) async {
  final (:host, :source) = channel;
  final cache = caches.forChannel(channelKey(host.id, source));
  final fetch = switch (source) {
    AgentSource.herdr => fetches.herdr,
    AgentSource.engine => fetches.engine,
  };
  HostOutcome failure(AgentOutcomeKind kind, {int? protocol}) => HostOutcome(
    host: host,
    kind: kind,
    source: source,
    agents: cache.agents,
    lastGoodAt: cache.receivedAt,
    protocol: protocol,
  );

  // debugPrint rather than dart:developer: only the former reaches logcat.
  void log(Object error) => debugPrint('upgrade.herdr ${host.name}: $error');

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
      source: source,
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
      HerdrBusy() => failure(AgentOutcomeKind.busy),
      EngineMissing() => failure(AgentOutcomeKind.noEngine),
      HerdrMissing() => failure(AgentOutcomeKind.noHerdr),
      HerdrHostKeyUnverified() => failure(AgentOutcomeKind.hostKeyUnverified),
      HerdrHostKeyChanged() => failure(AgentOutcomeKind.hostKeyChanged),
    };
  } on EngineRefused catch (error) {
    log(error);
    return failure(AgentOutcomeKind.protocolMismatch);
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
