import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:striked/application/agents/agents.dart';
import 'package:striked/application/agents/send.dart';
import 'package:striked/application/agents/send_queue.dart';
import 'package:striked/application/navigation.dart';
import 'package:striked/application/pip.dart';
import 'package:striked/design/tokens.dart';
import 'package:striked/design/components/action_block.dart';
import 'package:striked/design/components/dot_spinner.dart';
import 'package:striked/design/components/panel.dart';
import 'package:striked/design/spacing.dart';
import 'package:striked/platform/herdr/herdr_client.dart';
import 'package:striked/platform/shell/shell_connection.dart';
import 'package:striked/features/agents/agent_shell.dart';
import 'package:striked/features/agents/agents_screen.dart';
import 'package:striked/features/agents/pip_action.dart';
import 'package:striked/features/agents/sent_screen.dart';
import 'package:striked/features/hosts/hosts_screen.dart';
import 'package:striked/features/home/agent_mark.dart';
import 'package:striked/features/tasks/item_sheet.dart';

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
          sends: ref.watch(sendQueueProvider),
          now: now ?? DateTime.now(),
          onConfigureHosts: () =>
              ref.read(navIndexProvider.notifier).state = HostsScreen.navIndex,
          onOpen:
              onOpen ??
              (intent, host, agent) =>
                  openAgentShell(context, ref, host, agent, intent),
        ),
      ),
    );
  }
}

class _AgentsBody extends StatelessWidget {
  const _AgentsBody({
    required this.data,
    required this.sends,
    required this.now,
    required this.onConfigureHosts,
    required this.onOpen,
  });

  final AgentPanelState data;
  final List<PendingSend> sends;
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
    final shown = sends.take(_rowLimit).toList();

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
        if (failures.isNotEmpty &&
            (shown.isNotEmpty || active.isNotEmpty || answered))
          const SizedBox(height: Spacing.md),
        if (shown.isNotEmpty || active.isNotEmpty) ...[
          for (final send in shown) _SendRow(send),
          for (final row in active.take(_rowLimit - shown.length))
            _AgentRow(
              row.agent,
              onTap: UserIntent.onGesture(
                (intent) => onOpen(intent, row.host, row.agent),
              ),
            ),
          const SizedBox(height: Spacing.md),
        ],
        if (answered) _Footer(idle: idle, blocked: blocked),
      ],
    );
  }

  static const _rowLimit = 3;

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

class _SendRow extends ConsumerWidget {
  const _SendRow(this.send);

  final PendingSend send;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = send.state;
    final failed = state is SendFailed;
    final statusColor = failed
        ? context.tokens.danger
        : context.tokens.textMuted;
    final itemId = send.itemId;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: itemId == null
          ? () => openRun(context, send.id)
          : () => openItemSheet(context, itemId),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: TapTargets.minHeight),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Spacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                send.title,
                style: context.tokens.rowTitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: Spacing.sm),
              Row(
                children: [
                  AgentMark(send.kind.name),
                  const SizedBox(width: Spacing.md),
                  Expanded(
                    child: Text(
                      agentMarkName(send.kind.name),
                      style: context.tokens.rowSubtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (failed)
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: statusColor,
                        shape: BoxShape.circle,
                      ),
                    )
                  else
                    const DotSpinner(),
                  const SizedBox(width: Spacing.sm),
                  Text(
                    failed ? 'FAILED' : 'STARTING',
                    style: context.tokens.value.copyWith(color: statusColor),
                    maxLines: 1,
                  ),
                ],
              ),
              if (state is SendFailed && itemId == null) ...[
                const SizedBox(height: Spacing.sm),
                Text(
                  state.reason,
                  style: context.tokens.value.copyWith(color: statusColor),
                ),
                const SizedBox(height: Spacing.sm),
                Wrap(
                  spacing: Spacing.md,
                  children: [
                    ActionBlock(
                      label: 'RETRY',
                      onTap: () =>
                          ref.read(sendQueueProvider.notifier).retry(send.id),
                    ),
                    ActionBlock(
                      label: 'DISMISS',
                      onTap: () =>
                          ref.read(sendQueueProvider.notifier).dismiss(send.id),
                    ),
                  ],
                ),
              ],
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
