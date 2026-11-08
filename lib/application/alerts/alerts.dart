import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import 'package:upgrade/application/agents/agents.dart';
import 'package:upgrade/application/providers.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/data/repositories/settings_repository.dart';
import 'package:upgrade/platform/herdr/herdr_client.dart';
import 'package:upgrade/platform/notifications/alert_target.dart';

export 'package:upgrade/platform/notifications/alert_target.dart';

extension AlertKindSettings on AlertKind {
  String get settingsKey => switch (this) {
    AlertKind.blocked => SettingsRepository.alertsBlockedAgents,
    AlertKind.done => SettingsRepository.alertsDoneAgents,
  };
}

AlertTarget alertTargetFor(
  Host host,
  AgentSnapshot snapshot, {
  String? channel,
}) => AlertTarget(
  hostId: host.id,
  address: host.address,
  port: host.port,
  user: host.user,
  keyId: host.keyId,
  session: snapshot.session,
  paneId: snapshot.paneId,
  agent: snapshot.agent,
  text: alertText(snapshot),
  channel: channel,
  edge: snapshot.edgeId,
  approvalId: snapshot.approval?.id,
  hostKey: host.hostKey,
);

class WatcherReport {
  const WatcherReport({
    required this.hostId,
    required this.kind,
    this.source = AgentSource.herdr,
    this.agents = const [],
    this.lastGoodAt,
    this.protocol,
    this.retryIn,
    this.requestId,
  });

  final String hostId;
  final AgentSource source;

  String get key => channelKey(hostId, source);
  final AgentOutcomeKind kind;
  final List<AgentSnapshot> agents;
  final DateTime? lastGoodAt;
  final int? protocol;

  final Duration? retryIn;
  final String? requestId;

  Map<String, Object?> toJson() => {
    'host_id': hostId,
    if (source != AgentSource.herdr) 'source': source.name,
    'kind': kind.name,
    'agents': [for (final agent in agents) agent.toJson()],
    'last_good_at': lastGoodAt?.millisecondsSinceEpoch,
    'protocol': protocol,
    'retry_ms': retryIn?.inMilliseconds,
    if (requestId != null) 'request_id': requestId,
  };

  static WatcherReport? fromJson(Map<String, Object?> json) {
    final kind = AgentOutcomeKind.values
        .where((value) => value.name == json['kind'])
        .firstOrNull;
    final hostId = json['host_id'];
    if (kind == null || hostId is! String) return null;
    final agents = json['agents'];
    final lastGood = json['last_good_at'];
    final retry = json['retry_ms'];
    return WatcherReport(
      hostId: hostId,
      source:
          AgentSource.values
              .where((value) => value.name == json['source'])
              .firstOrNull ??
          AgentSource.herdr,
      kind: kind,
      agents: [
        if (agents is List<Object?>)
          for (final agent in agents)
            if (agent is Map<String, Object?>) AgentSnapshot.fromJson(agent),
      ],
      lastGoodAt: lastGood is int
          ? DateTime.fromMillisecondsSinceEpoch(lastGood)
          : null,
      protocol: json['protocol'] is int ? json['protocol']! as int : null,
      retryIn: retry is int ? Duration(milliseconds: retry) : null,
      requestId: json['request_id'] is String
          ? json['request_id']! as String
          : null,
    );
  }

  HostOutcome toOutcome(Host host) => HostOutcome(
    host: host,
    kind: kind,
    source: source,
    agents: agents,
    lastGoodAt: lastGoodAt,
    protocol: protocol,
  );
}

String watcherNotificationText(
  List<HostOutcome> outcomes, {
  Map<String, Duration> retries = const {},
}) {
  final down = outcomes.where((outcome) => !outcome.ok).toList();
  if (down.isNotEmpty) {
    final first = down.first;
    final retry = retries[first.host.id];
    final line = first.reason.toUpperCase();
    return retry == null ? line : '$line · RETRY ${retry.inSeconds}S';
  }
  final tally = agentTally(outcomes);
  if (tally.isNotEmpty) return tally;
  final count = outcomes.length;
  return 'WATCHING $count HOST${count == 1 ? '' : 'S'}';
}

enum AlertsRow {
  noHost,

  denied,
  off,
  on;

  bool get interactive => this != AlertsRow.noHost;

  String? get subtitle => switch (this) {
    AlertsRow.noHost => 'NO HOST',
    AlertsRow.denied => 'NOTIFICATIONS DENIED',
    _ => null,
  };
}

final alertsEnabledProvider = StreamProvider.family<bool, AlertKind>(
  (ref, kind) => ref
      .watch(settingsRepositoryProvider)
      .watchFlag(kind.settingsKey, orElse: false),
);

/// Not persisted: the OS is the record, and a permission granted from system settings
/// must not meet a stale line.
final alertsDeniedProvider = StateProvider<Set<AlertKind>>((ref) => const {});

final alertsRowProvider = Provider.family<AlertsRow, AlertKind>((ref, kind) {
  final channels = ref.watch(agentChannelsProvider).value ?? const [];
  if (channels.isEmpty) return AlertsRow.noHost;
  if (ref.watch(alertsDeniedProvider).contains(kind)) return AlertsRow.denied;
  return (ref.watch(alertsEnabledProvider(kind)).value ?? false)
      ? AlertsRow.on
      : AlertsRow.off;
});

final alertsWantedProvider = Provider<Set<AlertKind>>((ref) {
  return {
    for (final kind in AlertKind.values)
      if (ref.watch(alertsRowProvider(kind)) == AlertsRow.on) kind,
  };
});

final watcherWantedProvider = Provider<bool>(
  (ref) => ref.watch(alertsWantedProvider).isNotEmpty,
);
