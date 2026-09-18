import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/repositories/host_repository.dart';
import '../data/repositories/settings_repository.dart';
import '../platform/herdr_client.dart';
import 'agent_kind.dart';
import 'agents.dart';
import 'providers.dart';

const watcherNotificationId = 1;

/// Derived rather than counted out, because the isolate answering a tap is not the
/// one that posted. Folded to 30 bits to stay inside Android's signed 32-bit id.
int alertNotificationId(String hostId, String paneId) {
  var hash = 0;
  for (final unit in '$hostId/$paneId'.codeUnits) {
    hash = (hash * 31 + unit) & 0x3fffffff;
  }
  return 1000 + hash;
}

const _defaultAnswerKeys = (yes: 'enter', no: 'esc');

List<String> answerKeys(String agent, {required bool yes}) {
  final table = AgentKind.lookup(agent)?.answerKeys ?? _defaultAnswerKeys;
  return [yes ? table.yes : table.no];
}

String alertTitle(AgentSnapshot snapshot) => blockedTitle(snapshot.agent);

String blockedTitle(String agent) {
  final name = agent.trim();
  return '${name.isEmpty ? '?' : name.toUpperCase()} BLOCKED';
}

String alertText(AgentSnapshot snapshot) => snapshot.terminalTitleStripped;

String alertSentLine({required bool yes}) => 'SENT · ${yes ? 'YES' : 'NO'}';

String alertFailedLine(String reason) => 'FAILED · $reason';

String alertFailureReason(HerdrFailure failure) => switch (failure) {
  HerdrKeyRejected() => 'KEY REJECTED',
  HerdrProtocolMismatch(:final protocol) => 'PROTOCOL ${protocol ?? '?'}',
  HerdrUnresolved() => 'UNRESOLVED',
  HerdrUnreachable() => 'UNREACHABLE',
  HerdrHostKeyUnverified() => 'HOST KEY UNVERIFIED',
  HerdrHostKeyChanged() => 'HOST KEY CHANGED',
};

const alertActionRestore = Duration(seconds: 10);

const watcherKeepAlive = Duration(seconds: 15);
const watcherMinBackoff = Duration(seconds: 5);
const watcherMaxBackoff = Duration(seconds: 60);

class WatcherBackoff {
  Duration _current = watcherMinBackoff;

  Duration get current => _current;

  void advance() {
    final doubled = _current * 2;
    _current = doubled > watcherMaxBackoff ? watcherMaxBackoff : doubled;
  }

  void reset() => _current = watcherMinBackoff;
}

class BlockedEdges {
  final Map<String, Set<String>> _blocked = {};

  /// Called on every connect, so the next difference counts every blocked pane as new.
  void reset(String hostId) => _blocked.remove(hostId);

  BlockedDelta apply(String hostId, List<AgentSnapshot> agents) {
    final was = _blocked[hostId] ?? const <String>{};
    final now = <String>{};
    final entered = <AgentSnapshot>[];
    for (final agent in agents) {
      if (!agent.blocked) continue;
      now.add(agent.paneId);
      if (!was.contains(agent.paneId)) entered.add(agent);
    }
    _blocked[hostId] = now;
    return BlockedDelta(
      entered: entered,
      left: [
        for (final pane in was)
          if (!now.contains(pane)) pane,
      ],
    );
  }

  Set<String> blockedOn(String hostId) => _blocked[hostId] ?? const {};
}

class BlockedDelta {
  const BlockedDelta({required this.entered, required this.left});

  final List<AgentSnapshot> entered;
  final List<String> left;

  bool get isEmpty => entered.isEmpty && left.isEmpty;
}

/// The tap is answered in a background isolate with no database and no providers, so
/// everything the dial needs travels on the notification. The private key does not.
class AlertTarget {
  const AlertTarget({
    required this.hostId,
    required this.address,
    required this.port,
    required this.user,
    required this.keyId,
    required this.session,
    required this.paneId,
    required this.agent,
    required this.text,
  });

  final String hostId;
  final String address;
  final int port;
  final String user;
  final String keyId;

  final String session;
  final String paneId;
  final String agent;

  final String text;

  factory AlertTarget.forHost(Host host, AgentSnapshot snapshot) => AlertTarget(
    hostId: host.id,
    address: host.address,
    port: host.port,
    user: host.user,
    keyId: host.keyId,
    session: snapshot.session,
    paneId: snapshot.paneId,
    agent: snapshot.agent,
    text: alertText(snapshot),
  );

  String get title => blockedTitle(agent);

  PaneRef get pane => (session: session, pane: paneId);

  int get notificationId => alertNotificationId(hostId, paneId);

  String encode() => jsonEncode({
    'host_id': hostId,
    'address': address,
    'port': port,
    'user': user,
    'key_id': keyId,
    'session': session,
    'pane_id': paneId,
    'agent': agent,
    'text': text,
  });

  static AlertTarget? decode(String? payload) {
    if (payload == null || payload.isEmpty) return null;
    try {
      final json = jsonDecode(payload);
      if (json is! Map<String, Object?>) return null;
      return AlertTarget(
        hostId: json['host_id']! as String,
        address: json['address']! as String,
        port: json['port']! as int,
        user: json['user']! as String,
        keyId: json['key_id']! as String,
        session: json['session']! as String,
        paneId: json['pane_id']! as String,
        agent: json['agent']! as String,
        text: json['text']! as String,
      );
    } catch (_) {
      return null;
    }
  }
}

class WatcherReport {
  const WatcherReport({
    required this.hostId,
    required this.kind,
    this.agents = const [],
    this.lastGoodAt,
    this.protocol,
    this.retryIn,
    this.requestId,
  });

  final String hostId;
  final AgentOutcomeKind kind;
  final List<AgentSnapshot> agents;
  final DateTime? lastGoodAt;
  final int? protocol;

  final Duration? retryIn;
  final String? requestId;

  Map<String, Object?> toJson() => {
    'host_id': hostId,
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

final alertsEnabledProvider = StreamProvider<bool>(
  (ref) => ref
      .watch(settingsRepositoryProvider)
      .watchFlag(SettingsRepository.alertsBlockedAgents, orElse: false),
);

/// Not persisted: the OS is the record, and a permission granted from system settings
/// must not meet a stale line.
final alertsDeniedProvider = StateProvider<bool>((ref) => false);

final alertsRowProvider = Provider<AlertsRow>((ref) {
  final hosts = ref.watch(herdrHostsProvider).valueOrNull ?? const [];
  if (hosts.isEmpty) return AlertsRow.noHost;
  if (ref.watch(alertsDeniedProvider)) return AlertsRow.denied;
  return (ref.watch(alertsEnabledProvider).valueOrNull ?? false)
      ? AlertsRow.on
      : AlertsRow.off;
});

final watcherWantedProvider = Provider<bool>(
  (ref) => ref.watch(alertsRowProvider) == AlertsRow.on,
);
