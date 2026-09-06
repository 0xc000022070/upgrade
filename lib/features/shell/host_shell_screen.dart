import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../../application/clips.dart';
import '../../application/providers.dart';
import '../../application/shell_font.dart';
import '../../data/repositories/host_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../../design/colors.dart';
import '../../design/components/action_block.dart';
import '../../design/components/key_cell.dart';
import '../../design/components/list_row.dart';
import '../../design/components/panel.dart';
import '../../design/components/panel_sheet.dart';
import '../../design/icons/spectacle_icon.dart';
import '../../design/icons/spectacle_icons.dart';
import '../../design/motion.dart';
import '../../design/spacing.dart';
import '../../design/typography.dart';
import '../../platform/host_keys.dart';
import '../../platform/shell/shell_connection.dart';
import '../../platform/vnc/keysyms.dart';
import '../hosts/host_key_sheet.dart';
import 'attach_sheet.dart';
import 'shell_bar.dart';
import 'shell_sessions.dart';
import 'shell_status.dart';

/// The way in: a host panel's `SHELL >` row on HOSTS, a host row on SSH, or one
/// of that tab's session cards, which names the session it wants on screen.
///
/// The shell is a sheet over that screen, not a page in front of it: the
/// screen stays drawn under the wash, and the header drags the sheet down.
void openHostShell(
  BuildContext context,
  Host host, {
  ShellSession? session,
  String? seed,
}) {
  Navigator.of(
    context,
    rootNavigator: true,
  ).push(ShellSheetRoute(host: host, session: session, seed: seed));
}

/// The rule on the sheet's top edge, which is the whole of what says the shell
/// is a sheet. It is drawn over the header's ground rather than above it: the
/// sheet stands flush under the status bar, and rows are what a terminal is.
const _gripWidth = 36.0;
const _gripHeight = 2.0;
const _gripInset = 5.0;

/// A release faster than this, in px/s, decides on its own: downward leaves,
/// upward stays. Slower, where the finger left the sheet decides.
const _sheetFling = 700.0;

/// A slow release past this share of the sheet's rise leaves; short of it,
/// the sheet comes back.
const _sheetLeaveShare = 1 / 3;

/// The shell as a modal sheet: the route beneath stays under a wash, the
/// sheet rises from the bottom, and a drag on its header takes it down again.
///
/// The wash is lighter than the panel sheet's: what shows through it is the
/// tab the shell was opened from, and it should still read as that tab.
class ShellSheetRoute extends PopupRoute<void> {
  ShellSheetRoute({required this.host, this.session, this.seed});

  final Host host;
  final ShellSession? session;

  /// A line the shell opens on, which is how a workspace hands its directory
  /// to a terminal.
  final String? seed;

  /// Held for the route's life rather than made per frame: a curved animation
  /// listens to its parent, and one made in a build is one nobody disposes.
  CurvedAnimation? _curved;

  /// Up between a drag's start and its landing. A tap on the grip ends in the
  /// recognizer's cancel with no start before it, and that is not a drag.
  bool _dragging = false;

  @override
  Color get barrierColor => const Color(0x99000000);

  @override
  bool get barrierDismissible => true;

  @override
  String get barrierLabel => '${host.name} shell';

  @override
  Duration get transitionDuration => Motion.normal;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return _SheetFrame(
      child: _SheetContents(host: host, session: session, seed: seed),
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // Under the finger the sheet is where the finger is, one to one; on its
    // own it eases. The gesture flag outlives the finger until the settle
    // lands, so the curve does not swap under a sheet that is still moving.
    final linear = navigator?.userGestureInProgress ?? false;
    final position = linear
        ? animation
        : _curved ??= CurvedAnimation(
            parent: animation,
            curve: Motion.enter,
            reverseCurve: Motion.exit,
          );
    return SlideTransition(
      position: Tween(
        begin: const Offset(0, 1),
        end: Offset.zero,
      ).animate(position),
      child: child,
    );
  }

  @override
  void dispose() {
    _curved?.dispose();
    super.dispose();
  }

  /// The grip's drag, driven from the route so the controller stays where a
  /// route keeps it. The navigator's gesture flag goes up here and comes down
  /// only when the sheet has landed, whichever way it went.
  void dragStart() {
    _dragging = true;
    navigator!.didStartUserGesture();
  }

