import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

import '../../app/static_surface.dart';
import '../../application/agents.dart';
import '../../design/colors.dart';
import '../../design/components/list_row.dart';
import '../../design/components/panel.dart';
import '../../design/components/section.dart';
import '../../design/typography.dart';
import '../../platform/herdr_client.dart';
import '../home/agent_mark.dart';
import '../screen_scaffold.dart';

void openAgents(BuildContext context) {
  Navigator.of(
    context,
    rootNavigator: true,
  ).push(MaterialPageRoute<void>(builder: (_) => const AgentsScreen()));
}

class AgentsScreen extends ConsumerWidget {
  const AgentsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(agentsFeedProvider);
    return Scaffold(
      body: StaticSurface(
        child: ScreenScaffold(
          title: 'AGENTS',
          breadcrumb: '/ HOTLINE / AGENTS',
          onBack: () => Navigator.of(context).pop(),
          children: [
            state.when(
              loading: () => const Panel(
                title: 'WORKSPACES',
                child: EmptyState('waiting for host'),
              ),
              error: (error, _) =>
                  Panel(title: 'WORKSPACES', child: Text('error: $error')),
              data: (feed) => _Feed(feed),
            ),
          ],
        ),
      ),
    );
  }
}

/// VIEW ALL is the panel at full height, so it mirrors the panel's states
/// exactly: §39.20's blocked line, one line per failing host, workspaces for
/// the hosts that answered.
class _Feed extends StatelessWidget {
  const _Feed(this.feed);

  final AgentPanelState feed;

  @override
  Widget build(BuildContext context) {
    if (feed.noHost) {
      return const Panel(
        title: 'AGENTS',
        child: Text(AgentPanelState.blockedLine, style: HotlineText.value),
      );
    }
    // §39.20.6: group by host then workspace, and collapse the host level when
    // there is only one — naming the single host on every panel is noise, and
    // it is the shape every install has until a second machine is registered.
    final single = feed.outcomes.length == 1;
    return PanelStack(
      children: [
        for (final outcome in feed.outcomes)
          if (!outcome.ok)
            _FailureLine(outcome: outcome, named: !single)
          else
            ..._workspacePanels(outcome, named: !single),
      ],
    );
  }

  List<Widget> _workspacePanels(HostOutcome outcome, {required bool named}) {
    final groups = <String, List<AgentSnapshot>>{};
    for (final agent in outcome.agents) {
      groups.putIfAbsent(agent.workspaceId, () => []).add(agent);
    }
    final workspaces = groups.keys.toList()..sort();
    if (workspaces.isEmpty) {
      return [
        Panel(
          title: named ? outcome.host.name.toUpperCase() : 'WORKSPACES',
          child: const EmptyState('no agents'),
        ),
      ];
    }
    return [
      for (final workspace in workspaces)
        Panel(
          title: named
              ? '${outcome.host.name.toUpperCase()} / '
                    '${workspace.toUpperCase()}'
              : workspace.toUpperCase(),
          bodyPadding: panelRowsPadding,
          child: ListRowGroup(
            children: [
              for (final agent in groups[workspace]!)
                ListRow(
                  // §39.30: the same box the Home row draws, in the 14px glyph
                  // slot widened to the 24 the box needs.
                  leading: AgentMark(agent.agent),
                  leadingWidth: 24,
                  title: agentMarkName(agent.agent),
                  subtitle: '${agent.paneId} · ${path.basename(agent.cwd)}',
                  value: agent.agentStatus.toUpperCase(),
                  valueColor: switch (agent.agentStatus) {
                    'working' => HotlineColors.accent,
                    'blocked' => HotlineColors.warning,
                    _ => HotlineColors.textMuted,
                  },
                ),
            ],
          ),
        ),
    ];
  }
}

class _FailureLine extends StatelessWidget {
  const _FailureLine({required this.outcome, required this.named});

  final HostOutcome outcome;
  final bool named;

  @override
  Widget build(BuildContext context) {
    final timestamp = outcome.lastGoodAt;
    return Panel(
      title: named ? outcome.host.name.toUpperCase() : 'AGENTS',
      child: Row(
        children: [
          Expanded(child: Text(outcome.reason, style: HotlineText.value)),
          if (timestamp != null)
            Text(
              agentSnapshotAge(DateTime.now(), timestamp),
              style: HotlineText.value,
            ),
        ],
      ),
    );
  }
}
