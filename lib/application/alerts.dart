import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/repositories/host_repository.dart';
import '../data/repositories/settings_repository.dart';
import '../platform/herdr_client.dart';
import 'agent_kind.dart';
import 'agents.dart';
import 'providers.dart';

/// Everything about a blocked-agent alert that is a decision
/// rather than a platform call, kept away from the notification plugin and the
/// foreground service so the regression list can be run on the vm.

/// The persistent watcher notification. Fixed, because there is one service.
const watcherNotificationId = 1;

/// One notification per pane, "id derived from host and pane so a repeat
/// updates in place". The id has to survive a process death — the watcher's
/// isolate is not the isolate that answers a tap — so it is derived rather than
/// handed out from a counter. Offset past [watcherNotificationId] and folded to
/// 30 bits, which keeps it inside the signed 32-bit id Android takes.
int alertNotificationId(String hostId, String paneId) {
  var hash = 0;
  for (final unit in '$hostId/$paneId'.codeUnits) {
    hash = (hash * 31 + unit) & 0x3fffffff;
  }
  return 1000 + hash;
}

/// What a pane running nothing the app knows is answered with. The keys as the
/// spec writes them are not yet checked against a live blocked pane: the
/// emulator's key is not on nyx, so nothing here has answered a real prompt.
const _defaultAnswerKeys = (yes: 'enter', no: 'esc');

/// The key sent to the remote agent. Kept as a list because a later kind may
/// need two. herdr names whatever the pane is running, so a name that is no
/// agent of ours is answered the way most TUIs are.
List<String> answerKeys(String agent, {required bool yes}) {
  final table = AgentKind.lookup(agent)?.answerKeys ?? _defaultAnswerKeys;
  return [yes ? table.yes : table.no];
}

/// An empty `agent` reads as `?` everywhere; the title is the
/// same name uppercased.
String alertTitle(AgentSnapshot snapshot) => blockedTitle(snapshot.agent);

/// The same title built from the agent name alone, which is all the isolate
/// that answers an action tap is given.
String blockedTitle(String agent) {
  final name = agent.trim();
  return '${name.isEmpty ? '?' : name.toUpperCase()} BLOCKED';
}

String alertText(AgentSnapshot snapshot) => snapshot.terminalTitleStripped;

/// The action states, after a tap and while the watcher has not yet seen
/// the pane leave `blocked`.
String alertSentLine({required bool yes}) => 'SENT · ${yes ? 'YES' : 'NO'}';

String alertFailedLine(String reason) => 'FAILED · $reason';

/// The failure vocabulary without the host name: an alert names one host
/// already, so repeating it in the line would only cost width.
String alertFailureReason(HerdrFailure failure) => switch (failure) {
  HerdrKeyRejected() => 'KEY REJECTED',
  HerdrProtocolMismatch(:final protocol) => 'PROTOCOL ${protocol ?? '?'}',
  HerdrUnresolved() => 'UNRESOLVED',
  HerdrUnreachable() => 'UNREACHABLE',
  HerdrHostKeyUnverified() => 'HOST KEY UNVERIFIED',
  HerdrHostKeyChanged() => 'HOST KEY CHANGED',
};

/// The actions come back if 10 s pass with no change.
const alertActionRestore = Duration(seconds: 10);

/// Keepalive every 15 s, reconnect after 5 s doubling to 60 s. Kept
/// with the decisions rather than with the watcher: the schedule is one, and
/// the keepalive is the number the isolate answering a tap has to dial with
/// too.
const watcherKeepAlive = Duration(seconds: 15);
const watcherMinBackoff = Duration(seconds: 5);
const watcherMaxBackoff = Duration(seconds: 60);

/// One host's reconnect delay. It doubles per outage and not per
/// lifetime, so [reset] runs whenever a connection carries a snapshot: a link
/// that held for hours and then dropped retries after 5 s, not after the 60 s
/// some earlier outage climbed to.
class WatcherBackoff {
  Duration _current = watcherMinBackoff;

  Duration get current => _current;

  void advance() {
    final doubled = _current * 2;
    _current = doubled > watcherMaxBackoff ? watcherMaxBackoff : doubled;
  }

  void reset() => _current = watcherMinBackoff;
}

/// The blocked panes one host is currently showing, and the edges into and out
/// of that set.
///
/// One notification per blocked *episode*: a pane that is still
/// blocked on the next snapshot is not a new alert, and a pane that unblocks and
/// blocks again is. That is a set difference, kept per host because two hosts
/// can hand out the same pane id.
class BlockedEdges {
  final Map<String, Set<String>> _blocked = {};