  /// A finger's pixel is that share of the screen's height off the rise:
  /// the slide is the screen's height, so the two move one to one.
  void dragBy(double pixels, double height) {
    final next = controller!.value - pixels / height;
    controller!.value = next.clamp(0.0, 1.0);
  }

  /// A fast release decides by its direction, a slow one by where the sheet
  /// is. Downward is positive, as the screen's y is.
  void dragEnd(double velocity) {
    if (!_dragging) return;
    final leave = velocity.abs() > _sheetFling
        ? velocity > 0
        : controller!.value < 1 - _sheetLeaveShare;
    _settle(leave: leave);
  }

  void dragCancel() {
    if (_dragging) _settle(leave: false);
  }

  void _settle({required bool leave}) {
    _dragging = false;
    final nav = navigator!;
    final ctl = controller!;
    if (leave) {
      // The pop reverses the controller from where it is, which is the rest
      // of the slide and nothing more.
      nav.pop();
    } else {
      ctl.animateTo(1, duration: Motion.fast, curve: Curves.linear);
    }
    if (!ctl.isAnimating) {
      nav.didStopUserGesture();
      return;
    }
    late final AnimationStatusListener landed;
    landed = (_) {
      ctl.removeStatusListener(landed);
      nav.didStopUserGesture();
    };
    ctl.addStatusListener(landed);
  }
}

/// The sheet's box: the screen's height less the status bar, parked at the
/// bottom, a hairline and the grip's rule along its top edge.
class _SheetFrame extends StatelessWidget {
  const _SheetFrame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return Align(
      alignment: Alignment.bottomCenter,
      child: SizedBox(
        key: const ValueKey('shell-sheet'),
        height: media.size.height - media.padding.top,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // The frame already stands clear of the status bar, so the safe
            // area inside the route must not stand clear of it again.
            MediaQuery.removePadding(
              context: context,
              removeTop: true,
              child: DecoratedBox(
                // In front of the child: the route paints its own ground over
                // the whole box, and a rule behind it would be painted out.
                position: DecorationPosition.foreground,
                decoration: const BoxDecoration(
                  border: Border(
                    top: BorderSide(color: SpectacleColors.borderNormal),
                  ),
                ),
                child: child,
              ),
            ),
            // Over the header's first rows, and out of the way of its cells:
            // the rule is a sign, and the header under it is the grip.
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: IgnorePointer(child: _SheetRule()),
            ),
          ],
        ),
      ),
    );
  }
}

/// The short rule under the sheet's top edge.
class _SheetRule extends StatelessWidget {
  const _SheetRule();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      height: _gripInset + _gripHeight,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: SizedBox(
          key: ValueKey('shell-grip-rule'),
          width: _gripWidth,
          height: _gripHeight,
          child: ColoredBox(color: SpectacleColors.textDisabled),
        ),
      ),
    );
  }
}

/// The header as the sheet's grip: a vertical drag on it moves the sheet with
/// the finger, and the release decides whether the sheet leaves or comes
/// back. Nothing at all when the route is a page, which is how a test pumps
/// it.
///
/// The route's own controller is what the drag moves, the way the iOS back
/// swipe moves a page's: the transition already knows how to draw the sheet
/// at any point of its rise, and popping from a part-way value runs the rest
/// of the slide from there.
class _SheetGrip extends StatefulWidget {
  const _SheetGrip({required this.child});

  final Widget child;

  @override
  State<_SheetGrip> createState() => _SheetGripState();
}

class _SheetGripState extends State<_SheetGrip> {
  ShellSheetRoute? _route;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    _route = route is ShellSheetRoute ? route : null;
  }

  @override
  Widget build(BuildContext context) {
    final route = _route;
    if (route == null) return widget.child;
    return GestureDetector(
      key: const ValueKey('shell-grip'),
      behavior: HitTestBehavior.opaque,
      // The finger's whole travel moves the sheet, the slop included: the
      // sheet is under the finger from the first pixel, not from the
      // nineteenth.
      dragStartBehavior: DragStartBehavior.down,
      onVerticalDragStart: (_) => route.dragStart(),
      onVerticalDragUpdate: (details) => route.dragBy(
        details.primaryDelta!,
        MediaQuery.sizeOf(context).height,
      ),
      onVerticalDragEnd: (details) =>
          route.dragEnd(details.primaryVelocity ?? 0),
      onVerticalDragCancel: route.dragCancel,
      child: widget.child,
    );
  }
}

