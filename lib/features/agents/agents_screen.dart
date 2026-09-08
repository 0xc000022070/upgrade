import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

import '../../app/static_surface.dart';
import '../../application/agents.dart';
import '../../design/components/list_row.dart';
import '../../design/components/panel.dart';
import '../../design/components/section.dart';
import '../../design/spacing.dart';
import '../../design/sprite.dart';
import '../../design/typography.dart';
import '../../platform/herdr_client.dart';
import '../home/agent_mark.dart';
import '../screen_scaffold.dart';
import 'agent_shell.dart';

void openAgents(BuildContext context) {
  Navigator.of(
    context,
    rootNavigator: true,
  ).push(MaterialPageRoute<void>(builder: (_) => const AgentsScreen()));
}

class AgentsScreen extends ConsumerWidget {
  const AgentsScreen({super.key, this.onOpen});

  /// A row's tap. Null takes it to the agent's pane in the shell sheet.
  final AgentOpen? onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(agentsFeedProvider);
    return Scaffold(
      body: StaticSurface(
        child: ScreenScaffold(
          title: 'AGENTS',
          breadcrumb: '/ SPECTACLE / AGENTS',
          onBack: () => Navigator.of(context).pop(),
          children: [
            // Same reload blink as the panel: `waiting for host` would
            // replace the workspaces on every report the watcher pushes.
            state.when(
              skipLoadingOnReload: true,
              loading: () => const Panel(
                title: 'WORKSPACES',
                child: EmptyState('waiting for host'),
              ),
              error: (error, _) =>
                  Panel(title: 'WORKSPACES', child: Text('error: $error')),
              data: (feed) => _Feed(
                feed,
                onOpen:
                    onOpen ??
                    (host, agent) => openAgentShell(context, ref, host, agent),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// VIEW ALL is the panel at full height, so it mirrors the panel's states
/// exactly: the blocked line, one line per failing host, workspaces for
/// the hosts that answered.
class _Feed extends StatelessWidget {
  const _Feed(this.feed, {required this.onOpen});

  final AgentPanelState feed;
  final AgentOpen onOpen;

  /// Nothing to read on this route: no host set, or every host answered and
  /// none of them is running an agent. A host that failed is not empty — its
  /// line is the only place that failure is said — so those keep the stack.
  bool get _empty =>
      feed.noHost ||
      feed.outcomes.every((outcome) => outcome.ok && outcome.agents.isEmpty);

  @override
  Widget build(BuildContext context) {
    if (_empty) {
      return Column(
        children: [
          const _MascotEmpty(),
          const SizedBox(height: Spacing.xl),
          Panel(
            title: 'AGENTS',
            child: feed.noHost
                ? const Text(
                    AgentPanelState.blockedLine,
                    style: SpectacleText.value,
                  )
                : const EmptyState('no agents'),
          ),
        ],
      );
    }
    // Group by host then workspace, and collapse the host level when
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
                  // The same box the Home row draws, in the 14px glyph
                  // slot widened to the 24 the box needs.
                  leading: AgentMark(agent.agent),
                  leadingWidth: 24,
                  title: agentMarkName(agent.agent),
                  subtitle: '${agent.paneId} · ${path.basename(agent.cwd)}',
                  value: agent.state.label,
                  valueColor: agentStateColor(agent.state),
                  onTap: () => onOpen(outcome.host, agent),
                ),
            ],
          ),
        ),
    ];
  }
}

/// The mascot on an empty AGENTS route. The idle sheet runs here rather than
/// holding a frame the way the project detail's does: an empty route has
/// nothing else for the eye, which is where a loop belongs.
class _MascotEmpty extends StatelessWidget {
  const _MascotEmpty();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: Spacing.xl),
      child: Column(
        children: [
          Sprite(state: 'idle', scale: 4),
          SizedBox(height: Spacing.lg),
          Text('SPECTACLE_', style: SpectacleText.screenTitle),
        ],
      ),
    );
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
          Expanded(child: Text(outcome.reason, style: SpectacleText.value)),
          if (timestamp != null)
            Text(
              agentSnapshotAge(DateTime.now(), timestamp),
              style: SpectacleText.value,
            ),
        ],
      ),
    );
  }
}
