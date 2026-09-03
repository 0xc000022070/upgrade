import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/agents.dart';
import '../../design/colors.dart';
import '../../design/components/dot_spinner.dart';
import '../../design/components/panel.dart';
import '../../design/spacing.dart';
import '../../design/typography.dart';
import '../../platform/herdr_client.dart';
import '../agents/agents_screen.dart';

class AgentsPanel extends ConsumerWidget {
  const AgentsPanel({super.key, this.state, this.onViewAll, this.now});

  final AgentPanelState? state;
  final VoidCallback? onViewAll;
  final DateTime? now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final supplied = state;
    final value = supplied == null
        ? ref.watch(agentsFeedProvider)
        : AsyncValue<AgentPanelState>.data(supplied);
    final current = value.valueOrNull;
    return Panel(
      title: 'AGENTS',
      affordance: (current?.noHost ?? false)
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                PanelAffordance(
                  '${current?.agents.length ?? 0}',
                  showIcon: false,
                ),
                const SizedBox(width: Spacing.lg),
                PanelAffordance(
                  'VIEW ALL',
                  onTap: onViewAll ?? () => openAgents(context),
                ),
              ],
            ),
      bodyPadding: const EdgeInsets.symmetric(
        horizontal: Spacing.panelPadding,
        vertical: Spacing.md,
      ),
      child: value.when(
        loading: () => const DelayedSpinner(),
        error: (error, _) => _DimLine('error: $error'),
        data: (data) => _AgentsBody(data: data, now: now ?? DateTime.now()),
      ),
    );
  }
}

class _AgentsBody extends StatelessWidget {
  const _AgentsBody({required this.data, required this.now});

  final AgentPanelState data;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    // §39.20: blocked is one dim line and nothing else — no rows, no footer.
    if (data.noHost) return const _DimLine(AgentPanelState.blockedLine);

    final failures = data.failures;
    final active =
        data.agents
            .where(
              (agent) =>
                  agent.agentStatus == 'working' ||
                  agent.agentStatus == 'blocked',
            )
            .toList()
          ..sort((a, b) => b.stateChangeSeq.compareTo(a.stateChangeSeq));
    final idle = data.agents
        .where((agent) => agent.agentStatus == 'idle')
        .length;
    final blocked = data.agents
        .where((agent) => agent.agentStatus == 'blocked')
        .length;
    // Every host failed, so there is no snapshot behind the panel and a
    // `0 idle · 0 blocked` footer would read as "nothing is running" rather
    // than "nobody answered".
    final answered = failures.length < data.outcomes.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // One line per failing host, above the rows the healthy hosts still
        // contribute. A failure never takes the panel down with it.
        for (final outcome in failures)
          _ErrorLine(
            text: _failureLine(outcome, failures.length > 1),
            at: outcome.lastGoodAt,
            now: now,
          ),
        if (failures.isNotEmpty && (active.isNotEmpty || answered))
          const SizedBox(height: Spacing.md),
        if (active.isNotEmpty) ...[
          const _ColumnLabels(),
          const SizedBox(height: Spacing.sm),
          for (final agent in active.take(3)) _AgentRow(agent),
          const SizedBox(height: Spacing.md),
        ],
        if (answered) _Footer(idle: idle, blocked: blocked),
      ],
    );
  }

  /// §39.20 words the unreachable line with its host and the other two without.
  /// With one failing host that reads fine; with two, `key rejected` twice does
  /// not say which machine, so the host is put back in front.
  String _failureLine(HostOutcome outcome, bool disambiguate) {
    if (!disambiguate || outcome.kind == AgentOutcomeKind.unreachable) {
      return outcome.reason;
    }
    return '${outcome.host.name.toLowerCase()} · ${outcome.reason}';
  }
}

class _ColumnLabels extends StatelessWidget {
  const _ColumnLabels();

  @override
  Widget build(BuildContext context) => const Row(
    children: [
      Expanded(flex: 4, child: Text('AGENT', style: HotlineText.label)),
      Expanded(flex: 3, child: Text('STATUS', style: HotlineText.label)),
      Expanded(flex: 4, child: Text('WORK', style: HotlineText.label)),
    ],
  );
}

class _AgentRow extends StatelessWidget {
  const _AgentRow(this.agent);

  final AgentSnapshot agent;

  @override
  Widget build(BuildContext context) {
    final statusColor = switch (agent.agentStatus) {
      'working' => HotlineColors.accent,
      'blocked' => HotlineColors.warning,
      _ => HotlineColors.textMuted,
    };
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: TapTargets.minHeight),
      child: Row(
        children: [
          Expanded(
            flex: 4,
            child: Row(
              children: [
                Container(
                  width: 24,
                  height: 24,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    border: Border.all(color: HotlineColors.borderNormal),
                    borderRadius: BorderRadius.circular(Radii.sharp),
                  ),
                  child: Text(switch (agent.agent) {
                    'claude' => 'C',
                    'codex' => 'X',
                    _ => '?',
                  }, style: HotlineText.valueStrong),
                ),
                const SizedBox(width: Spacing.md),
                Expanded(
                  child: Text(
                    agent.agent.toUpperCase(),
                    style: HotlineText.rowTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 3,
            child: Row(
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: statusColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: Spacing.sm),
                Flexible(
                  child: Text(
                    agent.agentStatus.toUpperCase(),
                    style: HotlineText.value.copyWith(color: statusColor),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 4,
            child: Text(
              agent.terminalTitleStripped,
              style: HotlineText.rowSubtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
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
        TextSpan(text: '$idle idle · ', style: HotlineText.value),
        TextSpan(
          text: '$blocked blocked',
          style: HotlineText.value.copyWith(
            color: blocked == 0
                ? HotlineColors.textMuted
                : HotlineColors.warning,
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
          Text(agentSnapshotAge(now, timestamp), style: HotlineText.value),
      ],
    );
  }
}

class _DimLine extends StatelessWidget {
  const _DimLine(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(text, style: HotlineText.value);
}
