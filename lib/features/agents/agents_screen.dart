import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

import '../../app/static_surface.dart';
import '../../application/agents.dart';
import '../../data/repositories/host_repository.dart';
import '../../design/components/list_row.dart';
import '../../design/components/meta.dart';
import '../../design/components/panel.dart';
import '../../design/components/panel_text_action.dart';
import '../../design/components/section.dart';
import '../../design/icons/dazzle_icons.dart';
import '../../design/spacing.dart';
import '../../design/tokens.dart';
import '../../platform/herdr_client.dart';
import '../home/agent_mark.dart';
import '../screen_scaffold.dart';
import 'agent_shell.dart';
import 'pip_action.dart';

void openAgents(BuildContext context) {
  Navigator.of(
    context,
    rootNavigator: true,
  ).push(MaterialPageRoute<void>(builder: (_) => const AgentsScreen()));
}

class AgentsScreen extends ConsumerWidget {
  const AgentsScreen({super.key, this.onOpen});

  final AgentOpen? onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(agentsFeedProvider);
    return Scaffold(
      body: StaticSurface(
        child: ScreenScaffold(
          title: 'AGENTS',
          breadcrumb: '/ DAZZLE / AGENTS',
          titleTrailing: const PipAffordance(),
          onBack: () => Navigator.of(context).pop(),
          children: [
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

class _Feed extends StatelessWidget {
  const _Feed(this.feed, {required this.onOpen});

  final AgentPanelState feed;
  final AgentOpen onOpen;

  bool get _empty =>
      feed.noHost ||
      feed.outcomes.every((outcome) => outcome.ok && outcome.agents.isEmpty);

  @override
  Widget build(BuildContext context) {
    if (_empty) {
      return Panel(
        title: 'AGENTS',
        child: feed.noHost
            ? Text(AgentPanelState.blockedLine, style: context.tokens.value)
            : const EmptyState('no agents'),
      );
    }
    final single =
        {for (final outcome in feed.outcomes) outcome.host.id}.length == 1;
    final herdr = feed.outcomes.where(
      (outcome) => outcome.source == AgentSource.herdr,
    );
    final engine = feed.outcomes.where(
      (outcome) => outcome.source == AgentSource.engine,
    );
    return PanelStack(
      children: [
        for (final outcome in herdr)
          if (!outcome.ok)
            _FailureLine(outcome: outcome, named: !single)
          else
            ..._workspacePanels(context, outcome, named: !single),
        for (final outcome in engine)
          if (!outcome.ok)
            _FailureLine(outcome: outcome, named: !single)
          else
            _inboxPanel(context, outcome, named: !single),
      ],
    );
  }

  Widget _inboxPanel(
    BuildContext context,
    HostOutcome outcome, {
    required bool named,
  }) {
    final sessions = [...outcome.agents]
      ..sort((a, b) => b.stateChangeSeq.compareTo(a.stateChangeSeq));
    return Panel(
      title: inboxTitle(outcome.host, named: named),
      bodyPadding: sessions.isEmpty
          ? const EdgeInsets.all(Spacing.panelPadding)
          : panelRowsPadding,
      child: sessions.isEmpty
          ? const EmptyState('no sessions')
          : ListRowGroup(
              children: [
                for (final agent in sessions)
                  ListRow(
                    leading: AgentMark(agent.agent),
                    leadingWidth: 24,
                    title: inboxLine(agent),
                    titleMaxLines: 2,
                    subtitle:
                        '${agentMarkName(agent.agent)} · ${path.basename(agent.cwd)} · ${outcome.host.name}',
                    value: agent.state.label,
                    valueColor: agentStateColor(context, agent.state),
                    onTap: () => onOpen(outcome.host, agent),
                  ),
              ],
            ),
    );
  }

  List<Widget> _workspacePanels(
    BuildContext context,
    HostOutcome outcome, {
    required bool named,
  }) {
    final groups =
        <({String session, String workspace}), List<AgentSnapshot>>{};
    for (final agent in outcome.agents) {
      groups
          .putIfAbsent((
            session: agent.session,
            workspace: agent.workspaceId,
          ), () => [])
          .add(agent);
    }
    final workspaces = groups.keys.toList()
      ..sort(
        (a, b) => a.session != b.session
            ? a.session.compareTo(b.session)
            : a.workspace.compareTo(b.workspace),
      );
    final sessions = {for (final key in workspaces) key.session};
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
        _workspacePanel(
          context,
          outcome,
          groups[workspace]!,
          parents: [
            if (named) outcome.host.name,
            if (sessions.length > 1) workspace.session,
          ],
        ),
    ];
  }

  Widget _workspacePanel(
    BuildContext context,
    HostOutcome outcome,
    List<AgentSnapshot> agents, {
    required List<String> parents,
  }) {
    final label = agents.first.workspaceLabel;
    return Panel(
      title: label == null
          ? [
              for (final parent in parents) parent.toUpperCase(),
              agents.first.workspaceId,
            ].join(' / ')
          : [...parents, label].join(' / '),
      literalTitle: label == null,
      bodyPadding: panelRowsPadding,
      child: ListRowGroup(
        children: [
          for (final agent in agents)
            ListRow(
              leading: AgentMark(agent.agent),
              leadingWidth: 24,
              title: agent.terminalTitleStripped.trim().isEmpty
                  ? '${agentMarkName(agent.agent)} session'
                  : agent.terminalTitleStripped.trim(),
              titleMaxLines: 2,
              subtitle:
                  '${agentMarkName(agent.agent)} · ${path.basename(agent.cwd)} · ${outcome.host.name}',
              caption: agent.blocked
                  ? 'Needs attention · tap to open terminal'
                  : '${agent.session} · ${agent.paneId}',
              value: agent.state.label,
              valueColor: agentStateColor(context, agent.state),
              onTap: () => onOpen(outcome.host, agent),
            ),
        ],
      ),
    );
  }
}

class _FailureLine extends ConsumerStatefulWidget {
  const _FailureLine({required this.outcome, required this.named});

  final HostOutcome outcome;
  final bool named;

  @override
  ConsumerState<_FailureLine> createState() => _FailureLineState();
}

class _FailureLineState extends ConsumerState<_FailureLine> {
  HostOutcome? _retried;
  bool _retrying = false;
  bool _retryFailed = false;

  @override
  void didUpdateWidget(_FailureLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.outcome != widget.outcome ||
        oldWidget.outcome.host.id != widget.outcome.host.id) {
      _retried = null;
      _retryFailed = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final outcome = _retried ?? widget.outcome;
    final timestamp = outcome.lastGoodAt;
    return Panel(
      title: outcome.source == AgentSource.engine
          ? inboxTitle(outcome.host, named: widget.named)
          : widget.named
          ? outcome.host.name.toUpperCase()
          : 'AGENTS',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _DiagnosticRow(
            label: outcome.source == AgentSource.engine ? 'AGENTS' : 'HERDR',
            value: outcome.ok ? 'connected' : outcome.reason,
          ),
          _DiagnosticRow(
            label: 'DETAIL',
            value: _retryFailed ? 'retry request failed' : outcome.diagnostic,
            maxLines: 2,
          ),
          _DiagnosticRow(
            label: 'TARGET',
            value: _agentTarget(outcome.host),
            maxLines: 2,
          ),
          _DiagnosticRow(
            label: 'LAST UPDATE',
            value: timestamp == null
                ? 'never connected'
                : agentSnapshotAge(DateTime.now(), timestamp),
          ),
          if (!outcome.ok && outcome.kind.retryable)
            PanelTextAction(
              label: _retrying ? 'RETRYING' : 'RETRY',
              onTap: _retrying ? null : _retry,
              icon: DazzleIcons.sync,
            ),
        ],
      ),
    );
  }

  Future<void> _retry() async {
    setState(() {
      _retrying = true;
      _retryFailed = false;
    });
    try {
      final host = widget.outcome.host;
      final outcome = await ref.read(agentRetryProvider)(
        host,
        source: widget.outcome.source,
      );
      if (!mounted || widget.outcome.host.id != host.id) return;
      setState(() => _retried = outcome);
    } catch (_) {
      if (mounted) setState(() => _retryFailed = true);
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }
}

class _DiagnosticRow extends StatelessWidget {
  const _DiagnosticRow({
    required this.label,
    required this.value,
    this.maxLines = 1,
  });

  final String label;
  final String value;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final labelSize = context.tokens.label.fontSize!;
    final labelScale =
        MediaQuery.textScalerOf(context).scale(labelSize) / labelSize;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 32),
      child: Row(
        children: [
          SizedBox(
            width: 80 * labelScale,
            child: Text(label, style: context.tokens.label),
          ),
          const SizedBox(width: Spacing.md),
          Expanded(child: Meta(value, maxLines: maxLines)),
        ],
      ),
    );
  }
}

String inboxTitle(Host host, {required bool named}) =>
    named ? '${host.name.toUpperCase()} / INBOX' : 'INBOX';

String inboxLine(AgentSnapshot agent) {
  final line =
      agent.approval?.line ?? agent.question ?? agent.terminalTitleStripped;
  return line.trim().isEmpty
      ? '${agentMarkName(agent.agent)} session'
      : line.trim();
}

String _agentTarget(Host host) {
  final address = host.address.contains(':')
      ? '[${host.address}]'
      : host.address;
  return '${host.user}@$address:${host.port}';
}
