import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../data/repositories/host_repository.dart';
import '../../design/colors.dart';
import '../../design/components/key_cell.dart';
import '../../design/components/panel.dart';
import '../../design/icons/spectacle_icon.dart';
import '../../design/icons/spectacle_icons.dart';
import '../../design/motion.dart';
import '../../design/spacing.dart';
import '../../design/typography.dart';
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

/// How much of the header the word between the cells may take. The tabs are
/// what gives way on a narrow row, but not all of it: a long state word is
/// still cut before it leaves the strip nothing to scroll.
const _statusShare = 0.4;

/// The word one tab is drawn with: what its shell calls itself, cut down to
/// what a cell holds, and its number until it calls itself anything.
///
/// A login shell's title is who and where — `luis@nyx: ~/Projects/spectacle` —
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
    required this.canOpen,
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
  final bool canOpen;

  /// Opens the list of every shell on every host, or null when this is the
  /// only host with one.
  final VoidCallback? onSwitchHost;
  final void Function(ShellSession session) onSelect;
  final VoidCallback onNew;
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
  void didUpdateWidget(ShellHeader old) {
    super.didUpdateWidget(old);
    if (old.active == widget.active &&
        old.sessions.length == widget.sessions.length) {
      return;
    }
    // After the frame that lays the new strip out: a tab opened this build has
    // no box to bring into view until it has been through a layout.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final tab = _activeTab.currentContext;
      if (!mounted || tab == null) return;
      Scrollable.ensureVisible(
        tab,
        alignment: 0.5,
        duration: Motion.fast,
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
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: SpectacleColors.borderSubtle)),
      ),
      child: LayoutBuilder(
        builder: (context, box) => Row(
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
                    if (widget.canOpen)
                      _TabCell(
                        key: const ValueKey('shell-tab-new'),
                        label: '+',
                        onTap: widget.onNew,
                      ),
                  ],
                ),
              ),
            ),
            if (onDiff != null)
              _TabCell(
                key: const ValueKey('shell-tab-diff'),
                icon: SpectacleIcons.branch,
                dimmed: !widget.diffReady,
                onTap: widget.diffReady ? onDiff : null,
              ),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: box.maxWidth * _statusShare,
              ),
              child: _Middle(state: active?.state, onStop: widget.onStop),
            ),
            if (onClose != null)
              _TabCell(
                key: const ValueKey('shell-tab-close'),
                label: '×',
                onTap: onClose,
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

/// Where the session is when it is not live. Nothing at all while it is: what
/// the shell calls itself is already the tab's word, and the pane under the row
/// says the rest.
class _Middle extends StatelessWidget {
  const _Middle({required this.state, required this.onStop});

  final ShellState? state;
  final VoidCallback? onStop;

  @override
  Widget build(BuildContext context) {
    final word = switch (state) {
      null => null,
      ShellLive() => null,
      ShellConnecting() => 'CONNECTING',
      ShellDropped(:final attempt) =>
        'RECONNECTING $attempt/${shellReconnectDelays.length}',
      ShellExited(:final code) => 'EXITED ${code ?? '—'}',
      // Not the failure's words: the schedule is spent but the tab is not
      // over, and the row underneath is already saying what it hit.
      ShellWaiting() => 'WAITING',
      ShellFailed(:final kind) => kind.line.short,
    };
    if (word == null) return const SizedBox.shrink();
    final between = state is ShellDropped || state is ShellWaiting;
    final label = Text(
      word,
      style: between
          ? SpectacleText.panelHeader.copyWith(color: SpectacleColors.textMuted)
          : SpectacleText.panelHeader,
      textAlign: TextAlign.right,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    // The only hit target the row carries. Dialling again is the app's job, so
    // there is nothing to press while it works — stopping it is the one part
    // of a reconnect that is a decision, and only the user can make it.
    // The word takes the room it needs and no more: while a shell is live
    // there is nothing here at all, and the strip has the row to itself.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
      child: !between || onStop == null
          ? label
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(child: label),
                const SizedBox(width: Spacing.lg),
                PanelAffordance('STOP', showIcon: false, onTap: onStop!),
              ],
            ),
    );
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
                      style: SpectacleText.panelHeader.copyWith(
                        color: SpectacleColors.warning,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (detail != null)
                    SpectacleIcon(
                      _open ? SpectacleIcons.collapse : SpectacleIcons.expand,
                      size: 12,
                      color: SpectacleColors.textMuted,
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
      decoration: const BoxDecoration(
        color: SpectacleColors.surfacePrimary,
        border: Border(top: BorderSide(color: SpectacleColors.borderSubtle)),
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
                child: Text(detail, style: SpectacleText.rowSubtitle),
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
  }) : assert(label != null || icon != null, 'a word or a mark, not neither');

  final String? label;

  /// Drawn in place of the word. The row holds nine tabs before it holds
  /// anything else, and a mark costs a mark's width where a word costs four
  /// letters of one.
  final SpectacleIcons? icon;

  /// Drawn, and not tappable. What it means is the cell's own: the diff mark
  /// dims where the tab is standing in no checkout.
  final bool dimmed;

  /// What the shell in this tab is doing, drawn as the dot the cards carry.
  /// Null on the cells that hold no shell — the plus and the close.
  final ShellState? state;

  final bool active;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tint = switch ((active, dimmed)) {
      (true, _) => SpectacleColors.accent,
      (false, true) => SpectacleColors.textDisabled,
      (false, false) => SpectacleColors.textMuted,
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
            bottom: BorderSide(
              color: active ? SpectacleColors.accent : const Color(0x00000000),
              width: Borders.hairline * 2,
            ),
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
              SpectacleIcon(icon, size: IconSizes.sm, color: tint)
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: _tabMaxWidth),
                child: Text(
                  label!,
                  style: SpectacleText.panelHeader.copyWith(color: tint),
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
