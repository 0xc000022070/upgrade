import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/repositories/host_repository.dart';
import '../../design/tokens.dart';
import '../../design/components/key_cell.dart';
import '../../design/components/list_row.dart';
import '../../design/components/panel_sheet.dart';
import '../../design/components/panel_text_action.dart';
import '../../design/icons/dazzle_icon.dart';
import '../../design/icons/dazzle_icons.dart';
import '../../design/motion.dart';
import '../../design/spacing.dart';
import '../../platform/shell/shell_connection.dart';
import 'shell_sessions.dart';
import 'shell_status.dart';

/// What the sheet's grip needs from the route it is a grip for. Named rather
/// than reached for through the route's own type: the header is a header
/// wherever it is drawn, and a page has no drag at all.
abstract interface class SheetDrag {
  void dragStart();

  /// A finger's pixels, against the height they are a share of.
  void dragBy(double pixels, double height);

  void dragEnd(double velocity);

  void dragCancel();
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
class ShellSheetGrip extends StatefulWidget {
  const ShellSheetGrip({super.key, required this.child});

  final Widget child;

  @override
  State<ShellSheetGrip> createState() => _ShellSheetGripState();
}

class _ShellSheetGripState extends State<ShellSheetGrip> {
  SheetDrag? _route;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    _route = switch (route) {
      final SheetDrag drag => drag,
      _ => null,
    };
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

/// The one row above the terminal, and the one place in the route that is a
/// fixed size: the tab cells in it are hit targets before they are labels.
const _headerHeight = TapTargets.minHeight;

/// The row under it, drawn only when there is a failure to explain. Shorter
/// than the header because the line itself carries no hit target.
const _reasonHeight = 32.0;

/// How much of the screen the open detail may take before it scrolls inside
/// itself. Four lines of an ssh error, and the terminal keeps the rest.
const _detailHeight = 56.0;

/// How wide one tab may grow before its word is cut off. Two named tabs and
/// part of a third fit the strip on a phone, which is enough to tell the tab
/// in use from the ones beside it without the strip becoming the header. The
/// word is what is cut to it; the cell is as wide as what it holds.
const _tabMaxWidth = 88.0;

/// How wide the host's name may grow before it is cut off. Everything else on
/// the row is fixed — the two edges, the gap after the name, the diff mark and
/// the close — and on a 411 px phone what is left over holds two tab cells and
/// the plus only while the name stops here. A name is the host's, not the
/// row's: past this it is read from the switcher, not from the header.
const _hostMaxWidth = 112.0;

/// The word one tab is drawn with: what its shell calls itself, cut down to
/// what a cell holds, and its number until it calls itself anything.
///
/// A login shell's title is who and where — `luis@nyx: ~/Projects/dazzle` —
/// and the where is the half that tells two tabs apart. A title with a space in
/// it is a sentence the program wrote and is kept as it stands, slashes
/// included: `vim design/SPEC.md` is not a path.
String shellTabLabel(String? title, int number) {
  final named = title?.trim() ?? '';
  if (named.isEmpty) return '$number';
  final said = named.indexOf(': ');
  final rest = said == -1 ? named : named.substring(said + 2).trim();
  if (rest.isEmpty) return '$number';
  if (!rest.contains(' ') && rest.contains('/')) {
    final segments = rest.split('/').where((segment) => segment.isNotEmpty);
    if (segments.isNotEmpty) return segments.last;
  }
  return rest;
}

/// The route's whole chrome: the host, its tabs, what the shell calls itself,
/// and the way to close the one on screen — one row, because everything else
/// on this route is the terminal.
class ShellHeader extends StatefulWidget {
  const ShellHeader({
    super.key,
    required this.host,
    required this.sessions,
    required this.active,
    required this.newHosts,
    required this.onSwitchHost,
    required this.onSelect,
    required this.onNew,
    required this.onClose,
    required this.onStop,
    required this.onDiff,
    this.diffReady = false,
  });

