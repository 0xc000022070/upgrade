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
import '../../design/sprite.dart';
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
            // Same reload blink as the panel: `waiting for host` would replace the workspaces on
            // every report the watcher pushes.
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
      return Column(
        children: [
          const _MascotEmpty(),
          const SizedBox(height: Spacing.xl),
          Panel(
            title: 'AGENTS',
            child: feed.noHost
                ? Text(AgentPanelState.blockedLine, style: context.tokens.value)
                : const EmptyState('no agents'),
          ),
        ],
      );
    }
    // The host level is collapsed when there is only one, which is the shape every install
    // has until a second machine is registered.
    final single = feed.outcomes.length == 1;
    return PanelStack(
      children: [
        for (final outcome in feed.outcomes)
          if (!outcome.ok)
            _FailureLine(outcome: outcome, named: !single)
          else
            ..._workspacePanels(context, outcome, named: !single),
      ],
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
        Panel(
          title: [
            if (named) outcome.host.name,
            if (sessions.length > 1) workspace.session,
            workspace.workspace,
          ].join(' / ').toUpperCase(),
          bodyPadding: panelRowsPadding,
          child: ListRowGroup(
            children: [
              for (final agent in groups[workspace]!)
                ListRow(
                  leading: AgentMark(agent.agent),
                  leadingWidth: 24,
                  title: agentMarkName(agent.agent),
                  subtitle: '${agent.paneId} · ${path.basename(agent.cwd)}',
                  value: agent.state.label,
                  valueColor: agentStateColor(context, agent.state),
                  onTap: () => onOpen(outcome.host, agent),
                ),
            ],
          ),
        ),
    ];
  }
}

class _MascotEmpty extends StatelessWidget {
  const _MascotEmpty();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Spacing.xl),
      child: Column(
        children: [
          const Sprite(state: 'idle', scale: 4),
          const SizedBox(height: Spacing.lg),
          Text('DAZZLE_', style: context.tokens.screenTitle),
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
      title: widget.named ? outcome.host.name.toUpperCase() : 'AGENTS',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _DiagnosticRow(
            label: 'HERDR',
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
      final outcome = await ref.read(agentRetryProvider)(host);
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

String _agentTarget(Host host) {
  final address = host.address.contains(':')
      ? '[${host.address}]'
      : host.address;
  return '${host.user}@$address:${host.port}';
}
