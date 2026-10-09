import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/agents.dart';
import '../../application/agent_kind.dart';
import '../../application/clips.dart';
import '../../application/pin_alerts.dart';
import '../../application/providers.dart';
import '../../application/shell_font.dart';
import '../../application/whisper.dart';
import '../../data/repositories/host_repository.dart';
import '../../data/repositories/path_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../../design/effects/glitch.dart';
import '../../design/tokens.dart';
import '../../design/components/action_block.dart';
import '../../design/components/drag_sheet.dart';
import '../../design/components/field_panel.dart';
import '../../design/components/list_row.dart';
import '../../design/components/meta_row.dart';
import '../../design/components/panel_sheet.dart';
import '../../design/spacing.dart';
import '../../platform/herdr_client.dart';
import '../../platform/host_keys.dart';
import '../../platform/shell/shell_connection.dart';
import '../../platform/shell/shell_launch.dart';
import '../../platform/vnc/keysyms.dart';
import '../code/diff_sheet.dart';
import '../hosts/host_key_sheet.dart';
import 'attach_sheet.dart';
import 'shell_bar.dart';
import 'shell_header.dart';
import 'launch_picker_sheet.dart';
import 'shell_search.dart';
import 'shell_sessions.dart';
import 'shell_terminal.dart';
import 'shell_voice.dart';
import 'shell_watcher.dart';

class HostShellRoute extends ConsumerStatefulWidget {
  const HostShellRoute({
    super.key,
    required this.host,
    this.session,
    this.command,
    this.directory,
    this.pane,
    this.onSwitchHost,
    this.onOpenHost,
    this.openNew = false,
    this.openLaunch,
    this.intent,
  });

  final Host host;

  /// The tab to land on, or none — a host being taken over has no tab yet, and opens its
  /// first one where it arrives. Null where the shell is not in a sheet, which leaves the
  /// header's host name a label.
  final void Function(Host host, ShellSession? session)? onSwitchHost;

  final void Function(Host host, ShellLaunch? launch, UserIntent intent)?
  onOpenHost;

  /// Opens a fresh tab during this route's first frame even when the host already has
  /// sessions. Used after the sheet changes host through `+`.
  final bool openNew;

  final ShellLaunch? openLaunch;

  final ShellSession? session;

  final UserIntent? intent;

  final String? command;

  /// Where [command] leaves that tab standing, which is what the header's `DIFF` opens on
  /// until the shell says it has moved.
  final String? directory;

  final PaneRef? pane;

  @override
  ConsumerState<HostShellRoute> createState() => _HostShellRouteState();
}

class _HostShellRouteState extends ConsumerState<HostShellRoute> {
  /// The session whose view was drawn last, so a build that swaps the view for another
  /// tab's can be told from one that repaints the same tab.
  ShellSession? _shown;

  /// Tab numbers whose bad exit has already been put in front of the user. The header goes
  /// on saying `EXITED <code>` afterwards; the sheet is said once.
  final _announced = <int>{};

  /// True while the sheet is up, so a second exit waits its turn rather than landing on top
  /// of the first, and so the route is not popped out from under a modal that is still open.
  bool _announcing = false;

  /// The store is empty for the frame before the first shell opens, which is not the same
  /// emptiness as the last tab going.
  bool _opened = false;

  /// The size the fingers started from, for the length of one pinch: the scale is against
  /// where they began, so it applies to this and not to the last frame's result.
  double? _pinchBase;

  /// The size drawn from the first movement of a pinch until the settings stream has caught
  /// up with the write. The write is a database round trip behind the lift, and the view
  /// must not snap back in between.
  double? _pinched;