/// The palette, from the tokens where the tokens have a word for the colour and
/// from the standard hues where they do not. Green is the accent: it is the one
/// ANSI colour the app already has an opinion about, and a shell that prints a
/// prompt in green should print it in the app's green.
///
/// The selection is a wash, not a block: xterm paints it over the glyphs, so an
/// opaque colour hides the very text the finger picked.
const _shellTheme = TerminalTheme(
  cursor: SpectacleColors.accent,
  selection: Color(0x55B7FF2A),
  foreground: SpectacleColors.textPrimary,
  background: Color(0xFF000000),
  black: SpectacleColors.backgroundPrimary,
  red: Color(0xFFCD3131),
  green: SpectacleColors.accent,
  yellow: Color(0xFFE5E510),
  blue: Color(0xFF2472C8),
  magenta: Color(0xFFBC3FBC),
  cyan: Color(0xFF11A8CD),
  white: SpectacleColors.textPrimary,
  brightBlack: SpectacleColors.textDisabled,
  brightRed: Color(0xFFF14C4C),
  brightGreen: SpectacleColors.accentMuted,
  brightYellow: Color(0xFFF5F543),
  brightBlue: Color(0xFF3B8EEA),
  brightMagenta: Color(0xFFD670D6),
  brightCyan: Color(0xFF29B8DB),
  brightWhite: Color(0xFFFFFFFF),
  searchHitBackground: SpectacleColors.accent,
  searchHitBackgroundCurrent: SpectacleColors.accentMuted,
  searchHitForeground: SpectacleColors.backgroundPrimary,
);

/// One style per size, kept. The view compares styles by identity and lays
/// the whole buffer out again on a new one, and the route rebuilds far more
/// often than the size changes.
final _shellTextStyles = <double, TerminalStyle>{};

TerminalStyle _shellTextStyle(double fontSize) => _shellTextStyles.putIfAbsent(
  fontSize,
  () => TerminalStyle(fontSize: fontSize, fontFamily: FontFamilies.mono),
);

/// The one row above the terminal, and the one place in the route that is a
/// fixed size: the tab cells in it are hit targets before they are labels.
const _headerHeight = TapTargets.minHeight;

/// The row under it, drawn only when there is a failure to explain. Shorter
/// than the header because it carries no hit target at all.
const _reasonHeight = 32.0;

/// How much of the header the tabs may take before they start to scroll inside
/// it. Nine tabs are wider than a phone is, and the title is worth keeping a
/// readable share of the row.
const _tabsShare = 0.55;

/// What the sheet holds: one host's shell at a time, and the host it holds is
/// the switcher's to change.
///
/// The shell is keyed by host id, so switching drops the state of the host
/// being left and builds the one arrived at from its `initState` — the same
/// path a fresh open takes, which is what makes the arriving host activate the
/// tab it was asked for.
class _SheetContents extends StatefulWidget {
  const _SheetContents({required this.host, this.session, this.seed});

  final Host host;
  final ShellSession? session;
  final String? seed;

  @override
  State<_SheetContents> createState() => _SheetContentsState();
}

class _SheetContentsState extends State<_SheetContents> {
  late Host _host = widget.host;
  late ShellSession? _session = widget.session;

  void _switchTo(Host host, ShellSession session) {
    if (host.id == _host.id) return;
    setState(() {
      _host = host;
      _session = session;
    });
  }

