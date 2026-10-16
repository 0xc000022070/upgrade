import 'dart:async';

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

  static const _pageLimit = 200;
  static const _pagesPerTick = 20;
  static const _kept = 400;

  late final EngineOpen _open = ref.read(engineOpenProvider);
  Future<EngineAgents>? _engine;
  Timer? _timer;
  late bool _visible = ref.read(appVisibleProvider);
  bool _onStage = true;
  bool _asking = false;
  bool _gone = false;

  late AgentSnapshot? _session = widget.agent;
  final List<TranscriptItem> _items = [];
  bool _cut = false;
  int? _last;
  bool _noTranscript = false;
  bool _unnamed = false;
  String? _failure;
  String? _answering;
  String? _answerLine;

  String get _key => widget.agent.paneId;

  void _drop() {
    final engine = _engine;
    _engine = null;
    unawaited(
      engine?.then((engine) => engine.session.close(), onError: (_) {}),
    );
  }

  @override
  void initState() {
    super.initState();
    ref.listenManual<bool>(appVisibleProvider, (_, visible) {
      _visible = visible;
      _sync();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _onStage = TickerMode.valuesOf(context).enabled;
    _sync();
  }

  void _sync() {
    final run = _visible && _onStage;
    if (run == (_timer != null)) return;
    _timer?.cancel();
    _timer = null;
    if (!run) {
      _drop();
      return;
    }
    unawaited(_tick());
    _timer = Timer.periodic(AgentChatScreen.interval, (_) => _tick());
  }

  @override
  void dispose() {
    _gone = true;
    _timer?.cancel();
    _drop();
    super.dispose();
  }

  Future<void> _tick() async {
    if (_asking || _gone) return;
    _asking = true;
    try {
      final engine = await (_engine ??= _open(_host));
      if (_gone) return;
      final watched = await engine.watch();
      final session = watched.agents
          .where((agent) => agent.paneId == _key)
          .firstOrNull;
      final read = await _read(engine);
      if (_gone || !mounted) return;
      setState(() {
        _session = session;
        _last = read.last;
        _unnamed = read.unnamed;
        _items.addAll(read.fresh);
        if (_items.length > _kept) {
          _items.removeRange(0, _items.length - _kept);
          _cut = true;
        }
        _failure = read.failure;
      });
    } catch (error) {
      debugPrint('upgrade.engine ${_host.name} chat: $error');
      _drop();
      if (_gone || !mounted) return;
      setState(
        () => _failure = switch (error) {
          HerdrFailure() => error.line.on(_host.name),
          EngineRefused() => _refusal(error),
          _ => 'failed',
        },
      );
    } finally {
      _asking = false;
    }
  }

  static String _refusal(EngineRefused error) =>
      error.kind.replaceAll('_', ' ');

  Future<
    ({List<TranscriptItem> fresh, int? last, bool unnamed, String? failure})
  >
  _read(EngineAgents engine) async {
    final fresh = <TranscriptItem>[];
    var last = _last;
    if (_noTranscript) {
      return (fresh: fresh, last: last, unnamed: false, failure: null);
    }
    try {
      for (var page = 0; page < _pagesPerTick; page++) {
        final read = await engine.transcript(_key, after: last);
        fresh.addAll(read.items);
        final done = read.last == last || read.items.length < _pageLimit;
        last = read.last;
        if (done) break;
      }
    } on EngineRefused catch (error) {
      _noTranscript = error.kind == 'unsupported';
      final settled = error.notFound || _noTranscript;
      return (
        fresh: fresh,
        last: last,
        unnamed: error.notFound,
        failure: settled ? null : _refusal(error),
      );
    }
    return (fresh: fresh, last: last, unnamed: false, failure: null);
  }

  Future<void> _answer(AgentApproval approval, {required bool allow}) async {
    setState(() {
      _answering = approval.id;
      _answerLine = null;
    });
    try {
      final engine = await (_engine ??= _open(_host));
      await engine.answer(approval.id, allow: allow);
      if (mounted) setState(() => _answerLine = allow ? 'ALLOWED' : 'DENIED');
    } on EngineRefused catch (error) {
      if (mounted) {
        setState(
          () => _answerLine = error.notFound ? 'ALREADY ANSWERED' : 'REFUSED',
        );
      }
    } catch (error) {
      debugPrint('upgrade.engine ${_host.name} answer: $error');
      if (mounted) setState(() => _answerLine = 'FAILED');
    } finally {
      if (mounted) setState(() => _answering = null);
    }
    unawaited(_tick());
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
    final session = _session;
    final link = _link(ref.watch(agentsFeedProvider).valueOrNull);
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
                      if (_failure != null)
                        _Row('LINK', _failure!, color: context.tokens.warning),
                    ],
                  ),
                ),
                Panel(
                  title: 'CONVERSATION',
                  child: _noTranscript
                      ? const EmptyState('NO TRANSCRIPT')
                      : _items.isEmpty
                      ? EmptyState(
                          _unnamed
                              ? 'no transcript yet'
                              : _last == null
                              ? 'waiting for host'
                              : 'nothing yet',
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (_cut) const Meta('earlier lines cut'),
                            for (final item in _items)
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
              if (_answerLine != null) Meta(_answerLine!),
              const SizedBox(height: Spacing.sm),
              Row(
                children: [
                  Expanded(
                    child: ActionBlock(
                      label: 'DENY',
                      tone: context.tokens.warning,
                      onTap: _answering == null
                          ? () => _answer(approval, allow: false)
                          : null,
                    ),
                  ),
                  const SizedBox(width: Spacing.md),
                  Expanded(
                    child: ActionBlock(
                      label: 'ALLOW',
                      tone: context.tokens.accent,
                      filled: true,
                      onTap: _answering == null
                          ? () => _answer(approval, allow: true)
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
