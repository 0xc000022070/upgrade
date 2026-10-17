import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:striked/application/agents/agents.dart';
import 'package:striked/application/providers.dart';
import 'package:striked/data/enums.dart';
import 'package:striked/data/repositories/dispatch_repository.dart';
import 'package:striked/platform/herdr/herdr_client.dart';

const endedState = 'ended';

String? paneStateOf(AgentPanelState feed, Dispatch send) {
  final session = send.herdrSession;
  final pane = send.paneId;
  if (session == null || pane == null) return null;
  final PaneRef ref = (session: session, pane: pane);
  HostOutcome? herdr;
  for (final outcome in feed.outcomes) {
    if (outcome.host.id != send.hostId || !outcome.ok) continue;
    for (final agent in outcome.agents) {
      if (agent.engine ? agent.link == ref : agent.pane == ref) {
        return agent.state.word;
      }
    }
    if (outcome.source == AgentSource.herdr) herdr = outcome;
  }
  if (herdr == null) return null;
  final at = herdr.lastGoodAt;
  final settled =
      send.states.isNotEmpty ||
      (at != null && at.isAfter(send.sentAt.add(spawnDeadline)));
  return settled ? endedState : null;
}

final sendStatesProvider = Provider<void>((ref) {
  void record(AgentPanelState? feed, List<Dispatch>? sends) {
    if (feed == null || sends == null) return;
    if (!ref.read(agentsFeedLiveProvider)) return;
    final dispatches = ref.read(dispatchRepositoryProvider);
    for (final send in sends) {
      if (send.status != DispatchStatus.sent) continue;
      final last = send.lastSeen;
      if (last == endedState) continue;
      final state = paneStateOf(feed, send);
      if (state == null || state == last) continue;
      dispatches
          .seen(send.id, state)
          .catchError((Object error) => debugPrint('striked.sent: $error'));
    }
  }

  ref.listen(
    agentsFeedProvider,
    (_, next) => record(next.valueOrNull, ref.read(sendsProvider).valueOrNull),
  );
  ref.listen(
    sendsProvider,
    (_, next) =>
        record(ref.read(agentsFeedProvider).valueOrNull, next.valueOrNull),
  );
});