  @override
  Widget build(BuildContext context) {
    return HostShellRoute(
      key: ValueKey(_host.id),
      host: _host,
      session: _session,
      // Only the host the sheet opened on is the one the seed was meant for:
      // switching hosts carries nothing of the directory it came from.
      seed: _host.id == widget.host.id ? widget.seed : null,
      onSwitchHost: _switchTo,
    );
  }
}

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
    _store.addListener(_onSessions);
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
    _store.removeListener(_onSessions);
    _clips.removeListener(_onClips);
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
    super.dispose();
  }

  late final ShellSessions _store;

  /// Read for one number, the count on the bar's cell. A crop on the screen
  /// route while this one is under it is what changes it.
  late final ClipStore _clips;

  void _onClips() {
    if (mounted) setState(() {});
  }

  void _onSessions() {
    if (!mounted || _announcing) return;
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
        child: AnimatedBuilder(
          animation: store,
          builder: (context, _) {
            final sessions = store.forHost(widget.host.id);
            final active = store.activeFor(widget.host.id);
            _follow(active);
            final state = active?.state;
            return Column(
              children: [
                // The rows above the terminal are the sheet's grip: the
                // terminal's own drag is its scroll, and the bar's is its
                // horizontal one.
                _SheetGrip(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _Header(
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
                        _ReasonRow(host: widget.host, kind: state.kind),
                    ],
                  ),
                ),
                Expanded(
                  child: active == null
                      ? const SizedBox.shrink()
                      : RawGestureDetector(
                          key: const ValueKey('shell-pinch'),
                          gestures: {
                            _ResizeGestureRecognizer:
                                GestureRecognizerFactoryWithHandlers<
                                  _ResizeGestureRecognizer
                                >(
                                  _ResizeGestureRecognizer.new,
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
                              _Terminal(session: active, fontSize: fontSize),
                              _SelectionActions(session: active),
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

/// The view's inset, which is also where its render sits inside it: the copy
/// affordance carries the render's offsets out by this much.
const _terminalPadding = EdgeInsets.all(Spacing.md);

/// The view's key: by session, so switching tabs swaps the whole thing rather
/// than repainting one terminal with another's buffer, and global, so the copy
/// affordance can ask the view where a cell is on the screen.
GlobalObjectKey<TerminalViewState> _terminalKey(ShellSession session) =>
    GlobalObjectKey<TerminalViewState>(session);

/// The view, keyed by session so switching tabs swaps the whole thing rather
/// than repainting one terminal with another's buffer.
///
/// The IME is the terminal's own now: it takes text input, and what it produces
/// runs through the store, which is where the armed modifiers are applied and
/// spent. It comes up through the bar's KEYBOARD cell and nothing else: a tap on
/// the view is a look at the screen, not a call for input.
class _Terminal extends StatelessWidget {
  const _Terminal({required this.session, required this.fontSize});

  final ShellSession session;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return TerminalView(
      session.terminal,
      key: _terminalKey(session),
      controller: session.controller,
      focusNode: session.focusNode,
      scrollController: session.scrollController,
      theme: _shellTheme,
      textStyle: _shellTextStyle(fontSize),
      cursorType: TerminalCursorType.block,
      // Plain text: the view turns autocorrect and suggestions off itself, and
      // a keyboard picked for anything else puts the wrong keys under a shell.
      keyboardType: TextInputType.text,
      keyboardOnTap: false,
      padding: _terminalPadding,
    );
  }
}

/// A pinch that gives the one-finger drag back to the terminal.
///
/// [ScaleGestureRecognizer] wins the arena the moment a single finger passes
/// pan slop, which is a scroll the view under it never gets. Refusing to accept
/// below two fingers leaves that drag to the terminal's own scroll and keeps
/// the win for a real pinch, where the span between two fingers is what moves.
class _ResizeGestureRecognizer extends ScaleGestureRecognizer {
  @override
  void resolve(GestureDisposition disposition) {
    // A single finger past pan slop is a scroll, so hand it back rather than
    // hold the arena: the terminal's own drag is waiting to take it. A real
    // pinch has both fingers down before it moves, so it accepts as itself.
    if (disposition == GestureDisposition.accepted && pointerCount < 2) {
      super.resolve(GestureDisposition.rejected);
      return;
    }
    super.resolve(disposition);
  }
}

/// The selection's furniture, which xterm does not draw for a touch: a grip at
/// either end of it to drag that end by, and a floating cell that reads the
/// selected text out of the buffer and onto the clipboard. Nothing while there
/// is no selection.
///
/// The cell sits on the selection, over the top line of it, the way a text
/// field's toolbar sits on the words: the finger that made the selection is
/// already there, and a cell in a corner is a reach and a look away from the
/// words it acts on. Below the grips when the top line has no room over it.
///
/// Stateful for the listeners it keeps: the session's controller, which is
/// where the selection lives and the only thing that says a copy is possible;
/// the scroll and the terminal, which move the selected line under it.
class _SelectionActions extends StatefulWidget {
  const _SelectionActions({required this.session});

  final ShellSession session;

  @override
  State<_SelectionActions> createState() => _SelectionActionsState();
}

class _SelectionActionsState extends State<_SelectionActions> {
  @override
  void initState() {
    super.initState();
    _listen(widget.session);
  }

  @override
  void didUpdateWidget(_SelectionActions old) {
    super.didUpdateWidget(old);
    if (old.session != widget.session) {
      _unlisten(old.session);
      _listen(widget.session);
    }
  }

  @override
  void dispose() {
    _unlisten(widget.session);
    _releaseGrip();
    super.dispose();
  }

  void _listen(ShellSession session) {
    session.controller.addListener(_onSelection);
    session.scrollController.addListener(_onMove);
    session.terminal.addListener(_onMove);
  }

  void _unlisten(ShellSession session) {
    session.controller.removeListener(_onSelection);
    session.scrollController.removeListener(_onMove);
    session.terminal.removeListener(_onMove);
  }

  /// The line under the affordance moved: a scroll, or output that pushed it.
  void _onMove() {
    if (mounted && _selected) setState(() {});
  }

  bool _selected = false;

  /// The tick under the finger that says the press took: the highlight comes
  /// a frame later and is easy to miss under a thumb.
  void _onSelection() {
    if (!mounted) return;
    final selected = widget.session.controller.selection != null;
    if (selected && !_selected) HapticFeedback.selectionClick();
    _selected = selected;
    setState(() {});
  }

  /// The cell at the end a grip is not dragging, held from the start of the
  /// drag: the selection is normalised on every read, so once the finger
  /// crosses the other end the range no longer says which end is the still
  /// one. The cell itself and not the range's end, which is one past it.
  ///
  /// An anchor and not a [CellOffset], because a row index is only true of the
  /// buffer that answered it: output arriving mid-drag pushes the scrollback
  /// along and the still end would walk up the screen with it.
  CellAnchor? _held;

  void _onGripStart(_SelectionPart grip) {
    final range = widget.session.controller.selection?.normalized;
    if (range == null) return;
    final cell = grip == _SelectionPart.begin
        ? CellOffset(math.max(0, range.end.x - 1), range.end.y)
        : range.begin;
    _releaseGrip();
    _held = widget.session.terminal.buffer.createAnchorFromOffset(cell);
  }

  void _releaseGrip() {
    _held?.dispose();
    _held = null;
  }

  /// The selection runs from the held cell to the one under the finger,
  /// whichever way round they are, and takes both.
  void _onGripDrag(Offset global) {
    final anchor = _held;
    final render = _terminalKey(widget.session).currentState?.renderTerminal;
    if (anchor == null || !anchor.attached || render == null) return;
    final held = anchor.offset;
    final buffer = widget.session.terminal.buffer;
    final under = render.getCellOffset(render.globalToLocal(global));
    final first = under.isBefore(held) ? under : held;
    final last = under.isBefore(held) ? held : under;
    widget.session.controller.setSelection(
      buffer.createAnchorFromOffset(first),
      buffer.createAnchorFromOffset(CellOffset(last.x + 1, last.y)),
      mode: SelectionMode.line,
    );
  }

  Future<void> _copy() async {
    final controller = widget.session.controller;
    final selection = controller.selection;
    if (selection == null) return;
    final text = widget.session.terminal.buffer.getText(selection);
    await Clipboard.setData(ClipboardData(text: text));
    controller.clearSelection();
  }

  @override
  Widget build(BuildContext context) {
    final selection = widget.session.controller.selection;
    if (selection == null) return const SizedBox.shrink();
    final view = _terminalKey(widget.session);
    final lineHeight = view.currentState?.renderTerminal.lineHeight ?? 0;
    return CustomMultiChildLayout(
      delegate: _SelectionLayout(selection, view),
      children: [
        for (final part in [_SelectionPart.begin, _SelectionPart.end])
          LayoutId(
            id: part,
            child: _Grip(
              key: ValueKey('shell-select-${part.name}'),
              lineHeight: lineHeight,
              onStart: () => _onGripStart(part),
              onDrag: _onGripDrag,
              onFinish: _releaseGrip,
            ),
          ),
        LayoutId(
          id: _SelectionPart.actions,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: SpectacleColors.surfacePrimary,
              border: Border.all(color: SpectacleColors.borderSubtle),
            ),
            child: SizedBox(
              height: RowMetrics.minHeight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  KeyCell(
                    key: const ValueKey('shell-copy'),
                    label: 'COPY',
                    minWidth: RowMetrics.minHeight,
                    padding: RowMetrics.padding,
                    height: RowMetrics.minHeight,
                    onTap: _copy,
                  ),
                  const _Divider(),
                  KeyCell(
                    key: const ValueKey('shell-copy-clear'),
                    label: 'CLEAR',
                    minWidth: RowMetrics.minHeight,
                    padding: RowMetrics.padding,
                    height: RowMetrics.minHeight,
                    onTap: widget.session.controller.clearSelection,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

enum _SelectionPart { begin, end, actions }

/// A bar down the edge of the selection's first or last cell, with a knob under
/// it to take the finger, that moves that end of the selection where it is
/// dragged. It claims the pointer on the down: left to the arena, the scroll
/// under it takes any drag with a vertical lean before this one has moved
/// far enough to say it is a drag at all.
class _Grip extends StatelessWidget {
  const _Grip({
    super.key,
    required this.lineHeight,
    required this.onStart,
    required this.onDrag,
    required this.onFinish,
  });

  final double lineHeight;
  final VoidCallback onStart;
  final ValueChanged<Offset> onDrag;
  final VoidCallback onFinish;

  static const bar = 2.0;
  static const knob = 10.0;

  /// The finger's target, wider than the knob it is drawn as.
  static const width = RowMetrics.minHeight;

  @override
  Widget build(BuildContext context) {
    return RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: {
        _GripDragRecognizer:
            GestureRecognizerFactoryWithHandlers<_GripDragRecognizer>(
              _GripDragRecognizer.new,
              (recognizer) {
                recognizer.onStart = (_) => onStart();
                recognizer.onUpdate = (details) =>
                    onDrag(details.globalPosition);
                recognizer.onEnd = (_) => onFinish();
                recognizer.onCancel = onFinish;
              },
            ),
      },
      child: SizedBox(
        width: width,
        height: lineHeight + knob,
        child: Column(
          children: [
            Container(
              width: bar,
              height: lineHeight,
              color: SpectacleColors.accent,
            ),
            Container(width: knob, height: knob, color: SpectacleColors.accent),
          ],
        ),
      ),
    );
  }
}

class _GripDragRecognizer extends PanGestureRecognizer {
  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }
}

/// Puts the grips on the ends of the selection and the cell over it, centred,
/// or under it when the top has no room; kept on the screen either way. Each
/// child takes its own size: the layout is the parent's whole area and only
/// the children are targets, so a touch anywhere else still reaches the
/// terminal.
///
/// The selection's place is read at layout and not at build: the terminal
/// corrects its own scroll offset while it lays out, without a word to the
/// scroll controller, and a position taken before that is a line off. The
/// terminal is laid out first in the stack, so what this reads is this frame's.
class _SelectionLayout extends MultiChildLayoutDelegate {
  _SelectionLayout(this.selection, this.view);

  final BufferRange selection;
  final GlobalKey<TerminalViewState> view;

  static const _gap = Spacing.md;

  @override
  void performLayout(Size size) {
    final loose = BoxConstraints.loose(size);
    final grip = layoutChild(_SelectionPart.begin, loose);
    layoutChild(_SelectionPart.end, loose);
    final cell = layoutChild(_SelectionPart.actions, loose);
    final room = Offset(
      math.max(0.0, size.width - cell.width),
      math.max(0.0, size.height - cell.height),
    );

    final render = view.currentState?.renderTerminal;
    if (render == null) {
      // No view to ask: the corner over the key bar, where a thumb already
      // is, and the grips out of the way under it.
      positionChild(_SelectionPart.actions, room);
      positionChild(_SelectionPart.begin, Offset(size.width, size.height));
      positionChild(_SelectionPart.end, Offset(size.width, size.height));
      return;
    }

    // In the view's coordinates, which are this layout's: both fill the same
    // stack. The render sits inside the view's padding, so its own offsets
    // are carried out by that much; a transform walk is not allowed mid-layout.
    final range = selection.normalized;
    final cellSize = render.cellSize;
    // The range's end is one past the last cell, so its offset is the
    // selection's right edge as it stands.
    final begin = render.getOffset(range.begin) + _terminalPadding.topLeft;
    final end = render.getOffset(range.end) + _terminalPadding.topLeft;
    positionChild(
      _SelectionPart.begin,
      Offset(begin.dx - grip.width / 2, begin.dy),
    );
    positionChild(_SelectionPart.end, Offset(end.dx - grip.width / 2, end.dy));

    // Centred on the top line of the selection, or on the width when the
    // selection runs on past it.
    final right = range.begin.y == range.end.y ? end.dx : size.width;
    final double x = ((begin.dx + right - cell.width) / 2).clamp(0.0, room.dx);
    var y = begin.dy - _gap - cell.height;
    if (y < 0) y = end.dy + cellSize.height + _Grip.knob + _gap;
    positionChild(_SelectionPart.actions, Offset(x, y.clamp(0.0, room.dy)));
  }

  @override
  bool shouldRelayout(_SelectionLayout old) => true;
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) =>
      Container(width: Borders.hairline, color: SpectacleColors.borderSubtle);
}

/// The route's whole chrome: the host, its tabs, what the shell calls itself,
/// and the way to close the one on screen — one row, because everything else
/// on this route is the terminal.
class _Header extends StatelessWidget {
  const _Header({
    required this.host,
    required this.sessions,
    required this.active,
    required this.canOpen,
    required this.onSwitchHost,
    required this.onSelect,
    required this.onNew,
    required this.onClose,
    required this.onStop,
  });

  final Host host;
  final List<ShellSession> sessions;
  final ShellSession? active;
  final bool canOpen;

  /// Opens the list of every shell on every host, or null when this is the
  /// only host with one.
  final VoidCallback? onSwitchHost;
  final void Function(ShellSession session) onSelect;
  final VoidCallback onNew;
  final VoidCallback? onClose;
  final VoidCallback? onStop;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('shell-header'),
      height: _headerHeight,
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: SpectacleColors.borderSubtle)),
      ),
      child: LayoutBuilder(
        builder: (context, box) => Row(
          children: [
            const SizedBox(width: Spacing.screenEdge),
            _HostCell(name: host.name, onTap: onSwitchHost),
            const SizedBox(width: Spacing.lg),
            // The tabs take what they need and scroll for the rest, so a host
            // with nine shells open still has a header and not an overflow.
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: box.maxWidth * _tabsShare),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final session in sessions)
                      _TabCell(
                        key: ValueKey('shell-tab-${session.number}'),
                        label: '${session.number}',
                        active: session == active,
                        onTap: () => onSelect(session),
                      ),
                    if (canOpen)
                      _TabCell(
                        key: const ValueKey('shell-tab-new'),
                        label: '+',
                        onTap: onNew,
                      ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
                child: _Middle(session: active, onStop: onStop),
              ),
            ),
            if (onClose != null)
              _TabCell(
                key: const ValueKey('shell-tab-close'),
                label: '×',
                onTap: onClose!,
              ),
            const SizedBox(width: Spacing.screenEdge),
          ],
        ),
      ),
    );
  }
}

/// The host the sheet is holding, and the way to another one.
///
/// A label until a second host has a shell, and a cell from then on: the mark
/// beside the name is the whole of what says the name can be tapped.
class _HostCell extends StatelessWidget {
  const _HostCell({required this.name, required this.onTap});

  final String name;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final label = Text(
      name.toUpperCase(),
      style: SpectacleText.panelHeader.copyWith(
        color: SpectacleColors.textPrimary,
      ),
    );
    if (onTap == null) return label;
    return GestureDetector(
      key: const ValueKey('shell-host-switch'),
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          label,
          const SizedBox(width: Spacing.sm),
          const SpectacleIcon(
            SpectacleIcons.expand,
            size: IconSizes.affordance,
            color: SpectacleColors.textDisabled,
          ),
        ],
      ),
    );
  }
}

