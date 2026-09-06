import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/clips.dart';
import '../../application/providers.dart';
import '../../application/shell_font.dart';
import '../../data/repositories/host_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../../design/colors.dart';
import '../../design/components/action_block.dart';
import '../../design/components/list_row.dart';
import '../../design/components/panel_sheet.dart';
import '../../design/spacing.dart';
import '../../platform/host_keys.dart';
import '../../platform/vnc/keysyms.dart';
import '../hosts/host_key_sheet.dart';
import 'attach_sheet.dart';
import 'shell_bar.dart';
import 'shell_header.dart';
import 'shell_selection.dart';
import 'shell_sessions.dart';
import 'shell_status.dart';
import 'shell_terminal.dart';
import 'shell_watcher.dart';

/// `/ <HOST> SHELL`: the host's own login shell, several at once as tabs.
///
/// The sessions are not here. They live in the store, which outlives every
/// visit — leaving and coming back finds the tabs where they were, still
/// running, so this route's dispose closes nothing but the orientation lock.
class HostShellRoute extends ConsumerStatefulWidget {
  const HostShellRoute({
    super.key,
    required this.host,
    this.session,
    this.seed,
    this.onSwitchHost,
  });

  final Host host;

  /// How the shell hands the sheet another host to hold. Null where the shell
  /// is not in a sheet, which leaves the header's host name a label.
  final void Function(Host host, ShellSession session)? onSwitchHost;

  /// The tab to land on, when the way in named one. Null opens the host's last
  /// active tab, or its first shell when there is none.
  final ShellSession? session;

  /// A line typed into a fresh tab as it comes up.
  final String? seed;

  @override
  ConsumerState<HostShellRoute> createState() => _HostShellRouteState();
}

class _HostShellRouteState extends ConsumerState<HostShellRoute> {
  /// The session whose view was drawn last, so a build that swaps the view
  /// for another tab's can be told from one that repaints the same tab.
  ShellSession? _shown;

  /// Tab numbers whose bad exit has already been put in front of the user. The
  /// header goes on saying `EXITED <code>` afterwards; the sheet is said once.
  final _announced = <int>{};

  /// True while the sheet is up, so a second exit waits its turn rather than
  /// landing on top of the first, and so the route is not popped out from
  /// under a modal that is still open.
  bool _announcing = false;

  /// Whether this host has ever had a tab while the route was on screen. The
  /// store is empty for the frame before the first shell opens, which is not
  /// the same emptiness as the last tab going.
  bool _opened = false;

  /// The size the fingers started from, for the length of one pinch: the
  /// scale is against where they began, so it applies to this and not to the
  /// last frame's result.
  double? _pinchBase;

  /// The size drawn from the first movement of a pinch until the settings
  /// stream has caught up with the write. The write is a database round trip
  /// behind the lift, and the view must not snap back in between.
  double? _pinched;