  final Host host;
  final List<ShellSession> sessions;
  final ShellSession? active;
  final List<Host> newHosts;

  /// Opens the list of every shell on every host, or null when this is the
  /// only host with one.
  final VoidCallback? onSwitchHost;
  final void Function(ShellSession session) onSelect;
  final ValueChanged<Host> onNew;
  final VoidCallback? onClose;
  final VoidCallback? onStop;

  /// Opens the diff of the repository the tab is standing in, or null when
  /// there is none to open — a host with no registered directory and a tab
  /// that has never said where it is.
  final VoidCallback? onDiff;

  /// Whether there is a checkout for it to open. False dims the mark and takes
  /// its tap away: a tap that can only answer `NOT A CHECKOUT` is a tap spent
  /// on what the app already knew.
  final bool diffReady;

  @override
  State<ShellHeader> createState() => _ShellHeaderState();
}

class _ShellHeaderState extends State<ShellHeader> {
  /// Whichever tab is active, wherever it has moved to. One key rather than one
  /// per tab: the active tab is the only one ever asked where it is.
  final _activeTab = GlobalKey();

  @override
  void initState() {
    super.initState();
    // Restored tabs are in the store before the header is ever built, so the
    // active one is already past the edge on the first layout with nothing
    // having moved it. Placed rather than scrolled to: there was no earlier
    // position for the strip to travel from.
    _revealActive(Duration.zero);
  }

  @override
  void didUpdateWidget(ShellHeader old) {
    super.didUpdateWidget(old);
    if (old.active == widget.active &&
        old.sessions.length == widget.sessions.length) {
      return;
    }
    _revealActive(Motion.fast);
  }

