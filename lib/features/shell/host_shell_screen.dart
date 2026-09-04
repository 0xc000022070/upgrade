import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../../data/repositories/host_repository.dart';
import '../../design/colors.dart';
import '../../design/components/panel.dart';
import '../../design/components/panel_sheet.dart';
import '../../design/spacing.dart';
import '../../design/typography.dart';
import '../../platform/shell/strip_bytes.dart';
import '../../platform/vnc/keysyms.dart';
import '../screen/keys_strip.dart';
import '../screen/screen_rail.dart';
import 'shell_sessions.dart';

/// The way in: a host panel's `SHELL >` row on ACCESS.
void openHostShell(BuildContext context, Host host) {
  Navigator.of(
    context,
    rootNavigator: true,
  ).push(MaterialPageRoute<void>(builder: (_) => HostShellRoute(host: host)));
}

/// The palette, from the tokens where the tokens have a word for the colour and
/// from the standard hues where they do not. Green is the accent: it is the one
/// ANSI colour the app already has an opinion about, and a shell that prints a
/// prompt in green should print it in the app's green.
const _shellTheme = TerminalTheme(
  cursor: HotlineColors.accent,
  selection: HotlineColors.borderNormal,
  foreground: HotlineColors.textPrimary,
  background: Color(0xFF000000),
  black: HotlineColors.backgroundPrimary,
  red: Color(0xFFCD3131),
  green: HotlineColors.accent,
  yellow: Color(0xFFE5E510),
  blue: Color(0xFF2472C8),
  magenta: Color(0xFFBC3FBC),
  cyan: Color(0xFF11A8CD),
  white: HotlineColors.textPrimary,
  brightBlack: HotlineColors.textDisabled,
  brightRed: Color(0xFFF14C4C),
  brightGreen: HotlineColors.accentMuted,
  brightYellow: Color(0xFFF5F543),
  brightBlue: Color(0xFF3B8EEA),
  brightMagenta: Color(0xFFD670D6),
  brightCyan: Color(0xFF29B8DB),
  brightWhite: Color(0xFFFFFFFF),
  searchHitBackground: HotlineColors.accent,
  searchHitBackgroundCurrent: HotlineColors.accentMuted,
  searchHitForeground: HotlineColors.backgroundPrimary,
);

const _shellTextStyle = TerminalStyle(
  fontSize: 13,
  fontFamily: FontFamilies.mono,
);

/// The tab row's height, and the one place in the route that is a fixed size:
/// the cells are hit targets before they are labels.
const _tabRowHeight = TapTargets.minHeight;

/// `/ <HOST> SHELL`: the host's own login shell, several at once as tabs.
///
/// The sessions are not here. They live in the store, which outlives every
/// visit — leaving and coming back finds the tabs where they were, still
/// running, so this route's dispose closes nothing but the orientation lock.
class HostShellRoute extends ConsumerStatefulWidget {
  const HostShellRoute({super.key, required this.host});

  final Host host;

  @override
  ConsumerState<HostShellRoute> createState() => _HostShellRouteState();
}

class _HostShellRouteState extends ConsumerState<HostShellRoute> {
  /// The same two independent switches the screen route has, and the same rail
  /// state: about this visit, not about the host.
  bool _stripOpen = false;
  bool _keyboardOpen = false;
  bool _railHidden = false;

