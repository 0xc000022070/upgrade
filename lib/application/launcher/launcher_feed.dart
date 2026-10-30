import 'package:upgrade/application/agents/agents.dart';
import 'package:upgrade/platform/herdr/herdr_client.dart';
import 'package:upgrade/platform/launcher_widget/launcher_widget.dart';

LauncherTally? launcherTally(List<HostOutcome> outcomes) {
  if (outcomes.any((outcome) => !outcome.ok)) return null;
  var blocked = 0;
  var working = 0;
  for (final outcome in linkAgents(outcomes)) {
    for (final agent in outcome.agents) {
      if (agent.state.blocked) {
        blocked++;
      } else if (agent.state.active) {
        working++;
      }
    }
  }
  if (blocked == 0 && working == 0) return null;
  return (blocked: blocked, working: working);
}

Map<String, LauncherLive> launcherLive(
  List<OpenSend> sends,
  List<HostOutcome> outcomes,
  Map<String, LauncherLive> previous,
) {
  final live = <String, LauncherLive>{};
  for (final send in sends) {
    final mine = [
      for (final outcome in outcomes)
        if (outcome.host.id == send.host) outcome,
    ];
    if (mine.isEmpty) continue;
    if (mine.any((outcome) => !outcome.ok)) {
      if (previous[send.id] case final kept?) {
        live[send.id] = (state: kept.state, line: kept.line, dim: true);
      }
      continue;
    }
    final herdr = _agentOn(mine, AgentSource.herdr, send);
    final engine = _agentOn(mine, AgentSource.engine, send);
    final agent = engine ?? herdr;
    if (agent == null) {
      if (mine.any((outcome) => outcome.source == AgentSource.herdr)) {
        live[send.id] = (state: 'ENDED', line: null, dim: false);
      }
      continue;
    }
    final title = herdr?.terminalTitleStripped ?? agent.terminalTitleStripped;
    final line = agent.state.blocked
        ? engine?.approval?.line ??
              engine?.question ??
              agent.approval?.line ??
              agent.question
        : engine?.message;
    live[send.id] = (
      state: agent.state.label,
      line: _filled(line) ?? _filled(title),
      dim: false,
    );
  }
  return live;
}

AgentSnapshot? _agentOn(
  List<HostOutcome> outcomes,
  AgentSource source,
  OpenSend send,
) {
  for (final outcome in outcomes) {
    if (outcome.source != source) continue;
    for (final agent in outcome.agents) {
      final pane = source == AgentSource.herdr ? agent.paneId : agent.herdrPane;
      if (pane != send.pane) continue;
      if (source == AgentSource.herdr &&
          send.session != null &&
          agent.session != send.session) {
        continue;
      }
      return agent;
    }
  }
  return null;
}

String? _filled(String? line) {
  final trimmed = line?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}