  @override
  void initState() {
    super.initState();
    // Held rather than read where it is used: `ref` is closed by the time
    // dispose runs, and this is the store the listener has to come off.
    _store = ref.read(shellSessionsProvider);
    // Both notifiers: the strip is drawn from the set, and the header, the
    // exit sheet and the pop that follows the last tab are all drawn from what
    // the tabs themselves report.
    _follower = ShellFollower(
      store: _store,
      watch: (store) => store.forHost(widget.host.id),
      onChange: _onSessions,
    );
    _clips = ref.read(clipStoreProvider);
    _clips.addListener(_onClips);
    // Landscape, as the screen route: a terminal is the other thing in the app
    // worth turning the phone for.
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    // Opening a session tells the store, and the screen the user came from is
    // listening to it while it draws this route in. So the shell waits for the
    // frame that pushed it to finish before it exists.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final sessions = ref.read(shellSessionsProvider);
      final wanted = widget.session;
      final seed = widget.seed;
      if (wanted != null) {
        sessions.activate(widget.host.id, wanted);
      } else if (seed != null && sessions.canOpen(widget.host.id)) {
        // A seeded open is a tab of its own even when the host already has
        // some: the caller asked for a shell in one directory, and landing in
        // whatever tab was last active would not be that.
        sessions.open(widget.host, prompt: _askHostKey, seed: seed);
      } else if (sessions.forHost(widget.host.id).isEmpty) {
        // A first visit opens one shell; a return finds the ones already
        // running and opens nothing.
        sessions.open(widget.host, prompt: _askHostKey);
      }
    });
  }

  @override
  void dispose() {
    _follower.dispose();
    _clips.removeListener(_onClips);
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
    super.dispose();
  }

  late final ShellSessions _store;
  late final ShellFollower _follower;

  /// Read for one number, the count on the bar's cell. A crop on the screen
  /// route while this one is under it is what changes it.
  late final ClipStore _clips;

  void _onClips() {
    if (mounted) setState(() {});
  }

  void _onSessions() {
    if (!mounted) return;
    setState(() {});
    if (_announcing) return;
    unawaited(_drain());
  }

  /// The two things the route owes a session that ended: a sheet for every bad
  /// exit, one at a time, and the pop once there are no tabs left — a shell
  /// that exited clean closes itself, so the last one can go without anybody
  /// touching the `×` cell.
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
        if (close) await _store.close(widget.host.id, ended);
      }
      if (!mounted) return;
      if (_opened && _store.forHost(widget.host.id).isEmpty) {
        Navigator.of(context).pop();
      }
    } finally {
      _announcing = false;
    }
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

  /// What a shell that did not end on 0 gets: the code, which is otherwise a
  /// word in a header the user may never be looking at, and the choice the
  /// clean exit makes on its own. `KEEP` is the affirmative because the output
  /// under the sheet is the only place the error is written down.
  Future<bool> _exitSheet(int number, int? code) async {
    final title = 'SHELL $number EXITED ${code ?? '—'}';
    final answer = await showPanelSheet<bool>(
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
                  onTap: () => Navigator.of(context).pop(true),
                ),
              ),
              const SizedBox(width: Spacing.md),
              Expanded(
                child: ActionBlock(
                  label: 'KEEP',
                  tone: SpectacleColors.accent,
                  filled: true,
                  onTap: () => Navigator.of(context).pop(false),
                ),
              ),
            ],
          ),
        ],
      ),
    );
    return answer ?? false;
  }

  /// Every shell the app is holding, on every host, so the sheet can be handed
  /// another host without going down and coming back up.
  ///
  /// Offered only while a second host has one: with a single host the tab row
  /// beside the name is already the whole list.
  Future<void> _openSwitcher() async {
    final hosts = _store.openHosts;
    final chosen = await showPanelSheet<(Host, ShellSession)>(
      context,
      title: 'SHELLS',
      builder: (context) => PanelSheetBody(
        title: 'SHELLS',
        children: [
          ListRowGroup(
            children: [
              for (final (host, sessions) in hosts)
                for (final session in sessions)
                  ListRow(
                    key: ValueKey('shell-switch-${host.id}-${session.number}'),
                    title: '${host.name.toUpperCase()} ${session.number}',
                    subtitle: session.title,
                    leading: ShellStateDot(state: session.state),
                    value: identical(session, _store.activeFor(widget.host.id))
                        ? 'ON SCREEN'
                        : null,
                    onTap: () => Navigator.of(context).pop((host, session)),
                  ),
            ],
          ),
        ],
      ),
    );
    if (!mounted || chosen == null) return;
    final (host, session) = chosen;
    if (host.id == widget.host.id) {
      _store.activate(host.id, session);
      return;
    }
    widget.onSwitchHost?.call(host, session);
  }

  /// Whether the IME is up: what the system says it is showing, not what the
  /// view has focus. The two part company when the system back button hides
  /// the keyboard, which leaves the focus where it was.
  bool get _keyboardOpen => MediaQuery.viewInsetsOf(context).bottom > 0;

  void _onKeyboard(ShellSession session) {
    final focus = session.focusNode;
    if (_keyboardOpen) {
      focus.unfocus();
    } else if (focus.hasFocus) {
      // Focus the view already has cannot be asked for again, so the keyboard
      // the system took away is asked back directly.
      SystemChannels.textInput.invokeMethod<void>('TextInput.show');
    } else {
      focus.requestFocus();
    }
  }

  void _onSticky(ShellSession session, Set<StickyModifier> sticky, int repeat) {
    _store.arm(session, sticky, repeat: repeat);
  }

  void _onBytes(ShellSession session, Uint8List bytes) {
    _store.send(session, bytes);
  }

  void _onSelect(ShellSession session) {
    _store.activate(widget.host.id, session);
  }

  /// Called from build with the tab about to be drawn. When it is not the one
  /// drawn last, the view under the old tab is on its way out and its focus
  /// node goes with it: a node detached while it holds focus gives it up,
  /// which is what takes the keyboard down. With the keyboard up the user is
  /// mid-typing, so it is put back on the tab they landed on — whichever way
  /// they got there: the plus, a tab cell, or a shell exiting under them —
  /// rather than making them tap the toggle again.
  void _follow(ShellSession? active) {
    final shown = _shown;
    if (identical(shown, active)) return;
    _shown = active;
    if (active == null || shown == null || !shown.focusNode.hasFocus) return;
    // After the frame: the new view has to be in the tree for its node to
    // take focus, and the old one has to be out of it for its node to let go.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!identical(_store.activeFor(widget.host.id), active)) return;
      active.focusNode.requestFocus();
    });
  }

  void _onNew() {
    _store.open(widget.host, prompt: _askHostKey);
  }

  double get _fontSize =>
      _pinched ??
      ref.read(shellFontSizeProvider).valueOrNull ??
      shellFontSizeDefault;

  void _onPinchStart(ScaleStartDetails _) {
    _pinchBase = _fontSize;
  }

  /// Two fingers or nothing: the recognizer also reports a one-finger drag it
  /// happened to win, and that is a scroll the terminal did not get, not a
  /// resize.
  void _onPinchUpdate(ScaleUpdateDetails details) {
    final base = _pinchBase;
    if (base == null || details.pointerCount < 2) return;
    final next = pinchedFontSize(base, details.scale);
    if (next == _pinched) return;
    setState(() => _pinched = next);
  }

  /// The write happens on the lift, once, rather than on every frame of the
  /// pinch: the row is one number, and the stream behind every other shell
  /// tab does not need forty of them.
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

  /// The route is in front of the user, so a machine that has never been
  /// connected to is asked about rather than refused. The dial is waiting on
  /// this future inside the handshake.
  Future<bool> _askHostKey(HostKeyOffer offer) async {
    if (!mounted) return false;
    return askHostKey(context, host: widget.host, offer: offer);
  }

  Future<void> _onClose(ShellSession session) async {
    // A live shell is a thing with state in it — a job running, an editor with
    // an unsaved buffer — so closing one is asked about. One that has already
    // ended has nothing left to lose and goes at once.
    if (session.state is ShellLive) {
      final confirmed = await confirmSheet(
        context,
        title: 'CLOSE SHELL ${session.number}?',
        confirmLabel: 'CLOSE',
      );
      if (!confirmed || !mounted) return;
    }
    // The route is the tabs, and with none left there is nothing to be on —
    // but the pop belongs to the store's listener, which is the one path every
    // way of losing the last tab goes through.
    await _store.close(widget.host.id, session);
  }

  @override
  Widget build(BuildContext context) {
    final store = ref.watch(shellSessionsProvider);
    final persisted =
        ref.watch(shellFontSizeProvider).valueOrNull ?? shellFontSizeDefault;
    // The pinched size is let go the moment the row says the same thing, so
    // a change written from another tab is drawn here too.
    ref.listen(shellFontSizeProvider, (_, next) {
      if (_pinched != null && next.valueOrNull == _pinched) {
        setState(() => _pinched = null);
      }
    });
    final fontSize = _pinched ?? persisted;
    return Scaffold(
      backgroundColor: const Color(0xFF000000),
      // The bar rides up with the keyboard rather than being covered by it.
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: Builder(
          // The rebuild comes from the follower wired in `initState`, which is
          // watching the set and every tab in it.
          builder: (context) {
            final sessions = store.forHost(widget.host.id);
            final active = store.activeFor(widget.host.id);
            _follow(active);
            final state = active?.state;
            return Column(
              children: [
                // The rows above the terminal are the sheet's grip: the
                // terminal's own drag is its scroll, and the bar's is its
                // horizontal one.
                ShellSheetGrip(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ShellHeader(
                        host: widget.host,
                        sessions: sessions,
                        active: active,
                        canOpen: store.canOpen(widget.host.id),
                        // A host to go to, and a sheet that can hold it: with
                        // either missing the name is just the name.
                        onSwitchHost:
                            widget.onSwitchHost != null &&
                                store.openHosts.length > 1
                            ? _openSwitcher
                            : null,
                        onSelect: _onSelect,
                        onNew: _onNew,
                        onClose: active == null ? null : () => _onClose(active),
                        onStop: active == null
                            ? null
                            : () => store.stopReconnect(active),
                      ),
                      // The whole of what a failure costs the terminal: one
                      // short row, and only while there is a failure.
                      if (state is ShellFailed)
                        ShellReasonRow(host: widget.host, kind: state.kind),
                    ],
                  ),
                ),
                Expanded(
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
                          child: Stack(
                            // The terminal is the size of the whole area; the
                            // affordance floats over it. Without this the stack
                            // would take the size of the affordance, which is
                            // nothing at all until there is a selection.
                            fit: StackFit.expand,
                            children: [
                              ShellTerminalView(
                                session: active,
                                fontSize: fontSize,
                              ),
                              ShellSelectionActions(session: active),
                            ],
                          ),
                        ),
                ),
                if (active != null)
                  ShellBar(
                    sticky: active.sticky,
                    repeat: active.stickyRepeat,
                    onSticky: (sticky, repeat) =>
                        _onSticky(active, sticky, repeat),
                    onBytes: (bytes) => _onBytes(active, bytes),
                    keyboardOpen: _keyboardOpen,
                    onKeyboard: () => _onKeyboard(active),
                    clipCount: _clips.count,
                    onAttach: () => showAttachSheet(context, session: active),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}