  /// After the frame that lays the strip out: a tab the build put there has no
  /// box to bring into view until it has been through a layout.
  void _revealActive(Duration duration) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final tab = _activeTab.currentContext;
      if (!mounted || tab == null) return;
      Scrollable.ensureVisible(
        tab,
        alignment: 0.5,
        duration: duration,
        curve: Motion.transition,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final host = widget.host;
    final sessions = widget.sessions;
    final active = widget.active;
    final onClose = widget.onClose;
    final onDiff = widget.onDiff;
    return Container(
      key: const ValueKey('shell-header'),
      height: _headerHeight,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: context.tokens.borderSubtle)),
      ),
      child: Row(
        children: [
          const SizedBox(width: Spacing.screenEdge),
          _HostCell(name: host.name, onTap: widget.onSwitchHost),
          const SizedBox(width: Spacing.lg),
          // The strip is the one part of the row that gives way: the cells
          // beside it keep the size of what they hold, and nine shells open
          // scroll inside whatever is left rather than overflowing the row.
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final session in sessions)
                    KeyedSubtree(
                      key: session == active ? _activeTab : null,
                      child: _TabCell(
                        key: ValueKey('shell-tab-${session.number}'),
                        label: shellTabLabel(session.title, session.number),
                        state: session.state,
                        active: session == active,
                        onTap: () => widget.onSelect(session),
                      ),
                    ),
                  if (widget.newHosts.isNotEmpty)
                    MenuAnchor(
                      style: MenuStyle(
                        backgroundColor: WidgetStatePropertyAll(
                          context.tokens.surfaceSecondary,
                        ),
                        surfaceTintColor: const WidgetStatePropertyAll(
                          Colors.transparent,
                        ),
                        shadowColor: const WidgetStatePropertyAll(
                          Colors.transparent,
                        ),
                        elevation: const WidgetStatePropertyAll(0),
                        padding: const WidgetStatePropertyAll(
                          EdgeInsets.all(Spacing.sm),
                        ),
                        minimumSize: const WidgetStatePropertyAll(Size(200, 0)),
                        maximumSize: const WidgetStatePropertyAll(
                          Size(280, 360),
                        ),
                        shape: WidgetStatePropertyAll(
                          RoundedRectangleBorder(
                            borderRadius: const BorderRadius.all(
                              Radius.circular(Radii.sharp),
                            ),
                            side: BorderSide(
                              color: context.tokens.borderNormal,
                            ),
                          ),
                        ),
                      ),
                      alignmentOffset: const Offset(0, Spacing.sm),
                      menuChildren: [
                        for (final host in widget.newHosts)
                          MenuItemButton(
                            key: ValueKey('shell-new-host-${host.id}'),
                            onPressed: () => widget.onNew(host),
                            style: const ButtonStyle(
                              minimumSize: WidgetStatePropertyAll(
                                Size(192, TapTargets.minHeight),
                              ),
                              padding: WidgetStatePropertyAll(
                                EdgeInsets.symmetric(horizontal: Spacing.md),
                              ),
                              shape: WidgetStatePropertyAll(
                                RoundedRectangleBorder(
                                  borderRadius: BorderRadius.all(
                                    Radius.circular(Radii.sharp),
                                  ),
                                ),
                              ),
                            ),
                            child: Row(
                              children: [
                                DazzleIcon(
                                  DazzleIcons.hosts,
                                  size: IconSizes.glyph,
                                  color: context.tokens.textMuted,
                                ),
                                const SizedBox(width: Spacing.md),
                                Expanded(
                                  child: Text(
                                    host.name.toUpperCase(),
                                    style: context.tokens.rowTitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (host.id == widget.host.id)
                                  Text('CURRENT', style: context.tokens.label),
                              ],
                            ),
                          ),
                      ],
                      builder: (context, controller, child) => _TabCell(
                        key: const ValueKey('shell-tab-new'),
                        label: '+',
                        onTap: controller.isOpen
                            ? controller.close
                            : controller.open,
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (onDiff != null)
            _TabCell(
              key: const ValueKey('shell-tab-diff'),
              icon: DazzleIcons.branch,
              dimmed: !widget.diffReady,
              onTap: widget.diffReady ? onDiff : null,
            ),
          _Middle(host: host.name, session: active, onStop: widget.onStop),
          if (onClose != null)
            _TabCell(
              key: const ValueKey('shell-tab-close'),
              label: '×',
              onTap: onClose,
            ),
          const SizedBox(width: Spacing.screenEdge),
        ],
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
    // The cap is on the name and not on the cell, as the tabs cap their word:
    // the cell is as wide as what it holds, and a short name costs the strip
    // nothing.
    final label = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: _hostMaxWidth),
      child: Text(
        name.toUpperCase(),
        style: context.tokens.panelHeader.copyWith(
          color: context.tokens.textPrimary,
        ),
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
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
          DazzleIcon(
            DazzleIcons.expand,
            size: IconSizes.affordance,
            color: context.tokens.textDisabled,
          ),
        ],
      ),
    );
  }
}

/// The one mark in the middle of the row, and everything the row used to
/// spell out behind it. State words and a transport name cost the strip more
/// room than they were worth; a mark costs one cell, and the sheet it opens
/// has the room to say all of it at once.
class _Middle extends StatelessWidget {
  const _Middle({
    required this.host,
    required this.session,
    required this.onStop,
  });

  final String host;
  final ShellSession? session;
  final VoidCallback? onStop;

  @override
  Widget build(BuildContext context) {
    final session = this.session;
    // A shell that is up has nothing to report, and a cell costs the name it
    // stands next to: the middle is empty while the tab is live, and the mark
    // comes out in warning only once there is something behind it to read.
    if (session == null || session.state is ShellLive) {
      return const SizedBox.shrink();
    }
    return _TabCell(
      key: const ValueKey('shell-tab-info'),
      label: '(i)',
      tint: context.tokens.warning,
      onTap: () => _open(context, session),
    );
  }

