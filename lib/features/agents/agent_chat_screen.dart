import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/app/static_surface.dart';
import 'package:upgrade/application/agents/agents.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/design/components/action_block.dart';
import 'package:upgrade/design/components/meta.dart';
import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/design/components/panel_text_action.dart';
import 'package:upgrade/design/components/section.dart';
import 'package:upgrade/design/icons/upgrade_icons.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/platform/herdr/engine_agents.dart';
import 'package:upgrade/platform/herdr/herdr_client.dart';
import 'package:upgrade/platform/shell/shell_connection.dart';
import 'package:upgrade/features/home/agent_mark.dart';
import 'package:upgrade/design/components/screen_scaffold.dart';
import 'package:upgrade/features/agents/agent_session_feed.dart';
import 'package:upgrade/features/agents/agent_shell.dart';

void openAgentChat(BuildContext context, Host host, AgentSnapshot agent) {
  Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(
      builder: (_) => AgentChatScreen(host: host, agent: agent),
    ),
  );
}

class AgentChatScreen extends ConsumerStatefulWidget {
  const AgentChatScreen({super.key, required this.host, required this.agent});

  final Host host;

  final AgentSnapshot agent;

  static const interval = Duration(seconds: 3);

  @override
  ConsumerState<AgentChatScreen> createState() => _AgentChatScreenState();
}

class _AgentChatScreenState extends ConsumerState<AgentChatScreen> {
  Host get _host =>
      ref.read(registeredHostProvider(widget.host.id)) ?? widget.host;

  late final AgentSessionFeed _feed;

  String get _key => widget.agent.paneId;

  @override
  void initState() {
    super.initState();
    _feed = AgentSessionFeed(
      open: ref.read(engineOpenProvider),
      target: () async => _host,
      interval: AgentChatScreen.interval,
      tag: 'chat',
      visible: ref.read(appVisibleProvider),
      key: _key,
      session: widget.agent,
    )..addListener(_changed);
    ref.listenManual<bool>(appVisibleProvider, (_, visible) {
      _feed.visible = visible;
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _feed.onStage = TickerMode.valuesOf(context).enabled;
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    _feed.dispose();
    super.dispose();
  }

  PaneRef? _link(AgentPanelState? feed) {
    for (final outcome in feed?.outcomes ?? const <HostOutcome>[]) {
      if (outcome.host.id != widget.host.id ||
          outcome.source != AgentSource.engine) {
        continue;
      }
      for (final agent in outcome.agents) {
        if (agent.paneId == _key) return agent.link;
      }
    }
    return widget.agent.link;
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(registeredHostProvider(widget.host.id));
    final feed = _feed;
    final session = feed.session;
    final link = _link(ref.watch(agentsFeedProvider).value);
    final bar = _bar(context, session, link);
    return Scaffold(
      bottomNavigationBar: bar,
      body: StaticSurface(
        child: ScreenScaffold(
          title: agentMarkName(widget.agent.agent),
          breadcrumb: '/ UPGRADE / AGENTS',
          onBack: () => Navigator.of(context).pop(),
          children: [
            PanelStack(
              children: [
                Panel(
                  title: 'SESSION',
                  bodyPadding: panelRowsPadding,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _Row(
                        'STATE',
                        session?.state.label ?? 'ENDED',
                        color: session == null
                            ? context.tokens.textMuted
                            : agentStateColor(context, session.state),
                      ),
                      _Row('DIRECTORY', widget.agent.cwd),
                      _Row('HOST', _host.name),
                      if (feed.failure case final failure?)
                        _Row('LINK', failure, color: context.tokens.warning),
                    ],
                  ),
                ),
                Panel(
                  title: 'CONVERSATION',
                  child: feed.noTranscript
                      ? const EmptyState('NO TRANSCRIPT')
                      : feed.items.isEmpty
                      ? EmptyState(
                          feed.unnamed
                              ? 'no transcript yet'
                              : feed.last == null
                              ? 'waiting for host'
                              : 'nothing yet',
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (feed.cut) const Meta('earlier lines cut'),
                            for (final item in feed.items)
                              _Item(item, agent: widget.agent.agent),
                          ],
                        ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget? _bar(BuildContext context, AgentSnapshot? session, PaneRef? link) {
    final approval = session?.approval;
    final question = session?.question;
    if (approval == null && question == null && link == null) return null;
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: context.tokens.surfacePrimary,
          border: Border(
            top: BorderSide(
              color: context.tokens.borderSubtle,
              width: Borders.hairline,
            ),
          ),
        ),
        padding: const EdgeInsets.all(Spacing.panelPadding),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (approval != null) ...[
              Text(
                approval.line,
                style: context.tokens.value,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
              ),
              if (_feed.answerLine case final line?) Meta(line),
              const SizedBox(height: Spacing.sm),
              Row(
                children: [
                  Expanded(
                    child: ActionBlock(
                      label: 'DENY',
                      tone: context.tokens.warning,
                      onTap: _feed.answering == null
                          ? () => _feed.answer(_host, approval, allow: false)
                          : null,
                    ),
                  ),
                  const SizedBox(width: Spacing.md),
                  Expanded(
                    child: ActionBlock(
                      label: 'ALLOW',
                      tone: context.tokens.accent,
                      filled: true,
                      onTap: _feed.answering == null
                          ? () => _feed.answer(_host, approval, allow: true)
                          : null,
                    ),
                  ),
                ],
              ),
            ] else if (question != null)
              Text(
                question,
                style: context.tokens.value,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
              ),
            if (link != null)
              PanelTextAction(
                label: 'OPEN PANE',
                icon: UpgradeIcons.forward,
                onTap: UserIntent.onGesture(
                  (intent) => openAgentPane(context, ref, _host, link, intent),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value, {this.color});

  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: RowMetrics.minHeight),
      child: Row(
        children: [
          SizedBox(width: 96, child: Text(label, style: context.tokens.label)),
          const SizedBox(width: Spacing.md),
          Expanded(child: Meta(value, color: color)),
        ],
      ),
    );
  }
}

class _Item extends StatelessWidget {
  const _Item(this.item, {required this.agent});

  final TranscriptItem item;
  final String agent;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final (label, style, maxLines) = switch (item.kind) {
      'user' => ('YOU', tokens.prose.copyWith(color: tokens.accent), null),
      'assistant' => (agentMarkName(agent), tokens.prose, null),
      'tool' => ((item.tool ?? 'TOOL').toUpperCase(), tokens.value, 6),
      _ => (
        item.error ? 'ERROR' : 'RESULT',
        tokens.value.copyWith(
          color: item.error ? tokens.warning : tokens.textMuted,
        ),
        6,
      ),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label, style: tokens.label),
          const SizedBox(height: Spacing.xs),
          Text(
            item.text,
            style: style,
            maxLines: maxLines,
            overflow: maxLines == null ? null : TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