  /// "the first snapshot after a connect counts every blocked pane as
  /// new". Called on every connect, so the set the difference is taken against
  /// is empty and every blocked pane comes out of [apply] as an edge.
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
    // A pane that disappeared from the list left `blocked` as far as this app
    // can tell, and the notification is cleared either way.
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

/// Everything an action tap needs, carried on the notification itself.
///
/// "Actions work with only the service alive, the activity gone." The
/// tap is answered in a background isolate that has no database and no
/// providers, so the host it must dial travels with the notification rather
/// than being looked up. The private key does not: it stays in the keystore and
/// is read back by [keyId], which is the one part of this that is a secret.
class AlertTarget {
  const AlertTarget({
    required this.hostId,
    required this.address,
    required this.port,
    required this.user,
    required this.keyId,
    required this.paneId,
    required this.agent,
    required this.text,
  });

  final String hostId;
  final String address;
  final int port;
  final String user;
  final String keyId;
  final String paneId;
  final String agent;

  /// The notification's own text, carried so the isolate answering a tap can
  /// redraw the notification with the state line under it. It cannot read
  /// the line back off the posted notification: only the process that is still
  /// holding the snapshot knows it, and by then that process may be gone.
  final String text;

  factory AlertTarget.forHost(Host host, AgentSnapshot snapshot) => AlertTarget(
    hostId: host.id,
    address: host.address,
    port: host.port,
    user: host.user,
    keyId: host.keyId,
    paneId: snapshot.paneId,
    agent: snapshot.agent,
    text: alertText(snapshot),
  );

  String get title => blockedTitle(agent);

  int get notificationId => alertNotificationId(hostId, paneId);

  String encode() => jsonEncode({
    'host_id': hostId,
    'address': address,
    'port': port,
    'user': user,
    'key_id': keyId,
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
        paneId: json['pane_id']! as String,
        agent: json['agent']! as String,
        text: json['text']! as String,
      );
    } catch (_) {
      return null;
    }
  }
}

/// What one host's watcher connection is doing, as the service isolate reports
/// it to the UI.
///
/// Home reads the watcher's snapshots instead of its own poll, and draws the
/// same reason lines, so the report carries the outcome and not just
/// the agents.
class WatcherReport {
  const WatcherReport({
    required this.hostId,
    required this.kind,
    this.agents = const [],
    this.lastGoodAt,
    this.protocol,
    this.retryIn,
  });

  final String hostId;
  final AgentOutcomeKind kind;
  final List<AgentSnapshot> agents;
  final DateTime? lastGoodAt;
  final int? protocol;

  /// The persistent line, `nyx unreachable · retry 30s`: the backoff the
  /// watcher is currently sitting out.
  final Duration? retryIn;

  Map<String, Object?> toJson() => {
    'host_id': hostId,
    'kind': kind.name,
    'agents': [for (final agent in agents) agent.toJson()],
    'last_good_at': lastGoodAt?.millisecondsSinceEpoch,
    'protocol': protocol,
    'retry_ms': retryIn?.inMilliseconds,
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

/// The persistent notification body: `WATCHING N HOSTS` while every host
/// answers, and the first failing host's reason line with its backoff
/// when one does not.
String watcherNotificationText(
  List<HostOutcome> outcomes, {
  Map<String, Duration> retries = const {},
}) {
  final down = outcomes.where((outcome) => !outcome.ok).toList();
  if (down.isEmpty) {
    final count = outcomes.length;
    return 'WATCHING $count HOST${count == 1 ? '' : 'S'}';
  }
  final first = down.first;
  final retry = retries[first.host.id];
  final line = first.reason.toUpperCase();
  return retry == null ? line : '$line · RETRY ${retry.inSeconds}S';
}

/// The `[ ALERTS ]` row, as one value rather than three booleans
/// the row would have to combine at paint time.
enum AlertsRow {
  /// No host has `HERDR` on: dim, `NO HOST`, and the toggle does nothing.
  noHost,

  /// The OS refused notifications, so the toggle went back off.
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

/// "The setting persists across launches." The settings table
/// already stores flags, so this is a row and not a schema change.
final alertsEnabledProvider = StreamProvider<bool>(
  (ref) => ref
      .watch(settingsRepositoryProvider)
      .watchFlag(SettingsRepository.alertsBlockedAgents, orElse: false),
);

/// Set when a permission request comes back refused, cleared when the row is
/// next touched. Not persisted: the OS is the record, and a user who granted
/// the permission from the system settings should not meet a stale line.
final alertsDeniedProvider = StateProvider<bool>((ref) => false);

final alertsRowProvider = Provider<AlertsRow>((ref) {
  final hosts = ref.watch(herdrHostsProvider).valueOrNull ?? const [];
  if (hosts.isEmpty) return AlertsRow.noHost;
  if (ref.watch(alertsDeniedProvider)) return AlertsRow.denied;
  return (ref.watch(alertsEnabledProvider).valueOrNull ?? false)
      ? AlertsRow.on
      : AlertsRow.off;
});

/// The watcher runs when `ALERTS` is on **and** some host has `HERDR`
/// on, and stops the moment either stops being true. One expression, so the two
/// halves cannot drift.
final watcherWantedProvider = Provider<bool>(
  (ref) => ref.watch(alertsRowProvider) == AlertsRow.on,
);