  Future<void> _open(BuildContext context, ShellSession session) {
    final title = '${host.toUpperCase()} ${session.number}';
    return showPanelSheet<void>(
      context,
      title: title,
      // The session is read again on every notify: a tab that reconnects
      // under the open sheet takes its `STOP` away with it, rather than
      // leaving a control that would answer nothing.
      builder: (context) => ListenableBuilder(
        listenable: session,
        builder: (context, _) {
          final state = session.state;
          // Giving up on a reconnect is the one decision here, and it is one
          // only while something is on a clock or parked off one.
          final stop = state is ShellDropped || state is ShellWaiting
              ? onStop
              : null;
          return PanelSheetBody(
            title: title,
            children: [
              ListRowGroup(
                children: [
                  ListRow(
                    key: const ValueKey('shell-info-state'),
                    title: 'STATE',
                    subtitle: _stateWord(state),
                    subtitleColor: state is ShellLive
                        ? null
                        : context.tokens.warning,
                  ),
                  ListRow(
                    key: const ValueKey('shell-info-transport'),
                    title: 'TRANSPORT',
                    subtitle: _transportWord(session),
                  ),
                ],
              ),
              if (stop != null) ...[
                const SheetRule(),
                PanelTextAction(
                  key: const ValueKey('shell-info-stop'),
                  label: 'STOP',
                  icon: DazzleIcons.close,
                  onTap: () {
                    Navigator.of(context).pop();
                    stop();
                  },
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  String _stateWord(ShellState state) => switch (state) {
    ShellLive() => 'LIVE',
    ShellConnecting() => 'CONNECTING',
    ShellReconnecting() => 'RECONNECTING',
    ShellDisconnected() => 'DISCONNECTED',
    ShellDropped(:final attempt) =>
      'RECONNECTING $attempt/${shellReconnectDelays.length}',
    ShellExited(:final code) => 'EXITED ${code ?? '—'}',
    ShellWaiting() || ShellFailed() => 'DISCONNECTED',
  };

  /// What the tab is talking over: the state's own transport while it carries
  /// one, and the connection's while it does not. A dash once there is no
  /// connection left to ask.
  String _transportWord(ShellSession session) {
    final carried = switch (session.state) {
      ShellLive(:final transport) ||
      ShellReconnecting(:final transport) ||
      ShellDisconnected(:final transport) => transport,
      _ => session.connection?.transport,
    };
    return carried?.name.toUpperCase() ?? '—';
  }
}

/// Why the shell is not there, in a sentence with the host's name in it.
///
/// Only the failures the schedule gave up on or never took reach this row: a
/// key the host rejected and a key that changed are not waited out, they are
/// read and acted on somewhere else.
/// The failure, in the words the header has room for, over the words the
/// transport had. A tap opens the detail and a second puts it away; with
/// nothing under the line the row is not a button and does not answer one.
class ShellReasonRow extends StatefulWidget {
  const ShellReasonRow({
    super.key,
    required this.host,
    required this.kind,
    this.detail,
  });

  final Host host;
  final ShellFailureKind kind;
  final String? detail;

  @override
  State<ShellReasonRow> createState() => _ShellReasonRowState();
}

class _ShellReasonRowState extends State<ShellReasonRow> {
  var _open = false;

  @override
  void didUpdateWidget(ShellReasonRow old) {
    super.didUpdateWidget(old);
    // A failure that changed under the open detail is a different failure.
    if (old.detail != widget.detail) _open = false;
  }

  @override
  Widget build(BuildContext context) {
    final detail = widget.detail;
    return GestureDetector(
      key: const ValueKey('shell-reason'),
      behavior: HitTestBehavior.opaque,
      onTap: detail == null ? null : () => setState(() => _open = !_open),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: _reasonHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Spacing.screenEdge,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.kind.line.on(widget.host.name),
                      style: context.tokens.panelHeader.copyWith(
                        color: context.tokens.warning,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (detail != null)
                    DazzleIcon(
                      _open ? DazzleIcons.collapse : DazzleIcons.expand,
                      size: 12,
                      color: context.tokens.textMuted,
                    ),
                ],
              ),
            ),
          ),
          if (detail != null && _open) _ReasonDetail(detail: detail),
        ],
      ),
    );
  }
}

/// What the machine said, whole. Scrolls rather than grows past a few lines:
/// an ssh error runs long, and the terminal under it is what the user came
/// for.
class _ReasonDetail extends StatelessWidget {
  const _ReasonDetail({required this.detail});

  final String detail;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: context.tokens.surfacePrimary,
        border: Border(top: BorderSide(color: context.tokens.borderSubtle)),
      ),
      padding: const EdgeInsets.fromLTRB(
        Spacing.screenEdge,
        Spacing.sm,
        Spacing.sm,
        Spacing.sm,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: _detailHeight),
              child: SingleChildScrollView(
                child: Text(detail, style: context.tokens.rowSubtitle),
              ),
            ),
          ),
          const SizedBox(width: Spacing.sm),
          KeyCell(
            key: const ValueKey('shell-detail-copy'),
            label: 'COPY',
            minWidth: RowMetrics.minHeight,
            padding: RowMetrics.padding,
            height: RowMetrics.minHeight,
            onTap: () => Clipboard.setData(ClipboardData(text: detail)),
          ),
        ],
      ),
    );
  }
}

