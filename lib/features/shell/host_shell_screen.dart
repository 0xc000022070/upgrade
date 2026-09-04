import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../../data/repositories/host_repository.dart';
import '../../design/colors.dart';
import '../../design/components/action_block.dart';
import '../../design/components/panel.dart';
import '../../design/components/panel_sheet.dart';
import '../../design/spacing.dart';
import '../../design/typography.dart';
import '../../platform/host_keys.dart';
import '../../platform/shell/shell_connection.dart';
import '../../platform/vnc/keysyms.dart';
import '../hosts/host_key_sheet.dart';
import 'shell_bar.dart';
import 'shell_sessions.dart';

/// The way in: a host panel's `SHELL >` row on HOSTS, a host row on SSH, or one
/// of that tab's session cards, which names the session it wants on screen.
void openHostShell(BuildContext context, Host host, {ShellSession? session}) {
  Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(
      builder: (_) => HostShellRoute(host: host, session: session),
    ),
  );
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

/// `/ <HOST> SHELL`: the host's own login shell, several at once as tabs.
///
/// The sessions are not here. They live in the store, which outlives every
/// visit — leaving and coming back finds the tabs where they were, still
/// running, so this route's dispose closes nothing but the orientation lock.
class HostShellRoute extends ConsumerStatefulWidget {
  const HostShellRoute({super.key, required this.host, this.session});

  final Host host;

  /// The tab to land on, when the way in named one. Null opens the host's last
  /// active tab, or its first shell when there is none.
  final ShellSession? session;

  @override
  ConsumerState<HostShellRoute> createState() => _HostShellRouteState();
}

class _HostShellRouteState extends ConsumerState<HostShellRoute> {
  /// The route's, not the view's: it survives a tab switch swapping one
  /// [TerminalView] for another, which is what lets the keyboard stay up
  /// across one.
  final _focus = FocusNode(debugLabel: 'shell-terminal');

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

  @override
  void initState() {
    super.initState();
    // Held rather than read where it is used: `ref` is closed by the time
    // dispose runs, and this is the store the listener has to come off.
    _store = ref.read(shellSessionsProvider);
    _store.addListener(_onSessions);
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
      if (wanted != null) {
        sessions.activate(widget.host.id, wanted);
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
    _focus.dispose();
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
    super.dispose();
  }

  late final ShellSessions _store;

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
                  tone: HotlineColors.accent,
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

  /// Whether the IME is up: what the system says it is showing, not what the
  /// view has focus. The two part company when the system back button hides
  /// the keyboard, which leaves the focus where it was.
  bool get _keyboardOpen => MediaQuery.viewInsetsOf(context).bottom > 0;

  void _onKeyboard() {
    if (_keyboardOpen) {
      _focus.unfocus();
    } else if (_focus.hasFocus) {
      // Focus the view already has cannot be asked for again, so the keyboard
      // the system took away is asked back directly.
      SystemChannels.textInput.invokeMethod<void>('TextInput.show');
    } else {
      _focus.requestFocus();
    }
  }

  void _onSticky(ShellSession session, Set<StickyModifier> sticky) {
    _store.arm(session, sticky);
  }

  void _onBytes(ShellSession session, Uint8List bytes) {
    _store.send(session, bytes);
  }

  /// The terminal's own paste, not the wire: a remote that asked for bracketed
  /// paste gets the markers around the text, and one that did not gets the text.
  Future<void> _onPaste(ShellSession session) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    session.terminal.paste(text);
  }

  /// Switching tabs unmounts the view that had focus, which drops it. With the
  /// keyboard up the user is mid-typing, so it is put back on the tab they
  /// landed on rather than making them tap the toggle again.
  void _onSelect(ShellSession session) {
    final refocus = _focus.hasFocus;
    _store.activate(widget.host.id, session);
    if (!refocus) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  void _onNew() {
    _store.open(widget.host, prompt: _askHostKey);
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
            final state = active?.state;
            return Column(
              children: [
                _Header(
                  host: widget.host,
                  sessions: sessions,
                  active: active,
                  canOpen: store.canOpen(widget.host.id),
                  onSelect: _onSelect,
                  onNew: _onNew,
                  onClose: active == null ? null : () => _onClose(active),
                  onStop: active == null
                      ? null
                      : () => store.stopReconnect(active),
                ),
                // The whole of what a failure costs the terminal: one short row,
                // and only while there is a failure.
                if (state is ShellFailed)
                  _ReasonRow(host: widget.host, kind: state.kind),
                Expanded(
                  child: active == null
                      ? const SizedBox.shrink()
                      : _Terminal(session: active, focusNode: _focus),
                ),
                if (active != null)
                  ShellBar(
                    sticky: active.sticky,
                    onSticky: (sticky) => _onSticky(active, sticky),
                    onBytes: (bytes) => _onBytes(active, bytes),
                    onPaste: () => _onPaste(active),
                    keyboardOpen: _keyboardOpen,
                    onKeyboard: _onKeyboard,
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
/// The IME is the terminal's own now: it takes text input, and what it produces
/// runs through the store, which is where the armed modifiers are applied and
/// spent.
class _Terminal extends StatelessWidget {
  const _Terminal({required this.session, required this.focusNode});

  final ShellSession session;
  final FocusNode focusNode;

  @override
  Widget build(BuildContext context) {
    return TerminalView(
      session.terminal,
      key: ValueKey('shell-terminal-${session.number}'),
      focusNode: focusNode,
      theme: _shellTheme,
      textStyle: _shellTextStyle,
      cursorType: TerminalCursorType.block,
      // Plain text: the view turns autocorrect and suggestions off itself, and
      // a keyboard picked for anything else puts the wrong keys under a shell.
      keyboardType: TextInputType.text,
      padding: const EdgeInsets.all(Spacing.md),
    );
  }
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
    required this.onSelect,
    required this.onNew,
    required this.onClose,
    required this.onStop,
  });

  final Host host;
  final List<ShellSession> sessions;
  final ShellSession? active;
  final bool canOpen;
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
        border: Border(bottom: BorderSide(color: HotlineColors.borderSubtle)),
      ),
      child: LayoutBuilder(
        builder: (context, box) => Row(
          children: [
            const SizedBox(width: Spacing.screenEdge),
            Text(
              host.name.toUpperCase(),
              style: HotlineText.panelHeader.copyWith(
                color: HotlineColors.textPrimary,
              ),
            ),
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
          ? HotlineText.panelHeader.copyWith(color: HotlineColors.textMuted)
          : HotlineText.panelHeader,
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
              style: HotlineText.panelHeader.copyWith(
                color: HotlineColors.warning,
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
    final tint = active ? HotlineColors.accent : HotlineColors.textMuted;
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
