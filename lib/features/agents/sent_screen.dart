import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

import 'package:striked/app/static_surface.dart';
import 'package:striked/application/agents/agent_kind.dart';
import 'package:striked/application/agents/agent_state.dart';
import 'package:striked/application/agents/agents.dart';
import 'package:striked/application/agents/run_steps.dart';
import 'package:striked/application/agents/send.dart';
import 'package:striked/application/agents/send_queue.dart';
import 'package:striked/application/agents/send_states.dart';
import 'package:striked/application/drops/attachment_files.dart';
import 'package:striked/application/launcher/launcher_sends.dart';
import 'package:striked/application/formatting.dart';
import 'package:striked/application/providers.dart';
import 'package:striked/data/enums.dart';
import 'package:striked/data/repositories/dispatch_repository.dart';
import 'package:striked/data/repositories/host_repository.dart';
import 'package:striked/design/components/action_block.dart';
import 'package:striked/design/components/action_sheet.dart';
import 'package:striked/design/components/list_row.dart';
import 'package:striked/design/components/meta.dart';
import 'package:striked/design/components/panel.dart';
import 'package:striked/design/components/panel_text_action.dart';
import 'package:striked/design/components/screen_scaffold.dart';
import 'package:striked/design/components/section.dart';
import 'package:striked/design/icons/striked_icons.dart';
import 'package:striked/design/spacing.dart';
import 'package:striked/design/tokens.dart';
import 'package:striked/features/agents/agent_chat_screen.dart';
import 'package:striked/features/agents/agent_shell.dart';
import 'package:striked/features/home/agent_mark.dart';
import 'package:striked/features/home/compose_sheet.dart';
import 'package:striked/platform/herdr/engine_agents.dart';
import 'package:striked/platform/herdr/herdr_client.dart';
import 'package:striked/platform/shell/shell_connection.dart';

void openSent(BuildContext context) {
  Navigator.of(
    context,
    rootNavigator: true,
  ).push(MaterialPageRoute<void>(builder: (_) => const SentScreen()));
}

void openRun(BuildContext context, String sendId) {
  Navigator.of(
    context,
    rootNavigator: true,
  ).push(MaterialPageRoute<void>(builder: (_) => RunScreen(sendId: sendId)));
}

Future<SendChoice?> _choiceOf(WidgetRef ref, Dispatch send) async {
  final targets = ref.read(pathTargetsProvider.future);
  final kind = AgentKind.lookup(send.agent);
  final target = (await targets)
      .where((target) => target.path.id == send.pathId)
      .firstOrNull;
  if (kind == null || target == null) return null;
  return SendChoice(target: target, kind: kind, model: send.model);
}

Future<void> retrySend(WidgetRef ref, Dispatch send) async {
  final queue = ref.read(sendQueueProvider.notifier);
  final sender = ref.read(senderProvider);
  final files = ref.read(attachmentFilesProvider);
  final tasks = ref.read(taskRepositoryProvider);
  final attachments = ref.read(attachmentRepositoryProvider);
  final choice = await _choiceOf(ref, send);
  final itemId = send.itemId;
  final task = itemId == null ? null : await tasks.watchById(itemId).first;
  if (choice == null || (itemId != null && task == null)) return;
  final imagePaths = [
    if (itemId != null)
      for (final attachment in await attachments.forItem(itemId))
        if (attachment.kind == AttachmentKind.image)
          if (files.absolute(attachment.value) case final path?)
            if (sentImage(send.text, path)) path,
  ];
  final title = task?.title ?? send.firstLine;
  queue.start(
    id: send.id,
    itemId: itemId,
    title: title,
    target: choice.target,
    kind: choice.kind,
    run: launcherRun(
      (id) => sender(
        sendId: id,
        target: choice.target,
        itemId: itemId,
        title: title,
        links: const [],
        kind: choice.kind,
        message: sentMessage(send.text),
        imagePaths: imagePaths,
        model: choice.model,
      ),
    ),
  );
}

typedef _RowState = ({String label, Color color});

_RowState _rowState(BuildContext context, Dispatch send, String? live) {
  final tokens = context.tokens;
  return switch (send.status) {
    DispatchStatus.failed => (label: 'FAILED', color: tokens.danger),
    DispatchStatus.sending => (label: 'SENDING', color: tokens.textSecondary),
    DispatchStatus.sent
        when send.lastSeen == endedState || live == endedState =>
      (label: 'ENDED', color: tokens.textMuted),
    DispatchStatus.sent when live != null => (
      label: AgentState.of(live).label,
      color: agentStateColor(context, AgentState.of(live)),
    ),
    DispatchStatus.sent => (
      label: AgentState.of(send.lastSeen ?? 'sent').label,
      color: tokens.textDisabled,
    ),
  };
}

