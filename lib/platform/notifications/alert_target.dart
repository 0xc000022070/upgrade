import 'dart:convert';

import 'package:upgrade/data/pinned_host_key.dart';
import 'package:upgrade/platform/herdr/agent_kind.dart';
import 'package:upgrade/platform/herdr/herdr_client.dart';

const watcherNotificationId = 1;

enum AlertKind {
  blocked,
  done;

  bool holds(AgentSnapshot agent) => switch (this) {
    AlertKind.blocked => agent.blocked,
    AlertKind.done => agent.done,
  };

  String get label => switch (this) {
    AlertKind.blocked => 'BLOCKED AGENTS',
    AlertKind.done => 'FINISHED AGENTS',
  };

  String title(String agent) {
    final name = agent.trim();
    final word = this == AlertKind.blocked ? 'BLOCKED' : 'DONE';
    return '${name.isEmpty ? '?' : name.toUpperCase()} $word';
  }
}

/// Derived rather than counted out, because the isolate answering a tap is not the
/// one that posted. Folded to 30 bits to stay inside Android's signed 32-bit id.
int alertNotificationId(String hostId, String paneId) {
  var hash = 0;
  for (final unit in '$hostId/$paneId'.codeUnits) {
    hash = (hash * 31 + unit) & 0x3fffffff;
  }
  return 1000 + hash;
}

/// The kind salts the fold rather than offsetting it, because an offset would carry the
/// id past the 30 bits. Blocked keeps the unsalted id it has always posted under.
int kindNotificationId(AlertKind kind, String hostId, String paneId) =>
    kind == AlertKind.blocked
    ? alertNotificationId(hostId, paneId)
    : alertNotificationId('${kind.name}/$hostId', paneId);

const _defaultAnswerKeys = (yes: 'enter', no: 'esc');

List<String> answerKeys(String agent, {required bool yes}) {
  final table = AgentKind.lookup(agent)?.answerKeys ?? _defaultAnswerKeys;
  return [yes ? table.yes : table.no];
}

String alertTitle(AgentSnapshot snapshot) =>
    AlertKind.blocked.title(snapshot.agent);

String alertText(AgentSnapshot snapshot) =>
    snapshot.approval?.line ??
    snapshot.question ??
    (snapshot.engine && snapshot.done ? snapshot.message : null) ??
    snapshot.terminalTitleStripped;

String alertSentLine({required bool yes, bool approval = false}) =>
    'SENT · ${approval ? (yes ? 'ALLOW' : 'DENY') : (yes ? 'YES' : 'NO')}';

String alertFailedLine(String reason) => 'FAILED · $reason';

String alertFailureReason(HostFailure failure) =>
    failure.line.shortReason(protocol: failure.protocol);

const alertActionRestore = Duration(seconds: 10);

class AgentEdges {
  AgentEdges(this.kind);

  final AlertKind kind;

  final Map<String, Set<String>> _panes = {};

  /// Called on every connect, so the next difference counts every pane in the state as new.
  void reset(String hostId) => _panes.remove(hostId);

  AgentDelta apply(String hostId, List<AgentSnapshot> agents) {
    final was = _panes[hostId] ?? const <String>{};
    final now = <String>{};
    final entered = <AgentSnapshot>[];
    final quiet = <String>{};
    for (final agent in agents) {
      if (!kind.holds(agent)) continue;
      now.add(agent.edgeId);
      if (was.contains(agent.edgeId)) continue;
      entered.add(agent);
      // An approval that ran out leaves the same pane asking the same thing in its
      // terminal, so the replacement is posted without sound.
      if (agent.approval == null &&
          was.any(
            (edge) =>
                edge != agent.paneId &&
                AgentSnapshot.paneOfEdge(edge) == agent.paneId,
          )) {
        quiet.add(agent.edgeId);
      }
    }
    _panes[hostId] = now;
    return AgentDelta(
      entered: entered,
      quiet: quiet,
      left: [
        for (final pane in was)
          if (!now.contains(pane)) pane,
      ],
    );
  }

  Set<String> panesOn(String hostId) => _panes[hostId] ?? const {};
}

class AgentDelta {
  const AgentDelta({
    required this.entered,
    required this.left,
    this.quiet = const {},
  });

  final List<AgentSnapshot> entered;
  final List<String> left;

  final Set<String> quiet;

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
    String? channel,
    String? edge,
    this.approvalId,
    this.hostKey,
  }) : channel = channel ?? hostId,
       edge = edge ?? paneId;

  final String hostId;
  final String address;
  final int port;
  final String user;
  final String keyId;

  final String session;
  final String paneId;
  final String agent;

  final String text;

  final String channel;
  final String edge;

  final String? approvalId;

  final PinnedHostKey? hostKey;

  bool get engine => channel != hostId;

  String get title => AlertKind.blocked.title(agent);

  PaneRef get pane => (session: session, pane: paneId);

  int notificationIdFor(AlertKind kind) =>
      kindNotificationId(kind, channel, edge);

  int get notificationId => notificationIdFor(AlertKind.blocked);

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
    if (channel != hostId) 'channel': channel,
    if (edge != paneId) 'edge': edge,
    'approval_id': ?approvalId,
    if (hostKey case final key?)
      'host_key': {
        'type': key.type,
        'fingerprint': key.fingerprint,
        'pinned_at': key.pinnedAt.toIso8601String(),
      },
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
        channel: json['channel'] as String?,
        edge: json['edge'] as String?,
        approvalId: json['approval_id'] as String?,
        hostKey: switch (json['host_key']) {
          {
            'type': final String type,
            'fingerprint': final String fingerprint,
            'pinned_at': final String at,
          } =>
            PinnedHostKey(
              type: type,
              fingerprint: fingerprint,
              pinnedAt: DateTime.parse(at),
            ),
          _ => null,
        },
      );
    } catch (_) {
      return null;
    }
  }
}