class _TabCell extends StatelessWidget {
  const _TabCell({
    super.key,
    this.label,
    this.icon,
    required this.onTap,
    this.state,
    this.active = false,
    this.dimmed = false,
    this.tint,
  }) : assert(label != null || icon != null, 'a word or a mark, not neither');

  final String? label;

  /// Drawn in place of the word. The row holds nine tabs before it holds
  /// anything else, and a mark costs a mark's width where a word costs four
  /// letters of one.
  final DazzleIcons? icon;

  /// Drawn, and not tappable. What it means is the cell's own: the diff mark
  /// dims where the tab is standing in no checkout.
  final bool dimmed;

  /// What the shell in this tab is doing, drawn as the dot the cards carry.
  /// Null on the cells that hold no shell — the plus and the close.
  final ShellState? state;

  final bool active;
  final VoidCallback? onTap;

  /// What the cell is drawn in, when what it is drawn in is not the cell's own
  /// business: the info mark stands in warning for as long as it stands at all,
  /// rather than in the ink of whether it is the tab on screen.
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final tint =
        this.tint ??
        switch ((active, dimmed)) {
          (true, _) => context.tokens.accent,
          (false, true) => context.tokens.textDisabled,
          (false, false) => context.tokens.textMuted,
        };
    final label = this.label;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minWidth: TapTargets.minHeight),
        padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
        // The cell takes the row it is in rather than setting a height of its
        // own, so its underline sits on the row's edge and the hairline under
        // the header does not push it over.
        height: double.infinity,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          // The underline is the whole of what marks the active tab beyond its
          // ink: a filled cell would read as a button, and these are tabs.
          border: Border(
            bottom: active
                ? BorderSide(
                    color: context.tokens.accent,
                    width: Borders.hairline * 2,
                  )
                : BorderSide.none,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (state case final state?) ...[
              ShellStateDot(state: state),
              const SizedBox(width: Spacing.sm),
            ],
            // The cap is on the word and not on the cell: a Container that
            // aligns its child takes every pixel its constraints allow, so a
            // cell capped at [_tabMaxWidth] is that wide even when it says `1`,
            // and the row has nothing left for what the shell is doing.
            if (icon case final icon?)
              DazzleIcon(icon, size: IconSizes.sm, color: tint)
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: _tabMaxWidth),
                child: Text(
                  label!,
                  style: context.tokens.panelHeader.copyWith(color: tint),
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