  @override
  void initState() {
    super.initState();
    // Landscape, as the screen route: a terminal is the other thing in the app
    // worth turning the phone for.
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    final sessions = ref.read(shellSessionsProvider);
    // A first visit opens one shell; a return finds the ones already running
    // and opens nothing.
    if (sessions.forHost(widget.host.id).isEmpty) sessions.open(widget.host);
  }

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
    super.dispose();
  }

  void _onKeyboardClosed() {
    if (_keyboardOpen) setState(() => _keyboardOpen = false);
  }

  ShellSessions get _store => ref.read(shellSessionsProvider);

  void _onKeysym(int keysym, Set<StickyModifier> sticky) {
    final session = _store.activeFor(widget.host.id);
    if (session == null) return;
    final bytes = stripBytes(keysym, sticky);
    // Null is a key with no byte form, `SUPER` above all. Nothing goes, and
    // nothing is a bug.
    if (bytes != null) _store.send(session, bytes);
  }

  void _onCharacter(String character, Set<StickyModifier> sticky) {
    final session = _store.activeFor(widget.host.id);
    if (session == null) return;
    _store.send(session, typedBytes(character, sticky));
  }

  void _onNew() {
    _store.open(widget.host);
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
    await _store.close(widget.host.id, session);
    if (!mounted) return;
    // The route is the tabs. With none left there is nothing to be on.
    if (_store.forHost(widget.host.id).isEmpty) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final store = ref.watch(shellSessionsProvider);
    return Scaffold(
      backgroundColor: const Color(0xFF000000),
      // The strip rides up with the keyboard rather than being covered by it.
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: AnimatedBuilder(
          animation: store,
          builder: (context, _) {
            final sessions = store.forHost(widget.host.id);
            final active = store.activeFor(widget.host.id);
            final live = active?.state is ShellLive;
            return Column(
              children: [
                _Crumb(
                  host: widget.host,
                  session: active,
                  onBack: () => Navigator.of(context).pop(),
                  onRetry: active == null
                      ? null
                      : () => store.retry(widget.host, active),
                ),
                _TabRow(
                  sessions: sessions,
                  active: active,
                  canOpen: store.canOpen(widget.host.id),
                  onSelect: (session) =>
                      store.activate(widget.host.id, session),
                  onNew: _onNew,
                  onClose: active == null ? null : () => _onClose(active),
                ),
                Expanded(
                  child: Stack(
                    children: [
                      if (active != null)
                        Positioned.fill(child: _Terminal(session: active)),
                      // Over the terminal, and only where the rail is: every
                      // tap that misses a toggle still reaches the view under
                      // it.
                      if (live)
                        Positioned.fill(
                          child: ScreenRail(
                            keyboardOpen: _keyboardOpen,
                            stripOpen: _stripOpen,
                            hidden: _railHidden,
                            onKeyboard: () =>
                                setState(() => _keyboardOpen = !_keyboardOpen),
                            onStrip: () =>
                                setState(() => _stripOpen = !_stripOpen),
                            onHide: () => setState(() => _railHidden = true),
                            onShow: () => setState(() => _railHidden = false),
                          ),
                        ),
                    ],
                  ),
                ),
                KeysLayer(
                  stripVisible: _stripOpen,
                  keyboardOpen: _keyboardOpen,
                  // The shell is not the compositor on the other end, so the
                  // key that talks to one is drawn and does nothing here.
                  inertModifiers: const {StickyModifier.superKey},
                  onCharacter: _onCharacter,
                  onKeysym: _onKeysym,
                  onKeyboardClosed: _onKeyboardClosed,
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The view, keyed by session so switching tabs swaps the whole thing rather
/// than repainting one terminal with another's buffer.
///
/// The soft keyboard is the strip's, not the view's: [KeysLayer] holds the
/// field the IME writes into for the whole route, and a second input
/// connection under the terminal would fight it for focus.
class _Terminal extends StatelessWidget {
  const _Terminal({required this.session});

  final ShellSession session;

  @override
  Widget build(BuildContext context) {
    return TerminalView(
      session.terminal,
      key: ValueKey('shell-terminal-${session.number}'),
      theme: _shellTheme,
      textStyle: _shellTextStyle,
      cursorType: TerminalCursorType.block,
      hardwareKeyboardOnly: true,
      padding: const EdgeInsets.all(Spacing.md),
    );
  }
}

/// `/ <HOST> SHELL` and, on its right, the active session's state.
class _Crumb extends StatelessWidget {
  const _Crumb({
    required this.host,
    required this.session,
    required this.onBack,
    required this.onRetry,
  });

  final Host host;
  final ShellSession? session;
  final VoidCallback onBack;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final state = session?.state;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.screenEdge,
        vertical: Spacing.md,
      ),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onBack,
              child: Text(
                '/ ${host.name.toUpperCase()} SHELL',
                style: HotlineText.breadcrumb,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          // Live says nothing the prompt is not already saying.
          if (state != null && state is! ShellLive) ...[
            const SizedBox(width: Spacing.lg),
            _State(host: host, state: state, onRetry: onRetry),
          ],
        ],
      ),
    );
  }
}

class _State extends StatelessWidget {
  const _State({
    required this.host,
    required this.state,
    required this.onRetry,
  });

  final Host host;
  final ShellState state;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    switch (state) {
      case ShellConnecting():
        return const Text('CONNECTING', style: HotlineText.panelHeader);
      case ShellLive():
        return const SizedBox.shrink();
      case ShellExited(:final code):
        // A shell that ended is not a failure — it is what `exit` does — so it
        // is drawn in the resting ink and not the warning one.
        return _WithRetry(
          onRetry: onRetry,
          child: Text('EXITED ${code ?? '—'}', style: HotlineText.panelHeader),
        );
      case ShellFailed(:final kind):
        return _WithRetry(
          onRetry: onRetry,
          child: Text(
            shellReason(kind, host.name),
            style: HotlineText.panelHeader.copyWith(
              color: HotlineColors.warning,
            ),
          ),
        );
    }
  }
}

/// Both the ways a session can end come with the one way back. There is no
/// reconnect loop behind it.
class _WithRetry extends StatelessWidget {
  const _WithRetry({required this.onRetry, required this.child});

  final VoidCallback? onRetry;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        child,
        const SizedBox(width: Spacing.lg),
        PanelAffordance('RETRY', showIcon: false, onTap: onRetry),
      ],
    );
  }
}

/// The tabs: one cell per session in the order opened, `+` while there is room
/// for another, and `×` at the far end for the one on screen.
class _TabRow extends StatelessWidget {
  const _TabRow({
    required this.sessions,
    required this.active,
    required this.canOpen,
    required this.onSelect,
    required this.onNew,
    required this.onClose,
  });

  final List<ShellSession> sessions;
  final ShellSession? active;
  final bool canOpen;
  final void Function(ShellSession session) onSelect;
  final VoidCallback onNew;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: _tabRowHeight,
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: HotlineColors.borderSubtle)),
      ),
      child: Row(
        children: [
          const SizedBox(width: Spacing.screenEdge),
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
          const Spacer(),
          if (onClose != null)
            _TabCell(
              key: const ValueKey('shell-tab-close'),
              label: '×',
              onTap: onClose!,
            ),
          const SizedBox(width: Spacing.screenEdge),
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
    final tint = active ? HotlineColors.accent : HotlineColors.textMuted;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minWidth: TapTargets.minHeight),
        height: _tabRowHeight,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          // The underline is the whole of what marks the active tab beyond its
          // ink: a filled cell would read as a button, and these are tabs.
          border: Border(
            bottom: BorderSide(
              color: active ? HotlineColors.accent : const Color(0x00000000),
              width: Borders.hairline * 2,
            ),
          ),
        ),
        child: Text(
          label,
          style: HotlineText.panelHeader.copyWith(color: tint),
        ),
      ),
    );
  }
}
