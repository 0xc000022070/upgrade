import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/agents.dart';
import '../../application/navigation.dart';
import '../../application/pip.dart';
import '../../design/tokens.dart';
import '../../design/components/dot_spinner.dart';
import '../../design/components/panel.dart';
import '../../design/spacing.dart';
import '../../platform/herdr_client.dart';
import '../agents/agent_shell.dart';
import '../agents/agents_screen.dart';
import '../agents/pip_action.dart';
import '../hosts/hosts_screen.dart';
import 'agent_mark.dart';

class AgentsPanel extends ConsumerWidget {
  const AgentsPanel({
    super.key,
    this.state,
    this.onViewAll,
    this.onOpen,
    this.now,
  });

  final AgentPanelState? state;
  final VoidCallback? onViewAll;

  final AgentOpen? onOpen;
  final DateTime? now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final supplied = state;
    final value = supplied == null
        ? ref.watch(agentsFeedProvider)
        : AsyncValue<AgentPanelState>.data(supplied);
    final current = value.valueOrNull;
    final agents = !(current?.noHost ?? false);
    final header = <Widget>[
      if (agents)
        PanelAffordance('${current?.agents.length ?? 0}', showIcon: false),
      if (ref.watch(pipActionProvider) != PipAction.absent)
        const PipAffordance(),
      if (agents)
        PanelAffordance(
          'VIEW ALL',
          onTap: onViewAll ?? () => openAgents(context),
        ),
    ];
    return Panel(
      title: 'AGENTS',
      affordance: header.isEmpty
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < header.length; i++) ...[
                  if (i > 0) const SizedBox(width: Spacing.lg),
                  header[i],
                ],
              ],
            ),
      bodyPadding: const EdgeInsets.symmetric(
        horizontal: Spacing.panelPadding,
        vertical: Spacing.md,
      ),
      // The feed is rebuilt on every watcher report, and a rebuilt StreamProvider passes
      // through loading before its first event lands: without this the body collapses to the
      // spinner's 12px for a frame on every poll.
      child: value.when(
        skipLoadingOnReload: true,
        loading: () => const DelayedSpinner(),
        error: (error, _) => _DimLine('error: $error'),
        data: (data) => _AgentsBody(
          data: data,
          now: now ?? DateTime.now(),
          onConfigureHosts: () =>
              ref.read(navIndexProvider.notifier).state = HostsScreen.navIndex,
          onOpen:
              onOpen ??
              (host, agent) => openAgentShell(context, ref, host, agent),
        ),
      ),
    );
  }
}

class _AgentsBody extends StatelessWidget {
  const _AgentsBody({
    required this.data,
    required this.now,
    required this.onConfigureHosts,
    required this.onOpen,
  });

  final AgentPanelState data;
  final DateTime now;
  final VoidCallback onConfigureHosts;
  final AgentOpen onOpen;

  @override
  Widget build(BuildContext context) {
    if (data.noHost) return _SetupLine(onTap: onConfigureHosts);

    final failures = data.failures;
    // Rows keep their host: a tap needs the machine the agent was read from, and the merged
    // list has already lost it.
    final active = [
      for (final outcome in data.outcomes)
        for (final agent in outcome.agents)
          if (agent.state.active) (host: outcome.host, agent: agent),
    ]..sort((a, b) => b.agent.stateChangeSeq.compareTo(a.agent.stateChangeSeq));
    // Resting and not idle: an agent whose work finished unwatched is idle with something to
    // read, and it is counted here rather than nowhere.
    final idle = data.agents.where((agent) => agent.state.resting).length;
    final blocked = data.agents.where((agent) => agent.blocked).length;
    // Every host failed, so there is no snapshot behind the panel and a `0 idle · 0 blocked`
    // footer would read as "nothing is running" rather than "nobody answered".
    final answered = data.answered;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final outcome in failures)
          _ErrorLine(
            text: _failureLine(outcome, failures.length > 1),
            at: outcome.lastGoodAt,
            now: now,
          ),
        if (failures.isNotEmpty && (active.isNotEmpty || answered))
          const SizedBox(height: Spacing.md),
        if (active.isNotEmpty) ...[
          for (final row in active.take(3))
            _AgentRow(row.agent, onTap: () => onOpen(row.host, row.agent)),
          const SizedBox(height: Spacing.md),
        ],
        if (answered) _Footer(idle: idle, blocked: blocked),
      ],
    );
  }

  String _failureLine(HostOutcome outcome, bool disambiguate) =>
      disambiguate ? outcome.namedReason : outcome.reason;
}

class _SetupLine extends StatelessWidget {
  const _SetupLine({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: onTap,
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: TapTargets.minHeight),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          AgentPanelState.blockedLine,
          style: context.tokens.value.copyWith(color: context.tokens.accent),
        ),
      ),
    ),
  );
}

class _AgentRow extends StatelessWidget {
  const _AgentRow(this.agent, {required this.onTap});

  final AgentSnapshot agent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final statusColor = agentStateColor(context, agent.state);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: TapTargets.minHeight),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Spacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                inboxLine(agent),
                style: context.tokens.rowTitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: Spacing.sm),
              Row(
                children: [
                  AgentMark(agent.agent),
                  const SizedBox(width: Spacing.md),
                  Expanded(
                    child: Text(
                      agentMarkName(agent.agent),
                      style: context.tokens.rowSubtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: statusColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: Spacing.sm),
                  Text(
                    agent.state.label,
                    style: context.tokens.value.copyWith(color: statusColor),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({required this.idle, required this.blocked});

  final int idle;
  final int blocked;

  @override
  Widget build(BuildContext context) => Text.rich(
    TextSpan(
      children: [
        TextSpan(text: '$idle idle · ', style: context.tokens.value),
        TextSpan(
          text: '$blocked blocked',
          style: context.tokens.value.copyWith(
            color: blocked == 0
                ? context.tokens.textMuted
                : context.tokens.danger,
          ),
        ),
      ],
    ),
  );
}

class _ErrorLine extends StatelessWidget {
  const _ErrorLine({required this.text, required this.at, required this.now});

  final String text;
  final DateTime? at;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final timestamp = at;
    return Row(
      children: [
        Expanded(child: _DimLine(text)),
        if (timestamp != null)
          Text(agentSnapshotAge(now, timestamp), style: context.tokens.value),
      ],
    );
  }
}

class _DimLine extends StatelessWidget {
  const _DimLine(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(text, style: context.tokens.value);
}