class SentScreen extends ConsumerWidget {
  const SentScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sends = ref.watch(sendsProvider);
    ref.watch(pathTargetsProvider);
    final feed = ref.watch(agentsFeedLiveProvider)
        ? ref.watch(agentsFeedProvider).valueOrNull
        : null;
    return Scaffold(
      body: StaticSurface(
        child: ScreenScaffold(
          title: 'SENT',
          breadcrumb: '/ STRIKED / AGENTS / SENT',
          onBack: () => Navigator.of(context).pop(),
          children: [
            Panel(
              title: 'SENDS',
              bodyPadding: panelRowsPadding,
              child: switch (sends) {
                AsyncValue(valueOrNull: final List<Dispatch> list)
                    when list.isNotEmpty =>
                  ListRowGroup(
                    children: [
                      for (final send in list)
                        _SentRow(
                          send,
                          live: feed == null ? null : paneStateOf(feed, send),
                        ),
                    ],
                  ),
                AsyncValue(hasValue: true) => const EmptyState('nothing sent'),
                AsyncValue(hasError: true) => const EmptyState(
                  'sends unreadable',
                ),
                _ => const EmptyState('loading'),
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _SentRow extends ConsumerWidget {
  const _SentRow(this.send, {required this.live});

  final Dispatch send;
  final String? live;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = _rowState(context, send, live);
    final failed = send.status == DispatchStatus.failed;
    return ListRow(
      title: send.firstLine.isEmpty ? '(empty)' : send.firstLine,
      subtitle:
          '${send.hostName} · ${path.basename(send.directory)} · ${send.agent}',
      caption: failed ? (send.failure ?? 'failed').toUpperCase() : null,
      valueSpans: [
        TextSpan(
          text: state.label,
          style: TextStyle(color: state.color),
        ),
        TextSpan(
          text: '  ${relativeAge(send.sentAt)}',
          style: TextStyle(color: context.tokens.textMuted),
        ),
      ],
      onTap: failed
          ? () => unawaited(retrySend(ref, send))
          : () => openRun(context, send.id),
      onLongPress: () => _actions(context, ref),
    );
  }

  Future<void> _sendAgain(BuildContext context, WidgetRef ref) async {
    final choice = await _choiceOf(ref, send);
    if (!context.mounted) return;
    await showCompose(context, text: send.text, choice: choice);
  }

  void _actions(BuildContext context, WidgetRef ref) {
    unawaited(
      showActionSheet(
        context,
        title: send.firstLine,
        recommendFirst: false,
        actions: [
          if (failed)
            SheetAction('RETRY', () => unawaited(retrySend(ref, send))),
          SheetAction('SEND AGAIN', () => unawaited(_sendAgain(context, ref))),
          SheetAction(
            'DELETE',
            () => unawaited(
              ref
                  .read(dispatchRepositoryProvider)
                  .delete(send.id)
                  .catchError(
                    (Object error) => debugPrint('striked.sent: $error'),
                  ),
            ),
            danger: true,
          ),
        ],
      ),
    );
  }

  bool get failed => send.status == DispatchStatus.failed;
}

class RunScreen extends ConsumerStatefulWidget {
  const RunScreen({super.key, required this.sendId});

  final String sendId;

  static const interval = Duration(seconds: 3);

  @override
  ConsumerState<RunScreen> createState() => _RunScreenState();
}

class _RunScreenState extends ConsumerState<RunScreen> {
  static const _pageLimit = 200;
  static const _pagesPerTick = 20;
  static const _kept = 400;

  late final EngineOpen _open = ref.read(engineOpenProvider);
  Future<EngineAgents>? _engine;
  Timer? _timer;
  late bool _visible = ref.read(appVisibleProvider);
  bool _onStage = true;
  bool _asking = false;
  bool _disposed = false;

  String? _key;
  AgentSnapshot? _session;
  bool _looked = false;
  final List<TranscriptItem> _items = [];
  bool _cut = false;
  int? _last;
  bool _noTranscript = false;
  bool _unnamed = false;
  bool _sessionGone = false;
  String? _failure;
  String? _answering;
  String? _answerLine;

  void _drop() {
    final engine = _engine;
    _engine = null;
    unawaited(
      engine?.then(
        (engine) => engine.session.close(),
        onError: (_) {
          // ignored: an engine that never opened has nothing to close
        },
      ),
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
    _timer = Timer.periodic(RunScreen.interval, (_) => _tick());
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _drop();
    super.dispose();
  }

  Future<void> _tick() async {
    if (_asking || _disposed || _sessionGone || _noTranscript) return;
    _asking = true;
    Host? host;
    try {
      final send = await ref.read(sendProvider(widget.sendId).future);
      if (_disposed || send == null || send.paneId == null) return;
      final integrations = await ref.read(
        hostIntegrationsProvider(send.hostId).future,
      );
      host = ref.read(registeredHostProvider(send.hostId));
      if (_disposed || host == null) return;
      if (!integrations.contains(IntegrationKind.agents)) return;
      final engine = await (_engine ??= _open(host));
      if (_disposed) return;
      final watched = await engine.watch();
      final key =
          _key ?? send.engineSession ?? await _match(engine, watched, send);
      if (_disposed || !mounted) return;
      if (key == null) {
        setState(() => _looked = true);
        return;
      }
      if (_key == null) {
        _key = key;
        if (send.engineSession != key) {
          unawaited(
            ref
                .read(dispatchRepositoryProvider)
                .linkSession(send.id, key)
                .catchError(
                  (Object error) => debugPrint('striked.sent: $error'),
                ),
          );
        }
      }
      final session = watched.agents
          .where((agent) => agent.paneId == key)
          .firstOrNull;
      final read = await _read(engine, key, listed: session != null);
      if (_disposed || !mounted) return;
      setState(() {
        _looked = true;
        _session = session;
        _last = read.last;
        _unnamed = read.unnamed;
        _keep(read.fresh);
        _failure = read.failure;
      });
    } catch (error) {
      final name = host?.name ?? 'host';
      debugPrint('striked.engine $name run: $error');
      _drop();
      if (_disposed || !mounted) return;
      setState(
        () => _failure = switch (error) {
          HerdrFailure() => error.line.on(name),
          EngineRefused() => error.kind.replaceAll('_', ' '),
          _ => 'failed',
        },
      );
    } finally {
      _asking = false;
    }
  }

  void _keep(List<TranscriptItem> fresh) {
    _items.addAll(fresh);
    if (_items.length > _kept) {
      _items.removeRange(0, _items.length - _kept);
      _cut = true;
    }
  }

  Future<String?> _match(
    EngineAgents engine,
    EngineWatch watched,
    Dispatch send,
  ) async {
    for (final agent in watched.agents) {
      if (agent.herdrPane != send.paneId || agent.agent != send.agent) continue;
      final TranscriptPage page;
      try {
        page = await engine.transcript(agent.paneId);
      } on EngineRefused catch (error) {
        if (error.kind == 'unsupported') _noTranscript = true;
        continue;
      }
      final first = firstPrompt(page.items);
      if (first == null || !promptMatches(first, send.text)) continue;
      _keep(page.items);
      _last = page.last;
      return agent.paneId;
    }
    return null;
  }

  Future<
    ({List<TranscriptItem> fresh, int? last, bool unnamed, String? failure})
  >
  _read(EngineAgents engine, String key, {required bool listed}) async {
    final fresh = <TranscriptItem>[];
    var last = _last;
    try {
      for (var page = 0; page < _pagesPerTick; page++) {
        final read = await engine.transcript(key, after: last);
        fresh.addAll(read.items);
        final done = read.last == last || read.items.length < _pageLimit;
        last = read.last;
        if (done) break;
      }
    } on EngineRefused catch (error) {
      _noTranscript = error.kind == 'unsupported';
      _sessionGone = error.notFound && !listed;
      final settled = error.notFound || _noTranscript;
      if (_sessionGone) _drop();
      return (
        fresh: fresh,
        last: last,
        unnamed: error.notFound && listed,
        failure: settled ? null : error.kind.replaceAll('_', ' '),
      );
    }
    return (fresh: fresh, last: last, unnamed: false, failure: null);
  }

  Future<void> _answer(
    Host host,
    AgentApproval approval, {
    required bool allow,
  }) async {
    setState(() {
      _answering = approval.id;
      _answerLine = null;
    });
    try {
      final engine = await (_engine ??= _open(host));
      await engine.answer(approval.id, allow: allow);
      if (mounted) setState(() => _answerLine = allow ? 'ALLOWED' : 'DENIED');
    } on EngineRefused catch (error) {
      if (mounted) {
        setState(
          () => _answerLine = error.notFound ? 'ALREADY ANSWERED' : 'REFUSED',
        );
      }
    } catch (error) {
      debugPrint('striked.engine ${host.name} answer: $error');
      if (mounted) setState(() => _answerLine = 'FAILED');
    } finally {
      if (mounted) setState(() => _answering = null);
    }
    unawaited(_tick());
  }

  @override
  Widget build(BuildContext context) {
    final send = ref.watch(sendProvider(widget.sendId)).valueOrNull;
    if (send == null) {
      return Scaffold(
        body: StaticSurface(
          child: ScreenScaffold(
            title: 'RUN',
            breadcrumb: '/ STRIKED / AGENTS / SENT',
            onBack: () => Navigator.of(context).pop(),
            children: const [Panel(child: EmptyState('no such send'))],
          ),
        ),
      );
    }
    final host = ref.watch(registeredHostProvider(send.hostId));
    final agentsOn = ref
        .watch(hostIntegrationsProvider(send.hostId))
        .valueOrNull
        ?.contains(IntegrationKind.agents);
    final feed = ref.watch(agentsFeedLiveProvider)
        ? ref.watch(agentsFeedProvider).valueOrNull
        : null;
    final live = feed == null ? null : paneStateOf(feed, send);
    final state = _rowState(context, send, live);
    final session = _session;
    final pane = switch ((send.herdrSession, send.paneId)) {
      (final String session, final String pane)
          when live != null && live != endedState =>
        (session: session, pane: pane),
      _ => null,
    };
    return Scaffold(
      bottomNavigationBar: host == null
          ? null
          : _bar(context, host, send, pane),
      body: StaticSurface(
        child: ScreenScaffold(
          title: send.firstLine.isEmpty ? 'RUN' : send.firstLine,
          breadcrumb: '/ STRIKED / AGENTS / SENT / ${send.firstLine}',
          onBack: () => Navigator.of(context).pop(),
          children: [
            PanelStack(
              children: [
                Panel(
                  title: 'PROMPT',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SelectableText(send.text, style: context.tokens.prose),
                      const SizedBox(height: Spacing.md),
                      _Field('TARGET', '${send.hostName} · ${send.directory}'),
                      _Field(
                        'AGENT',
                        [agentMarkName(send.agent), ?send.model].join(' · '),
                      ),
                      _Field(
                        'WENT',
                        '${timeOfDay(send.sentAt)} · ${relativeAge(send.sentAt)}',
                      ),
                      _Field('STATE', state.label, color: state.color),
                      if (send.failure != null)
                        _Field(
                          'REASON',
                          send.failure!,
                          color: context.tokens.danger,
                        ),
                      if (_failure != null)
                        _Field(
                          'LINK',
                          _failure!,
                          color: context.tokens.warning,
                        ),
                    ],
                  ),
                ),
                _steps(context, send, session, agentsOn),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _steps(
    BuildContext context,
    Dispatch send,
    AgentSnapshot? session,
    bool? agentsOn,
  ) {
    if (send.paneId == null) {
      return Panel(title: 'STEPS', child: _Timeline(send));
    }
    if (agentsOn == false) {
      return Panel(
        title: 'STEPS',
        child: _Timeline(
          send,
          why: 'NO STEPS · AGENTS IS OFF ON ${send.hostName.toUpperCase()}',
        ),
      );
    }
    if (_noTranscript) {
      return Panel(
        title: 'STEPS',
        child: _Timeline(
          send,
          why: 'NO STEPS · ${agentMarkName(send.agent)} KEEPS NO TRANSCRIPT',
        ),
      );
    }
    if (_sessionGone) {
      return Panel(title: 'SESSION GONE', child: _Timeline(send));
    }
    if (_items.isEmpty) {
      return Panel(
        title: 'STEPS',
        child: EmptyState(
          _unnamed
              ? 'no transcript yet'
              : _looked
              ? (_key == null ? 'no session yet' : 'nothing yet')
              : 'waiting for host',
        ),
      );
    }
    final ended = session == null || session.state.resting;
    final lines = runLines(
      _items,
      agent: send.agent,
      approval: session?.approval,
      ended: ended,
    );
    return Panel(
      title: 'STEPS',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_cut) const Meta('earlier lines cut'),
          for (final line in lines) _RunLineView(line),
        ],
      ),
    );
  }

  Widget? _bar(BuildContext context, Host host, Dispatch send, PaneRef? pane) {
    final session = _session;
    final approval = session?.approval;
    final key = _key;
    final conversation = key != null && !_sessionGone;
    if (approval == null && pane == null && !conversation) return null;
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
                          ? () => _answer(host, approval, allow: false)
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
                          ? () => _answer(host, approval, allow: true)
                          : null,
                    ),
                  ),
                ],
              ),
            ],
            Row(
              children: [
                if (pane != null)
                  Expanded(
                    child: PanelTextAction(
                      label: 'OPEN PANE',
                      icon: StrikedIcons.forward,
                      onTap: UserIntent.onGesture(
                        (intent) =>
                            openAgentPane(context, ref, host, pane, intent),
                      ),
                    ),
                  ),
                if (conversation)
                  Expanded(
                    child: PanelTextAction(
                      label: 'CONVERSATION',
                      icon: StrikedIcons.forward,
                      onTap: () => openAgentChat(
                        context,
                        host,
                        session ?? _snapshot(send, key),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static AgentSnapshot _snapshot(Dispatch send, String key) => AgentSnapshot(
    session: '',
    paneId: key,
    agent: send.agent,
    state: AgentState.of(send.lastSeen ?? 'done'),
    terminalTitleStripped: send.firstLine,
    workspaceId: '',
    cwd: send.directory,
    stateChangeSeq: 0,
    source: AgentSource.engine,
    herdrPane: send.paneId,
  );
}

class _Field extends StatelessWidget {
  const _Field(this.label, this.value, {this.color});

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

class _Timeline extends StatelessWidget {
  const _Timeline(this.send, {this.why});

  final Dispatch send;
  final String? why;

  @override
  Widget build(BuildContext context) {
    final failed = send.status == DispatchStatus.failed;
    final rows = <SeenState>[
      (
        state: switch (send.status) {
          DispatchStatus.sending => 'sending',
          DispatchStatus.sent => 'sent',
          DispatchStatus.failed => 'failed',
        },
        at: send.sentAt,
      ),
      if (!failed) ...send.states,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (why != null) Meta(why!, color: context.tokens.textMuted),
        for (final row in rows)
          _Field(
            timeOfDay(row.at),
            AgentState.of(row.state).label,
            color: row.state == 'failed' ? context.tokens.danger : null,
          ),
      ],
    );
  }
}

class _RunLineView extends StatefulWidget {
  const _RunLineView(this.line);

  final RunLine line;

  @override
  State<_RunLineView> createState() => _RunLineViewState();
}

class _RunLineViewState extends State<_RunLineView> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return switch (widget.line) {
      PromptLine(:final text) => Padding(
        padding: const EdgeInsets.only(top: Spacing.lg, bottom: Spacing.sm),
        child: Text(
          text,
          style: tokens.prose.copyWith(color: tokens.accent),
          maxLines: _open ? null : 3,
          overflow: _open ? null : TextOverflow.ellipsis,
        ),
      ),
      SaidLine(:final text, :final first) => _tappable(
        Text(
          _open ? text : first,
          style: tokens.value.copyWith(color: tokens.textMuted),
          maxLines: _open ? null : 1,
          overflow: _open ? null : TextOverflow.ellipsis,
        ),
      ),
      LastSaidLine(:final text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
        child: Text(
          text,
          style: tokens.prose.copyWith(color: tokens.textPrimary),
        ),
      ),
      final StepsLine steps => _tappable(
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _StepRow(
              glyph: steps.glyph,
              verb: steps.steps.length == 1
                  ? steps.verb
                  : '${steps.verb} ×${steps.steps.length}',
              argument: steps.steps.length == 1 || _open
                  ? steps.steps.first.argument
                  : '',
            ),
            if (_open && steps.steps.length > 1)
              for (final step in steps.steps.skip(1))
                _StepRow(glyph: step.glyph, verb: '', argument: step.argument),
          ],
        ),
        enabled: steps.steps.length > 1,
      ),
    };
  }

  Widget _tappable(Widget child, {bool enabled = true}) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: enabled ? () => setState(() => _open = !_open) : null,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
      child: child,
    ),
  );
}

class _StepRow extends StatelessWidget {
  const _StepRow({
    required this.glyph,
    required this.verb,
    required this.argument,
  });

  final StepGlyph glyph;
  final String verb;
  final String argument;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final color = switch (glyph) {
      StepGlyph.done => tokens.textMuted,
      StepGlyph.running => tokens.warning,
      StepGlyph.waiting => tokens.danger,
    };
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: TapTargets.minHeight),
      child: Row(
        children: [
          SizedBox(
            width: 16,
            child: Text(
              glyph.mark,
              style: tokens.valueStrong.copyWith(color: color),
            ),
          ),
          SizedBox(width: 88, child: Text(verb, style: tokens.label)),
          Expanded(
            child: Text(
              argument,
              style: tokens.value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