  @override
  void initState() {
    super.initState();
    // Held rather than read where it is used: `ref` is closed by the time dispose
    // runs, and this is the store the listener has to come off.
    _store = ref.read(shellSessionsProvider);
    _store.addListener(_onStore);
    // Both notifiers: the strip is drawn from the set, and the header, the exit
    // sheet and the pop that follows the last tab are all drawn from what the tabs
    // themselves report.
    _follower = ShellFollower(
      store: _store,
      watch: (store) => store.forHost(widget.host.id),
      onChange: _onSessions,
    );
    _view = ShellFollower(
      store: _store,
      watch: (store) {
        final active = store.activeFor(widget.host.id);
        return active == null ? const [] : [active];
      },
      onChange: _onView,
    );
    _clips = ref.read(clipStoreProvider);
    _clips.addListener(_onClips);
    _dictation = ShellDictation(
      onWords: _onWords,
      whisper: ref.read(whisperProvider),
    )..addListener(_onDictation);
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    // Opening a session tells the store, and the screen the user came from is
    // listening to it while it draws this route in. So the shell waits for the frame
    // that pushed it to finish before it exists.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final sessions = ref.read(shellSessionsProvider);
      final wanted = widget.session;
      final command = widget.command;
      final canOpen = sessions.canOpen(widget.host.id);
      // A commanded open is a tab of its own even when the host has some: the
      // caller asked for one directory or agent, not whatever tab was last active.
      final commanded = command != null && canOpen;
      final fresh = !commanded && widget.openNew && canOpen;
      if (wanted != null) {
        sessions.activate(widget.host.id, wanted);
      } else if (commanded ||
          fresh ||
          sessions.forHost(widget.host.id).isEmpty) {
        if (widget.intent case final intent?) {
          sessions.open(
            widget.host,
            intent: intent,
            prompt: _askHostKey,
            command: commanded ? command : null,
            directory: commanded ? widget.directory : null,
            pane: commanded ? widget.pane : null,
            launch: fresh ? widget.openLaunch : null,
          );
        }
      }
      // Landing on tabs that were already there tells the store nothing, so no drain
      // would ever see them.
      if (sessions.forHost(widget.host.id).isNotEmpty) _opened = true;
    });
  }

  @override
  void dispose() {
    _voiceSendSuggestionTimer?.cancel();
    _voiceSendSuggestion?.voiceSendSuggested = false;
    _follower.dispose();
    _view.dispose();
    _store.removeListener(_onStore);
    _clips.removeListener(_onClips);
    _dictation
      ..removeListener(_onDictation)
      ..dispose();
    _voiceLanding.dispose();
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
    super.dispose();
  }

  late final ShellSessions _store;
  late final ShellFollower _follower;
  late final ShellFollower _view;
  Object? _drawn;

  late final ClipStore _clips;

  late final ShellDictation _dictation;

  final _voiceLanding = GlitchController();

  ShellSession? _voiceSendSuggestion;
  Timer? _voiceSendSuggestionTimer;
  final _checkingTypedSend = <ShellSession>{};

  var _searching = false;

  /// The request the sheet is up for, so a `done` from the host can take the sheet down and
  /// nothing else can.
  ({ShellSession session, String id})? _pinShown;
  BuildContext? _pinSheet;

  /// A request the user swiped off the phone. It stays open on the computer and is not put
  /// back in front of them unless they ask through the header; the next id is a new request.
  String? _pinDismissed;

  PinRequest? _swipedPin() {
    if (_pinShown != null || _pinDismissed == null) return null;
    for (final session in _store.forHost(widget.host.id)) {
      final request = session.pin;
      if (request?.id == _pinDismissed && session.state is ShellLive) {
        return request;
      }
    }
    return null;
  }

  void _onPinReopen() {
    setState(() => _pinDismissed = null);
    unawaited(_askPins());
  }

  void _onClips() {
    if (mounted) setState(() {});
  }

  void _onDictation() {
    if (mounted) setState(() {});
  }

  void _onWords(ShellSession session, String words) {
    _voiceLanding.fire();
    final draft = session.voiceDraft;
    final agent = draft?.agent ?? shellAgent(session, _agentsOn(session.host));
    if (agent == null) {
      session.terminal.paste(words);
      if (session.state is ShellLive) _suggestVoiceSend(session);
      return;
    }
    if (!mounted) return;
    setState(() {
      session.voiceDraft = (
        agent: agent,
        text: appendWords(draft?.text ?? '', words),
      );
    });
    _suggestVoiceSend(session);
  }

  void _suggestVoiceSend(ShellSession session) {
    if (_voiceSendSuggestion case final previous?) {
      previous.voiceSendSuggested = false;
    }
    _voiceSendSuggestionTimer?.cancel();
    _voiceSendSuggestion = session;
    session.voiceSendSuggested = true;
    if (session.voiceDraft == null) {
      _voiceSendSuggestionTimer = Timer(const Duration(seconds: 30), () {
        if (!mounted || _voiceSendSuggestion != session) return;
        session.voiceSendSuggested = false;
        _voiceSendSuggestionTimer = null;
        setState(() => _voiceSendSuggestion = null);
      });
    }
    if (mounted) setState(() {});
  }

  void _clearVoiceSendSuggestion(ShellSession session) {
    if (_voiceSendSuggestion != session) return;
    _voiceSendSuggestionTimer?.cancel();
    _voiceSendSuggestionTimer = null;
    session.voiceSendSuggested = false;
    setState(() => _voiceSendSuggestion = null);
  }

  AgentKind? _typedAgent(ShellSession session) {
    if (!session.typedSendReady || !session.agentInput.hasText) return null;
    if (session.pane != null) {
      return paneAgent(session, _freshAgentsOn(session.host));
    }
    if (session.connection?.transport == ShellTransport.engine &&
        session.engineForegroundKnown) {
      return session.engineAgent;
    }
    return session.probedAgent;
  }

  Future<void> _onSendSuggestion(ShellSession session) async {
    if (_dictation.hearing || session.state is! ShellLive) return;
    if (session.voiceDraft != null) {
      _onDraftSend(session);
      return;
    }
    final typed = _typedAgent(session);
    if (typed != null) {
      if (!_checkingTypedSend.add(session)) return;
      final revision = session.agentInputRevision;
      final connection = session.connection;
      setState(() {});
      try {
        final current = session.pane == null
            ? await _store.agentFromHost(session)
            : await _store.agentFromPane(session);
        if (!mounted ||
            session.state is! ShellLive ||
            !identical(session.connection, connection) ||
            session.agentInputRevision != revision) {
          return;
        }
        if (current?.name != typed.name || !session.agentInput.hasText) {
          session.clearAgentInput();
          return;
        }
        session.clearAgentInput();
        _clearVoiceSendSuggestion(session);
        _store.send(session, Uint8List.fromList(const [0x0d]));
      } finally {
        _checkingTypedSend.remove(session);
        if (mounted) setState(() {});
      }
      return;
    }
    if (_voiceSendSuggestion == session && session.voiceSendSuggested) {
      _clearVoiceSendSuggestion(session);
      _store.send(session, Uint8List.fromList(const [0x0d]));
    }
  }

  Iterable<AgentSnapshot> _agentsOn(Host host) sync* {
    final state = ref.read(agentsFeedProvider).valueOrNull;
    if (state == null) return;
    for (final outcome in state.outcomes) {
      if (outcome.host.id == host.id) yield* outcome.agents;
    }
  }

  Iterable<AgentSnapshot> _freshAgentsOn(Host host) sync* {
    if (!ref.exists(agentsFeedProvider)) return;
    final state = ref.read(agentsFeedProvider).valueOrNull;
    if (state == null) return;
    final now = DateTime.now();
    for (final outcome in state.outcomes) {
      final at = outcome.lastGoodAt;
      if (outcome.host.id == host.id &&
          outcome.ok &&
          at != null &&
          now.difference(at) <= const Duration(seconds: 15)) {
        yield* outcome.agents;
      }
    }
  }

  void _onDraftEdit(ShellSession session, String text) {
    final draft = session.voiceDraft;
    if (draft == null) return;
    final wasEmpty = draft.text.trim().isEmpty;
    session.voiceDraft = (agent: draft.agent, text: text);
    if (wasEmpty != text.trim().isEmpty) setState(() {});
  }

  void _onDraftCancel(ShellSession session) {
    _clearVoiceSendSuggestion(session);
    setState(() => session.voiceDraft = null);
  }

  void _onDraftSend(ShellSession session) {
    final text = session.voiceDraft?.text.trim() ?? '';
    if (text.isEmpty) return;
    _clearVoiceSendSuggestion(session);
    setState(() => session.voiceDraft = null);
    unawaited(sendDraft(session, text, (bytes) => _store.send(session, bytes)));
  }

  void _onStore() {
    if (mounted) setState(() {});
  }

  void _onView() {
    if (!mounted || _drawnFrom(_store.activeFor(widget.host.id)) == _drawn) {
      return;
    }
    setState(() {});
  }

  /// Everything the route draws from the active tab but its title, which only the header
  /// shows, and the header follows every tab on its own.
  Object? _drawnFrom(ShellSession? session) => session == null
      ? null
      : (
          session,
          session.state,
          session.connection,
          session.repository,
          session.cwd,
          StickyModifier.values.where(session.sticky.contains).join(),
          session.stickyRepeat,
          session.stickyLocked,
        );

  void _onSessions() {
    if (!mounted) return;
    if (_dictation.session?.retired ?? false) _dictation.cancel();
    _withdrawPin();
    if (_pinShown == null) unawaited(_askPins());
    if (_announcing) return;
    unawaited(_drain());
  }

  Future<void> _drain() async {
    _announcing = true;
    try {
      while (mounted) {
        final sessions = _store.forHost(widget.host.id);
        if (sessions.isNotEmpty) _opened = true;
        final ended = _nextBadExit(sessions);
        if (ended == null) break;
        _announced.add(ended.number);
        final state = ended.state as ShellExited;
        final close = await _exitSheet(ended.number, state.code);
        if (!mounted) return;
        if (close != null) {
          await _store.close(widget.host.id, ended, intent: close);
        }
      }
      if (!mounted) return;
      if (_opened && _store.forHost(widget.host.id).isEmpty) {
        Navigator.of(context).pop();
      }
    } finally {
      _announcing = false;
    }
  }

  /// Takes the sheet down when the request it was up for is gone: answered on the computer,
  /// given up on by the agent, replaced, or lost with the link.
  void _withdrawPin() {
    final shown = _pinShown;
    if (shown == null || shown.session.pin?.id == shown.id) return;
    final sheet = _pinSheet;
    if (sheet == null || !sheet.mounted) return;
    // A sheet that popped itself is still mounted for its way out, and the request
    // it answered is gone by then: a second pop would take the route under it.
    if (ModalRoute.of(sheet)?.isActive != true) return;
    Navigator.of(sheet).pop();
  }

  /// One sheet at a time, as the exit sheets are. The sheet coming down on its own —
  /// `done`, a swipe — sends nothing; only a tap on one of its blocks reaches the host.
  Future<void> _askPins() async {
    while (mounted) {
      final session = _nextPin(_store.forHost(widget.host.id));
      final request = session?.pin;
      if (session == null || request == null) break;
      _pinShown = (session: session, id: request.id);
      // Nothing reconnects under the sheet: the request belongs to this session's
      // shell, and a redial would take that shell away from the answer the user is
      // typing.
      final release = _store.hold();
      PinAnswer? outcome;
      try {
        final answer = await _pinSheetFor(session, request);
        if (!mounted) return;
        if (answer == null) {
          _pinDismissed = request.id;
        } else if (session.pin?.id == request.id) {
          outcome = await _store.answerPin(
            session,
            answer.passphrase,
            answer.intent,
          );
        }
      } finally {
        release();
        _pinShown = null;
        _pinSheet = null;
      }
      if (!mounted) return;
      setState(() {});
      if (outcome == PinAnswer.expired) {
        await _expiredSheet(session.number);
        if (!mounted) return;
      }
    }
  }

  /// The tab on screen first: under Mosh every tab of the host hears the same bell, and the
  /// sheet names the shell the user is looking at. Then any other live tab, in order.
  ShellSession? _nextPin(List<ShellSession> sessions) {
    final onScreen = _store.activeFor(widget.host.id);
    for (final session in [?onScreen, ...sessions]) {
      final request = session.pin;
      if (request == null || session.state is! ShellLive) continue;
      if (request.id == _pinDismissed) continue;
      return session;
    }
    return null;
  }

  Future<_PinDecision?> _pinSheetFor(ShellSession session, PinRequest request) {
    const title = 'AUTHORIZATION REQUIRED';
    return showPanelSheet<_PinDecision>(
      context,
      title: title,
      builder: (context) {
        _pinSheet = context;
        // The sheet names the tab on screen once that tab holds the same request,
        // which under Mosh it does a moment after the first tab. A tab taking a
        // request is the tab's own news, not the store's, so the label follows
        // every tab of the host.
        return PanelSheetBody(
          title: title,
          children: [
            ShellWatcher(
              store: _store,
              watch: (store) => store.forHost(widget.host.id),
              builder: (_) => _PinSheet(
                number: _pinTab(session, request),
                request: _pinHeld(session, request),
              ),
            ),
          ],
        );
      },
    );
  }

  int _pinTab(ShellSession session, PinRequest request) {
    final onScreen = _store.activeFor(widget.host.id);
    if (onScreen != null && onScreen.pin?.id == request.id) {
      return onScreen.number;
    }
    return session.number;
  }

  /// The ask as a tab holds it now, rather than as it was when the sheet went up: the same
  /// id grows old where it stands. Falls back to the one the sheet was raised with once no
  /// tab holds it, which is the moment the sheet is on its way down.
  PinRequest _pinHeld(ShellSession session, PinRequest request) {
    for (final other in [session, ..._store.forHost(widget.host.id)]) {
      final held = other.pin;
      if (held != null && held.id == request.id) return held;
    }
    return request;
  }

  /// The host had taken the ask down before the passphrase left, so nothing was written and
  /// nothing is waiting on it.
  Future<void> _expiredSheet(int number) async {
    const title = 'AUTHORIZATION EXPIRED';
    await showPanelSheet<void>(
      context,
      title: title,
      builder: (context) => PanelSheetBody(
        title: title,
        children: [
          Text('SHELL $number', style: context.tokens.label),
          const SizedBox(height: Spacing.sm),
          Text(
            'The host had already taken this ask down, so nothing reached it. '
            'If the key is still wanted the ask comes again.',
            style: context.tokens.prose,
          ),
          const SizedBox(height: Spacing.md),
          Row(
            children: [
              Expanded(
                child: ActionBlock(
                  label: 'CLOSE',
                  onTap: () => Navigator.of(context).pop(),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  ShellSession? _nextBadExit(List<ShellSession> sessions) {
    for (final session in sessions) {
      final state = session.state;
      if (state is! ShellExited || state.code == shellCleanExit) continue;
      if (_announced.contains(session.number)) continue;
      return session;
    }
    return null;
  }

  Future<UserIntent?> _exitSheet(int number, int? code) {
    final title = 'SHELL $number EXITED ${code ?? '—'}';
    return showPanelSheet<UserIntent>(
      context,
      title: title,
      builder: (context) => PanelSheetBody(
        title: title,
        children: [
          Row(
            children: [
              Expanded(
                child: ActionBlock(
                  label: 'CLOSE',
                  onTap: UserIntent.onGesture(
                    (intent) => Navigator.of(context).pop(intent),
                  ),
                ),
              ),
              const SizedBox(width: Spacing.md),
              Expanded(
                child: ActionBlock(
                  label: 'KEEP',
                  tone: context.tokens.accent,
                  filled: true,
                  onTap: () => Navigator.of(context).pop(),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  List<(Host, List<ShellSession>)> _groups(ShellSessions store) => [
    for (final (host, sessions) in store.openHosts)
      if (widget.onSwitchHost != null || host.id == widget.host.id)
        (host, sessions),
  ];

  /// Whether the IME is up: an inset the system reports *and* a view focused to have raised
  /// it. Neither alone is the answer. Focus alone parts company with the truth when the
  /// system back button hides the keyboard, which leaves the focus where it was. The inset
  /// alone parts company with it when the window comes back from a stop with the keyboard's
  /// inset standing and no keyboard under it.
  bool _keyboardUp(ShellSession session) =>
      MediaQuery.viewInsetsOf(context).bottom > 0 && session.focusNode.hasFocus;

  void _onFind() {
    setState(() => _searching = !_searching);
  }

  void _onKeyboard(ShellSession session) {
    final focus = session.focusNode;
    if (_keyboardUp(session)) {
      focus.unfocus();
    } else if (focus.hasFocus) {
      // Focus the view already has cannot be asked for again, so the keyboard the
      // system took away is asked back directly.
      SystemChannels.textInput.invokeMethod<void>('TextInput.show');
    } else {
      focus.requestFocus();
      scheduleMicrotask(
        () => SystemChannels.textInput.invokeMethod<void>('TextInput.show'),
      );
    }
  }

  void _onSticky(
    ShellSession session,
    Set<StickyModifier> sticky,
    int repeat,
    bool locked,
  ) {
    _store.arm(session, sticky, repeat: repeat, locked: locked);
  }

  void _onBytes(ShellSession session, Uint8List bytes) {
    if (clearsVoiceSendSuggestion(bytes)) {
      _clearVoiceSendSuggestion(session);
    }
    _store.send(session, bytes);
  }

  void _onSelect(Host host, ShellSession session) {
    if (host.id == widget.host.id) {
      _store.activate(host.id, session);
      return;
    }
    widget.onSwitchHost?.call(host, session);
  }

  /// Called from build with the tab about to be drawn. When it is not the one drawn last,
  /// the view under the old tab is on its way out and its focus node goes with it: a node
  /// detached while it holds focus gives it up, which is what takes the keyboard down. With
  /// the keyboard up the user is mid-typing, so it is put back on the tab they landed on.
  void _follow(ShellSession? active) {
    final shown = _shown;
    if (identical(shown, active)) return;
    _shown = active;
    if (active == null || shown == null || !shown.focusNode.hasFocus) return;
    // After the frame: the new view has to be in the tree for its node to take
    // focus, and the old one has to be out of it for its node to let go.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!identical(_store.activeFor(widget.host.id), active)) return;
      active.focusNode.requestFocus();
    });
  }

  void _onNew(Host host) => unawaited(
    showLaunchPicker(
      context,
      host,
      onPick: (intent, launch) {
        if (!mounted) return;
        if (host.id == widget.host.id) {
          if (!_store.canOpen(host.id)) return;
          _store.open(
            widget.host,
            intent: intent,
            prompt: _askHostKey,
            launch: launch,
          );
          return;
        }
        widget.onOpenHost?.call(host, launch, intent);
      },
    ),
  );

  List<({String directory, String label})> _diffTargets() {
    final groups =
        ref.watch(workspacesByHostProvider).valueOrNull ??
        const <HostWorkspaces>[];
    return [
      for (final group in groups)
        if (group.host.id == widget.host.id)
          for (final path in group.paths)
            (directory: path.directory, label: path.label),
    ];
  }

  /// The directory each tab's checkout was last asked about, under the tab's own mark, which
  /// no two tabs share and no tab changes. Dropped when the connection goes, so a reconnect
  /// asks again.
  final _asked = <String, String?>{};

  /// Asked once per place: a tab that says it has moved is asked again, and the answer is
  /// written back so the rebuild it causes is not a second question.
  void _askRepository(ShellSession? session) {
    if (session == null) return;
    if (session.connection == null) {
      _asked.remove(session.mark);
      return;
    }
    final mark = session.mark;
    if (_asked.containsKey(mark) && _asked[mark] == session.cwd) return;
    _asked[mark] = session.cwd;
    unawaited(
      _store
          .repositoryFromHost(session)
          .then(
            (_) {
              if (mounted) _asked[mark] = session.cwd;
            },
            onError: (Object error, StackTrace stack) {
              if (!isHostFailure(error) && !isKeyFailure(error)) {
                Error.throwWithStackTrace(error, stack);
              }
              debugPrint(
                'upgrade.shell ${widget.host.name}: repository: $error',
              );
            },
          ),
    );
  }

  Future<void> _onDiff(
    ShellSession? active,
    List<({String directory, String label})> targets,
  ) async {
    if (active != null) {
      try {
        await _store.repositoryFromHost(active);
      } catch (error) {
        if (!isHostFailure(error) && !isKeyFailure(error)) rethrow;
        debugPrint(
          'upgrade.shell ${widget.host.name}: diff repository: $error',
        );
      }
    }
    if (!mounted) return;
    final directory =
        active?.repository ??
        (targets.length == 1
            ? targets.first.directory
            : await _pickWorkspace(targets));
    if (!mounted || directory == null) return;
    await showDiffSheetAt(context, widget.host, directory);
  }

  Future<String?> _pickWorkspace(
    List<({String directory, String label})> targets,
  ) {
    const title = 'DIFF';
    return showPanelSheet<String>(
      context,
      title: title,
      builder: (context) => PanelSheetBody(
        title: title,
        children: [
          ListRowGroup(
            children: [
              for (final target in targets)
                ListRow(
                  key: ValueKey('shell-diff-${target.directory}'),
                  title: target.label.toUpperCase(),
                  subtitle: shortPathLabel(target.directory),
                  onTap: () => Navigator.of(context).pop(target.directory),
                ),
            ],
          ),
        ],
      ),
    );
  }

  double get _fontSize =>
      _pinched ??
      ref.read(shellFontSizeProvider).valueOrNull ??
      shellFontSizeDefault;

  void _onPinchStart(ScaleStartDetails _) {
    _pinchBase = _fontSize;
  }

  /// Two fingers or nothing: the recognizer also reports a one-finger drag it happened to
  /// win, and that is a scroll the terminal did not get, not a resize.
  void _onPinchUpdate(ScaleUpdateDetails details) {
    final base = _pinchBase;
    if (base == null || details.pointerCount < 2) return;
    final next = pinchedFontSize(base, details.scale);
    if (next == _pinched) return;
    setState(() => _pinched = next);
  }

  /// The write happens on the lift, once, rather than on every frame of the pinch: the row
  /// is one number, and the stream behind every other shell tab does not need forty of them.
  void _onPinchEnd(ScaleEndDetails _) {
    _pinchBase = null;
    final size = _pinched;
    if (size == null) return;
    unawaited(
      ref
          .read(settingsRepositoryProvider)
          .setNumber(SettingsRepository.shellFontSize, size),
    );
  }

  /// The route is in front of the user, so a machine that has never been connected to is
  /// asked about rather than refused. The dial is waiting on this future inside the
  /// handshake.
  Future<bool> _askHostKey(HostKeyOffer offer, PinnedHostKey? pinned) async {
    if (!mounted) return false;
    final release = _store.hold();
    try {
      return await askHostKey(
        context,
        host: widget.host,
        offer: offer,
        pinned: pinned,
      );
    } finally {
      release();
    }
  }

  Future<void> _onClose(UserIntent intent, ShellSession session) async {
    // A live shell is a thing with state in it — a job running, an editor with an
    // unsaved buffer — so closing one is asked about.
    if (session.state is ShellLive) {
      final title = 'CLOSE SHELL ${session.number}?';
      await showPanelSheet<bool>(
        context,
        title: title,
        builder: (_) => ConfirmSheetBody(
          title: title,
          confirmLabel: 'CLOSE',
          onConfirm: UserIntent.onGesture((confirm) {
            if (!mounted) return;
            unawaited(_store.close(widget.host.id, session, intent: confirm));
          }),
        ),
      );
      return;
    }
    // The pop belongs to the store's listener, which is the one path every way of
    // losing the last tab goes through.
    await _store.close(widget.host.id, session, intent: intent);
  }

  @override
  Widget build(BuildContext context) {
    final store = ref.watch(shellSessionsProvider);
    if (ref.exists(agentsFeedProvider)) ref.watch(agentsFeedProvider);
    final persisted =
        ref.watch(shellFontSizeProvider).valueOrNull ?? shellFontSizeDefault;
    // The pinched size is let go the moment the row says the same thing, so a
    // change written from another tab is drawn here too.
    ref.listen(shellFontSizeProvider, (_, next) {
      if (_pinched != null && next.valueOrNull == _pinched) {
        setState(() => _pinched = null);
      }
    });
    final fontSize = _pinched ?? persisted;
    return Scaffold(
      backgroundColor: context.tokens.mediaBackdrop,
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: Builder(
          builder: (context) {
            final active = store.activeFor(widget.host.id);
            _drawn = _drawnFrom(active);
            final registered =
                ref.watch(hostsProvider).valueOrNull ?? const <Host>[];
            final known = {
              for (final host in registered) host.id: host,
              widget.host.id: widget.host,
            };
            final newHosts = [
              for (final host in known.values)
                if (store.canOpen(host.id) &&
                    (host.id == widget.host.id || widget.onOpenHost != null))
                  host,
            ];
            _follow(active);
            final state = active?.state;
            final diffTargets = _diffTargets();
            _askRepository(active);
            return Column(
              children: [
                SheetGrip(
                  key: const ValueKey('shell-grip'),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ShellWatcher(
                        store: store,
                        watch: (store) => [
                          for (final (_, sessions) in _groups(store))
                            ...sessions,
                        ],
                        builder: (context) {
                          final swiped = _swipedPin();
                          return ShellHeader(
                            host: widget.host,
                            groups: _groups(store),
                            active: active,
                            newHosts: newHosts,
                            folded: (host) => store.isFolded(host.id),
                            onSelect: _onSelect,
                            onFold: (host) => store.fold(
                              host.id,
                              folded: !store.isFolded(host.id),
                            ),
                            onMoveTab: (host, from, to) =>
                                store.moveTab(host.id, from, to),
                            onMoveGroup: store.moveGroup,
                            onNew: _onNew,
                            onClose: active == null
                                ? null
                                : UserIntent.onGesture(
                                    (intent) => _onClose(intent, active),
                                  ),
                            onDiff:
                                diffTargets.isEmpty &&
                                    active?.connection == null
                                ? null
                                : () => _onDiff(active, diffTargets),
                            diffReady:
                                active?.repository != null ||
                                diffTargets.isNotEmpty,
                            onStop: active == null
                                ? null
                                : () => store.stopReconnect(active),
                            onReconnect: active == null
                                ? null
                                : UserIntent.onGesture(
                                    (intent) => unawaited(
                                      store.reconnectControl(
                                        active,
                                        UserAction(intent),
                                      ),
                                    ),
                                  ),
                            onPin: swiped == null ? null : _onPinReopen,
                            pinStale: swiped?.stale ?? false,
                          );
                        },
                      ),
                      if (state?.failure case final failure?)
                        ShellReasonRow(
                          host: widget.host,
                          kind: failure.kind,
                          detail: failure.detail,
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: active == null
                            ? const SizedBox.shrink()
                            : RawGestureDetector(
                                key: const ValueKey('shell-pinch'),
                                gestures: {
                                  ShellResizeGestureRecognizer:
                                      GestureRecognizerFactoryWithHandlers<
                                        ShellResizeGestureRecognizer
                                      >(
                                        ShellResizeGestureRecognizer.new,
                                        (recognizer) => recognizer
                                          ..onStart = _onPinchStart
                                          ..onUpdate = _onPinchUpdate
                                          ..onEnd = _onPinchEnd,
                                      ),
                                },
                                child: ShellTerminalView(
                                  session: active,
                                  fontSize: fontSize,
                                ),
                              ),
                      ),
                      if (_dictation.showing)
                        Positioned.fill(
                          child: VoiceFloat(dictation: _dictation),
                        ),
                    ],
                  ),
                ),
                if (active != null && _searching)
                  ShellSearchRow(
                    session: active,
                    onClose: () => setState(() => _searching = false),
                  ),
                if (active?.voiceDraft case final draft?)
                  VoiceComposer(
                    key: ValueKey('shell-voice-composer-${active!.mark}'),
                    draft: draft,
                    onEdit: (text) => _onDraftEdit(active, text),
                    onCancel: () => _onDraftCancel(active),
                    onSend: () => _onDraftSend(active),
                  ),
                if (active != null)
                  // The lamp answers the same question the tap does, so it is rebuilt
                  // on the focus that question reads and not only on the inset: a lit
                  // key over a keyboard that is not there is how the jam looked before
                  // the tap converged.
                  ListenableBuilder(
                    listenable: Listenable.merge([active.focusNode, active]),
                    builder: (context, _) => ShellBar(
                      sticky: active.sticky,
                      repeat: active.stickyRepeat,
                      locked: active.stickyLocked,
                      onSticky: (sticky, repeat, locked) =>
                          _onSticky(active, sticky, repeat, locked),
                      onBytes: (bytes) => _onBytes(active, bytes),
                      keyboardOpen: _keyboardUp(active),
                      onKeyboard: () => _onKeyboard(active),
                      clipCount: _clips.count,
                      searching: _searching,
                      onFind: _onFind,
                      onAttach: () => showAttachSheet(context, session: active),
                      dictation: _dictation,
                      voiceLanding: _voiceLanding,
                      onVoicePress: () => unawaited(_dictation.press(active)),
                      onVoiceLift: _dictation.lift,
                      onVoiceDrop: _dictation.cancel,
                      onSend:
                          !_dictation.hearing &&
                              active.state is ShellLive &&
                              !_checkingTypedSend.contains(active) &&
                              ((active.voiceDraft?.text.trim().isNotEmpty ??
                                      false) ||
                                  (_voiceSendSuggestion == active &&
                                      active.voiceSendSuggested) ||
                                  _typedAgent(active) != null)
                          ? () => unawaited(_onSendSuggestion(active))
                          : null,
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

typedef _PinDecision = ({String? passphrase, UserIntent intent});

class _PinSheet extends StatefulWidget {
  const _PinSheet({required this.number, required this.request});

  final int number;
  final PinRequest request;

  @override
  State<_PinSheet> createState() => _PinSheetState();
}

class _PinSheetState extends State<_PinSheet> {
  final _field = TextEditingController();

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _decide(UserIntent intent, String? passphrase) =>
      Navigator.of(context).pop((passphrase: passphrase, intent: intent));

  @override
  Widget build(BuildContext context) {
    final request = widget.request;
    final wantsPin = request.mode == 'pin';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('SHELL ${widget.number}', style: context.tokens.label),
        if (request.desc.isNotEmpty) ...[
          const SizedBox(height: Spacing.sm),
          if (pinFacts(request.desc) case final parsed?) ...[
            Text(parsed.lead, style: context.tokens.prose),
            const SizedBox(height: Spacing.sm),
            for (final (label, value) in parsed.facts)
              MetaRow(label, value, maxLines: 2),
          ] else
            Text(request.desc, style: context.tokens.prose),
        ],
        if (request.error.isNotEmpty) ...[
          const SizedBox(height: Spacing.sm),
          Text(
            request.error,
            style: context.tokens.prose.copyWith(color: context.tokens.danger),
          ),
        ],
        // The host gives up on an ask after a window of its own and never says how
        // long that is, so an ask this old is drawn as one that may be over rather
        // than as one that is: it was listed open a moment ago.
        if (request.stale) ...[
          const SizedBox(height: Spacing.sm),
          Text(
            'MAY HAVE EXPIRED',
            style: context.tokens.label.copyWith(color: context.tokens.warning),
          ),
        ],
        const SizedBox(height: Spacing.md),
        if (wantsPin) ...[
          FieldPanel(
            label: request.promptLabel,
            controller: _field,
            obscureText: true,
            autofocus: true,
            textInputAction: TextInputAction.done,
            onSubmitted: UserIntent.onGestureWith(_decide),
          ),
          const SizedBox(height: Spacing.md),
        ],
        Row(
          children: [
            if (request.mode != 'message') ...[
              Expanded(
                child: ActionBlock(
                  label: request.cancelLabel,
                  onTap: UserIntent.onGesture(
                    (intent) => _decide(intent, null),
                  ),
                ),
              ),
              const SizedBox(width: Spacing.md),
            ],
            Expanded(
              child: ActionBlock(
                label: request.okLabel,
                tone: context.tokens.accent,
                filled: !request.stale,
                onTap: UserIntent.onGesture(
                  (intent) => _decide(intent, wantsPin ? _field.text : 'ok'),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
