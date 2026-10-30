import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/agents/agents.dart';
import 'package:upgrade/application/agents/send.dart';
import 'package:upgrade/application/agents/send_queue.dart';
import 'package:upgrade/application/navigation.dart';
import 'package:upgrade/application/pip.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/design/components/action_block.dart';
import 'package:upgrade/design/components/dot_spinner.dart';
import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/platform/shell/shell_connection.dart';
import 'package:upgrade/features/agents/agent_shell.dart';
import 'package:upgrade/features/agents/agents_screen.dart';
import 'package:upgrade/features/agents/pip_action.dart';
import 'package:upgrade/features/agents/sent_screen.dart';
import 'package:upgrade/features/hosts/hosts_screen.dart';
import 'package:upgrade/features/shell/session/program_status.dart';
import 'package:upgrade/features/shell/session/shell_sessions.dart';
import 'package:upgrade/features/shell/sheets/shell_sheet.dart';
import 'package:upgrade/features/home/agent_mark.dart';
import 'package:upgrade/features/tasks/item_sheet.dart';

class AgentsPanel extends ConsumerWidget {
  const AgentsPanel({
    super.key,
    this.state,
    this.onViewAll,
    this.onOpen,
    this.now,
    this.programs,
  });

  final AgentPanelState? state;
  final List<TabProgram>? programs;
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
    final List<TabProgram> tabs = programs ?? ref.watch(tabProgramsProvider);
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
    Widget body(AgentPanelState? data) => _body(context, ref, data, tabs);
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
        loading: () =>
            _active(tabs).isEmpty ? const DelayedSpinner() : body(null),
        error: (error, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [_DimLine('error: $error'), body(null)],
        ),
        data: body,
      ),
    );
  }

  Widget _body(
    BuildContext context,
    WidgetRef ref,
    AgentPanelState? data,
    List<TabProgram> tabs,
  ) => _AgentsBody(
    data: data,
    programs: tabs,
    sends: ref.watch(sendQueueProvider),
    now: now ?? DateTime.now(),
    onConfigureHosts: () =>
        ref.read(navIndexProvider.notifier).state = HostsScreen.navIndex,
    onOpen:
        onOpen ??
        (intent, host, agent) =>
            openAgentShell(context, ref, host, agent, intent),
    onOpenTab: (intent, program) {
      ref.read(navIndexProvider.notifier).state = HostsScreen.navIndex;
      openHostShell(
        context,
        program.host,
        intent: intent,
        session: program.session,
      );
    },
  );
}

List<TabProgram> _active(List<TabProgram> programs) => [
  for (final program in programs)
    if (program.record.state.active) program,
]..sort((a, b) => b.record.seq.compareTo(a.record.seq));

class _AgentsBody extends StatelessWidget {
  const _AgentsBody({
    required this.data,
    required this.programs,
    required this.sends,
    required this.now,
    required this.onConfigureHosts,
    required this.onOpen,
    required this.onOpenTab,
  });

  final AgentPanelState? data;
  final List<TabProgram> programs;
  final List<PendingSend> sends;
  final DateTime now;
  final VoidCallback onConfigureHosts;
  final AgentOpen onOpen;
  final void Function(UserIntent intent, TabProgram program) onOpenTab;

  @override
  Widget build(BuildContext context) {
    final data = this.data;
    final tabs = _active(programs);
    if (data == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final program in tabs.take(_rowLimit)) _tabRow(context, program),
        ],
      );
    }
    if (data.noHost && tabs.isEmpty) {
      return _SetupLine(onTap: onConfigureHosts);
    }

    final failures = data.failures;
    // Rows keep their host: a tap needs the machine the agent was read from, and the merged
    // list has already lost it.
    final active = [
      for (final outcome in data.outcomes)
        for (final agent in outcome.agents)
          if (agent.state.active) (host: outcome.host, agent: agent),
    ]..sort((a, b) => b.agent.stateChangeSeq.compareTo(a.agent.stateChangeSeq));
    final idle =
        data.agents.where((agent) => agent.state.resting).length +
        programs.where((program) => !program.record.state.active).length;
    final blocked =
        data.agents.where((agent) => agent.blocked).length +
        programs
            .where((program) => program.record.state == ProgramState.blocked)
            .length;
    // Every host failed, so there is no snapshot behind the panel and a `0 idle · 0 blocked`
    // footer would read as "nothing is running" rather than "nobody answered".
    final answered = data.answered;
    final shown = sends.take(_rowLimit).toList();
    final hosted = active.take(_rowLimit - shown.length).toList();
    final tabbed = tabs.take(_rowLimit - shown.length - hosted.length);

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
            (shown.isNotEmpty ||
                active.isNotEmpty ||
                tabs.isNotEmpty ||
                answered))
          const SizedBox(height: Spacing.md),
        if (shown.isNotEmpty || active.isNotEmpty || tabs.isNotEmpty) ...[
          for (final send in shown) _SendRow(send),
          for (final row in hosted)
            _AgentRow(
              line: inboxLine(row.agent),
              agent: row.agent.agent,
              name: agentMarkName(row.agent.agent),
              status: row.agent.state.label,
              statusColor: agentStateColor(context, row.agent.state),
              onTap: UserIntent.onGesture(
                (intent) => onOpen(intent, row.host, row.agent),
              ),
            ),
          for (final program in tabbed) _tabRow(context, program),
          const SizedBox(height: Spacing.md),
        ],
        if (answered) _Footer(idle: idle, blocked: blocked),
      ],
    );
  }

  static const _rowLimit = 3;

  Widget _tabRow(BuildContext context, TabProgram program) {
    final app = program.record.app;
    final kind = agentKindOfApp(app)?.name;
    final named = kind == null ? app.toUpperCase() : agentMarkName(kind);
    return _AgentRow(
      line: program.line,
      agent: kind,
      name: named.isEmpty ? program.origin : '$named · ${program.origin}',
      status: program.record.state.label,
      statusColor: program.record.state == ProgramState.blocked
          ? context.tokens.danger
          : context.tokens.warning,
      onTap: UserIntent.onGesture((intent) => onOpenTab(intent, program)),
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
  const _AgentRow({
    required this.line,
    required this.agent,
    required this.name,
    required this.status,
    required this.statusColor,
    required this.onTap,
  });

  final String line;

  final String? agent;
  final String name;
  final String status;
  final Color statusColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
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
                line,
                style: context.tokens.rowTitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: Spacing.sm),
              Row(
                children: [
                  if (agent case final agent?) ...[
                    AgentMark(agent),
                    const SizedBox(width: Spacing.md),
                  ],
                  Expanded(
                    child: Text(
                      name,
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
                    status,
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