/// What the shell calls itself while it is live, and where the session is when
/// it is not. Nothing at all for a live shell that never named itself: the
/// prompt under it is already saying everything this line could.
class _Middle extends StatelessWidget {
  const _Middle({required this.session, required this.onStop});

  final ShellSession? session;
  final VoidCallback? onStop;

  @override
  Widget build(BuildContext context) {
    final state = session?.state;
    final word = switch (state) {
      null => null,
      ShellLive() => session?.title,
      ShellConnecting() => 'CONNECTING',
      ShellDropped(:final attempt) =>
        'RECONNECTING $attempt/${shellReconnectDelays.length}',
      ShellExited(:final code) => 'EXITED ${code ?? '—'}',
      ShellFailed(:final kind) => _kindWord(kind),
    };
    if (word == null) return const SizedBox.shrink();
    final label = Text(
      word,
      style: state is ShellDropped
          ? SpectacleText.panelHeader.copyWith(color: SpectacleColors.textMuted)
          : SpectacleText.panelHeader,
      textAlign: TextAlign.right,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    // The only hit target the row carries. Dialling again is the app's job, so
    // there is nothing to press while it works — stopping it is the one part
    // of a reconnect that is a decision, and only the user can make it.
    if (state is! ShellDropped || onStop == null) return label;
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Flexible(child: label),
        const SizedBox(width: Spacing.lg),
        PanelAffordance('STOP', showIcon: false, onTap: onStop!),
      ],
    );
  }
}

/// The failure as one word for the header. The sentence with the host's name
/// in it belongs to the row underneath.
String _kindWord(ShellFailureKind kind) => switch (kind) {
  ShellFailureKind.unresolved => 'UNRESOLVED',
  ShellFailureKind.unreachable => 'UNREACHABLE',
  ShellFailureKind.keyRejected => 'KEY REJECTED',
  ShellFailureKind.shellRefused => 'SHELL REFUSED',
  ShellFailureKind.streamClosed => 'STREAM CLOSED',
  ShellFailureKind.hostKeyUnverified => 'HOST KEY UNVERIFIED',
  ShellFailureKind.hostKeyChanged => 'HOST KEY CHANGED',
};

/// Why the shell is not there, in a sentence with the host's name in it.
///
/// Only the failures the schedule gave up on or never took reach this row: a
/// key the host rejected and a key that changed are not waited out, they are
/// read and acted on somewhere else.
class _ReasonRow extends StatelessWidget {
  const _ReasonRow({required this.host, required this.kind});

  final Host host;
  final ShellFailureKind kind;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('shell-reason'),
      height: _reasonHeight,
      padding: const EdgeInsets.symmetric(horizontal: Spacing.screenEdge),
      child: Row(
        children: [
          Expanded(
            child: Text(
              shellReason(kind, host.name),
              style: SpectacleText.panelHeader.copyWith(
                color: SpectacleColors.warning,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _TabCell extends StatelessWidget {
  const _TabCell({
    super.key,
    required this.label,
    required this.onTap,
    this.active = false,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tint = active ? SpectacleColors.accent : SpectacleColors.textMuted;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minWidth: TapTargets.minHeight),
        // The cell takes the row it is in rather than setting a height of its
        // own, so its underline sits on the row's edge and the hairline under
        // the header does not push it over.
        height: double.infinity,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          // The underline is the whole of what marks the active tab beyond its
          // ink: a filled cell would read as a button, and these are tabs.
          border: Border(
            bottom: BorderSide(
              color: active ? SpectacleColors.accent : const Color(0x00000000),
              width: Borders.hairline * 2,
            ),
          ),
        ),
        child: Text(
          label,
          style: SpectacleText.panelHeader.copyWith(color: tint),
        ),
      ),
    );
  }
}
