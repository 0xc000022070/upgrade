import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:striked/data/repositories/host_repository.dart';
import 'package:striked/design/tokens.dart';
import 'package:striked/design/components/cell_divider.dart';
import 'package:striked/design/components/key_cell.dart';
import 'package:striked/design/components/list_row.dart';
import 'package:striked/design/components/panel_sheet.dart';
import 'package:striked/design/components/panel_text_action.dart';
import 'package:striked/design/components/scan_sweep.dart';
import 'package:striked/design/icons/striked_icon.dart';
import 'package:striked/design/icons/striked_icons.dart';
import 'package:striked/design/motion.dart';
import 'package:striked/design/spacing.dart';
import 'package:striked/platform/shell/shell_connection.dart';
import 'package:striked/features/hosts/host_strip.dart';
import 'package:striked/features/shell/session/shell_sessions.dart';
import 'package:striked/features/shell/shell_status.dart';

const _headerHeight = TapTargets.minHeight;

const _reasonHeight = 32.0;

const _detailHeight = 56.0;

const _tabMaxWidth = 88.0;

const _fadeWidth = Spacing.xxl;

/// A login shell's title is who and where (`luis@nyx: ~/Projects/striked`), and the where
/// is the half that tells two tabs apart. A title with a space in it is a sentence the
/// program wrote and is kept as it stands, slashes included: `vim design/SPEC.md` is not
/// a path.
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

String shellSessionLabel(ShellSession session) => shellTabLabel(
  session.title?.trim().isNotEmpty == true
      ? session.title
      : session.repository ?? session.cwd,
  session.number,
);

/// Outside the header: a tap on another host's tab brings up a new header before the
/// second tap lands.
ShellSession? _tapped;
Timer? _tapWindow;

class ShellHeader extends StatefulWidget {
  const ShellHeader({
    super.key,
    required this.host,
    required this.groups,
    required this.active,
    required this.newHosts,
    required this.folded,
    required this.onSelect,
    required this.onFold,
    required this.onMoveTab,
    required this.onMoveGroup,
    required this.onNew,
    required this.onClose,
    required this.onStop,
    required this.onReconnect,
    required this.onDiff,
    this.diffReady = false,
    this.onMachine,
    this.machineAlert = false,
    this.reasonLine,
    this.onPin,
    this.pinStale = false,
  });
  final Host host;
  final List<(Host, List<ShellSession>)> groups;
  final ShellSession? active;
  final List<Host> newHosts;

  final bool Function(Host host) folded;

  final void Function(Host host, ShellSession session) onSelect;
  final ValueChanged<Host> onFold;
  final void Function(Host host, int from, int to) onMoveTab;
  final void Function(int from, int to) onMoveGroup;
  final ValueChanged<Host> onNew;
  final VoidCallback? onClose;
  final ValueChanged<ShellSession>? onStop;

  final ValueChanged<ShellSession>? onReconnect;

  /// Null when there is none to open — a host with no registered directory and a tab that
  /// has never said where it is.
  final VoidCallback? onDiff;

  /// False dims the mark and takes its tap away: a tap that can only answer `NOT A
  /// CHECKOUT` is a tap spent on what the app already knew.
  final bool diffReady;

  final VoidCallback? onMachine;

  final bool machineAlert;

  final String? reasonLine;

  /// Non-null while a passphrase ask the user swiped away is still open on the host.
  final VoidCallback? onPin;

  final bool pinStale;

  @override
  State<ShellHeader> createState() => _ShellHeaderState();
}

class _ShellHeaderState extends State<ShellHeader> {
  /// One key rather than one per tab: the active tab is the only one ever asked where it is.
  final _activeTab = GlobalKey();

  final _newMenu = MenuController();
  var _newMenuOpen = false;

  var _past = (before: false, after: false);

  @override
  void initState() {
    super.initState();
    // Restored tabs are in the store before the header is ever built, so the active
    // one is already past the edge on the first layout with nothing having moved
    // it. Placed rather than scrolled to: there was no earlier position for the
    // strip to travel from.
    _revealActive(Duration.zero);
  }

  @override
  void didUpdateWidget(ShellHeader old) {
    super.didUpdateWidget(old);
    if (old.active == widget.active && _count(old) == _count(widget)) return;
    _revealActive(Motion.fast);
  }

  int _count(ShellHeader header) =>
      header.groups.fold(0, (total, group) => total + group.$2.length);

  /// After the frame that lays the strip out: a tab the build put there has no box to bring
  /// into view until it has been through a layout.
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

  bool _onStripMetrics(ScrollMetricsNotification notification) {
    if (notification.depth != 0) return false;
    final metrics = notification.metrics;
    final past = (
      before: metrics.extentBefore > 0,
      after: metrics.extentAfter > 0,
    );
    if (past != _past) setState(() => _past = past);
    return false;
  }

  /// Always masked, even with nothing past either end: a mask that came and went would
  /// put the strip under a new parent and throw its scroll offset away.
  Widget _faded(Widget strip) {
    final past = _past;
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (bounds) {
        final edge = (_fadeWidth / bounds.width).clamp(0.0, 0.5);
        return LinearGradient(
          colors: [
            past.before ? Colors.transparent : Colors.white,
            Colors.white,
            Colors.white,
            past.after ? Colors.transparent : Colors.white,
          ],
          stops: [0, edge, 1 - edge, 1],
        ).createShader(bounds);
      },
      child: strip,
    );
  }

  Widget _lifted(Widget child, int index, Animation<double> animation) =>
      ColoredBox(color: context.tokens.surfaceSecondary, child: child);

  @override
  Widget build(BuildContext context) {
    final onClose = widget.onClose;
    final onDiff = widget.onDiff;
    // The menu is an overlay rather than a route, so back would pop the sheet under it.
    return PopScope(
      canPop: !_newMenuOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _newMenu.close();
      },
      child: Container(
        key: const ValueKey('shell-header'),
        height: _headerHeight,
        foregroundDecoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: context.tokens.borderSubtle),
          ),
        ),
        child: Row(
          children: [
            const SizedBox(width: Spacing.screenEdge - Spacing.sm),
            // The strip is the one part of the row that gives way: the cells beside it
            // keep the size of what they hold, and nine shells open scroll inside
            // whatever is left rather than overflowing the row.
            Expanded(
              child: NotificationListener<ScrollMetricsNotification>(
                onNotification: _onStripMetrics,
                child: _faded(
                  ReorderableListView(
                    key: const ValueKey('shell-strip'),
                    scrollDirection: Axis.horizontal,
                    buildDefaultDragHandles: false,
                    proxyDecorator: _lifted,
                    onReorderItem: widget.onMoveGroup,
                    footer: widget.newHosts.isEmpty ? null : _plus(context),
                    children: [
                      for (final (index, (group, sessions))
                          in widget.groups.indexed)
                        _group(context, index, group, sessions),
                    ],
                  ),
                ),
              ),
            ),
            if (widget.onPin case final onPin?)
              _TabCell(
                key: const ValueKey('shell-tab-pin'),
                label: 'UNLOCK',
                icon: StrikedIcons.sshKey,
                tint: widget.pinStale
                    ? context.tokens.warning
                    : context.tokens.accent,
                onTap: onPin,
              ),
            if (onDiff != null)
              _TabCell(
                key: const ValueKey('shell-tab-diff'),
                label: 'DIFF',
                icon: StrikedIcons.branch,
                dimmed: !widget.diffReady,
                onTap: widget.diffReady ? onDiff : null,
              ),
            if (widget.onMachine case final onMachine? when widget.machineAlert)
              _TabCell(
                key: const ValueKey('shell-tab-machine'),
                label: 'MACHINE',
                icon: StrikedIcons.systemServer,
                tint: context.tokens.warning,
                onTap: onMachine,
              ),
            if (onClose != null) ...[
              const CellDivider(),
              _TabCell(
                key: const ValueKey('shell-tab-close'),
                label: '×',
                onTap: onClose,
              ),
            ],
            SizedBox(width: onClose != null ? Spacing.sm : Spacing.screenEdge),
          ],
        ),
      ),
    );
  }

  Widget _group(
    BuildContext context,
    int index,
    Host group,
    List<ShellSession> sessions,
  ) {
    final folded = widget.folded(group);
    final front = group.id == widget.host.id;
    final shown = [
      for (final session in sessions)
        if (!folded || (front && session == widget.active)) session,
    ];
    return Padding(
      key: ValueKey('shell-group-${group.id}'),
      padding: const EdgeInsets.only(right: Spacing.sm),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ReorderableDelayedDragStartListener(
            index: index,
            child: HostGroupCell(
              key: ValueKey('shell-group-label-${group.id}'),
              name: group.name,
              system: group.system,
              hostId: group.id,
              front: front,
              hidden: sessions.length - shown.length,
              onTap: () => widget.onFold(group),
            ),
          ),
          ReorderableListView(
            scrollDirection: Axis.horizontal,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            proxyDecorator: _lifted,
            // Folded, the list holds only what is shown, so a move among it would not
            // say where the tab goes among the ones that are not.
            onReorderItem: (from, to) {
              if (folded) return;
              widget.onMoveTab(group, from, to);
            },
            children: [
              for (final (slot, session) in shown.indexed)
                ReorderableDelayedDragStartListener(
                  key: ValueKey('shell-tab-${group.id}-${session.number}'),
                  index: slot,
                  enabled: !folded,
                  child: KeyedSubtree(
                    key: session == widget.active ? _activeTab : null,
                    child: _TabCell(
                      key: session == widget.active
                          ? const ValueKey('shell-tab-active')
                          : null,
                      label: shellSessionLabel(session),
                      session: session,
                      grouped: true,
                      active: session == widget.active,
                      onTap: () => _tap(group, session),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  void _tap(Host group, ShellSession session) {
    final again = _tapped == session;
    _tapWindow?.cancel();
    _tapped = again ? null : session;
    _tapWindow = again ? null : Timer(kDoubleTapTimeout, () => _tapped = null);
    if (again) {
      unawaited(_readout(session));
    } else {
      widget.onSelect(group, session);
    }
  }

  Future<void> _readout(ShellSession session) {
    final title = '${session.host.name.toUpperCase()} ${session.number}';
    final onStop = widget.onStop;
    final onReconnect = widget.onReconnect;
    final onMachine = widget.onMachine;
    return showPanelSheet<void>(
      context,
      title: title,
      // The session is read again on every notify: a tab that comes back under the open
      // sheet takes its `STOP` and `RECONNECT` away with it, rather than leaving controls
      // that would answer nothing.
      builder: (context) => ListenableBuilder(
        listenable: session,
        builder: (context, _) {
          final state = session.state;
          final redialable = session.redialable;
          final stale = state is ShellLive && session.controlStale;
          final failure = stale
              ? switch (session.controlFailure) {
                  final control? => (
                    kind: control.kind,
                    detail: control.detail,
                  ),
                  null => null,
                }
              : state.failure;
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
                  if (stale)
                    ListRow(
                      key: const ValueKey('shell-info-background'),
                      title: 'DIRECTORY, AGENT, PASSPHRASE',
                      subtitle: session.controlFailure == null
                          ? 'STALE · HOST RECONNECTING'
                          : 'STALE · RECONNECT FAILED',
                      subtitleColor: context.tokens.warning,
                    ),
                ],
              ),
              if (failure != null)
                ShellReasonRow(
                  host: session.host,
                  kind: failure.kind,
                  detail: failure.detail,
                  line: stale ? null : widget.reasonLine,
                ),
              if (onReconnect != null && (redialable || stale)) ...[
                const SheetRule(),
                PanelTextAction(
                  key: const ValueKey('shell-info-reconnect'),
                  label: 'RECONNECT',
                  icon: StrikedIcons.sync,
                  onTap: () {
                    Navigator.of(context).pop();
                    onReconnect(session);
                  },
                ),
              ],
              if (onStop != null &&
                  (state is ShellDropped || state is ShellWaiting)) ...[
                const SheetRule(),
                PanelTextAction(
                  key: const ValueKey('shell-info-stop'),
                  label: 'STOP',
                  icon: StrikedIcons.close,
                  onTap: () {
                    Navigator.of(context).pop();
                    onStop(session);
                  },
                ),
              ],
              if (onMachine != null) ...[
                const SheetRule(),
                PanelTextAction(
                  key: const ValueKey('shell-info-machine'),
                  label: 'MACHINE',
                  icon: StrikedIcons.systemServer,
                  onTap: () {
                    Navigator.of(context).pop();
                    onMachine();
                  },
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _plus(BuildContext context) {
    return HostMenu(
      key: const ValueKey('shell-strip-plus'),
      title: 'NEW SHELL ON',
      hosts: widget.newHosts,
      current: widget.host.id,
      itemKey: (host) => 'shell-new-host-${host.id}',
      onPick: widget.onNew,
      controller: _newMenu,
      onOpen: () => setState(() => _newMenuOpen = true),
      onClose: () => setState(() => _newMenuOpen = false),
      builder: (context, controller, child) => _TabCell(
        key: const ValueKey('shell-tab-new'),
        label: '+',
        onTap: controller.isOpen ? controller.close : controller.open,
      ),
    );
  }
}

String _stateWord(ShellState state) => switch (state) {
  ShellLive() => 'LIVE',
  ShellConnecting() => 'CONNECTING',
  ShellReconnecting() => 'RECONNECTING',
  ShellDisconnected() => 'DISCONNECTED',
  ShellDropped(:final attempt) =>
    'RECONNECTING $attempt/${shellReconnectDelays.length}',
  ShellExited(:final code) => 'EXITED ${code ?? '—'}',
  ShellWaiting() => 'WAITING',
  ShellFailed() => 'FAILED',
};

String _transportWord(ShellSession session) {
  final carried = switch (session.state) {
    ShellLive(:final transport) ||
    ShellReconnecting(:final transport) ||
    ShellDisconnected(:final transport) => transport,
    _ => session.connection?.transport,
  };
  return carried?.name.toUpperCase() ?? '—';
}

/// Only the failures the schedule gave up on or never took reach this row: a key the host
/// rejected and a key that changed are not waited out, they are read and acted on
/// somewhere else. A tap opens the detail and a second puts it away; with nothing under
/// the line the row is not a button and does not answer one.
class ShellReasonRow extends StatefulWidget {
  const ShellReasonRow({
    super.key,
    required this.host,
    required this.kind,
    this.detail,
    this.line,
  });

  final Host host;
  final ShellFailureKind kind;
  final String? detail;

  final String? line;

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
                      widget.line ?? widget.kind.line.on(widget.host.name),
                      style: context.tokens.panelHeader.copyWith(
                        color: context.tokens.warning,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (detail != null)
                    StrikedIcon(
                      _open ? StrikedIcons.collapse : StrikedIcons.expand,
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
    this.session,
    this.active = false,
    this.grouped = false,
    this.dimmed = false,
    this.tint,
  }) : assert(label != null || icon != null, 'a word or a mark, not neither');

  final String? label;

  final StrikedIcons? icon;

  final bool dimmed;

  final ShellSession? session;

  final bool active;
  final bool grouped;
  final VoidCallback? onTap;

  /// What the cell is drawn in, when what it is drawn in is not the cell's own business:
  /// the machine mark goes to warning while the machine is why the tab is down, rather
  /// than taking the ink of whether it is the tab on screen.
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
        // The cell takes the row it is in rather than setting a height of its own, so
        // its underline sits on the row's edge and the hairline under the header does
        // not push it over.
        height: double.infinity,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border(
            bottom: active || grouped
                ? BorderSide(
                    color: active
                        ? context.tokens.accent
                        : context.tokens.borderNormal,
                    width: Borders.hairline * 2,
                  )
                : BorderSide.none,
          ),
        ),
        child: _TabScan(
          session: session,
          active: active,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (session case final session?) ...[
                ShellStateMark(session: session),
                const SizedBox(width: Spacing.sm),
              ],
              // The cap is on the word and not on the cell: a Container that aligns
              // its child takes every pixel its constraints allow, so a cell capped
              // at [_tabMaxWidth] is that wide even when it says `1`.
              if (icon case final icon?)
                Semantics(
                  label: label,
                  child: StrikedIcon(icon, size: IconSizes.sm, color: tint),
                )
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
      ),
    );
  }
}

class _TabScan extends StatelessWidget {
  const _TabScan({
    required this.session,
    required this.active,
    required this.child,
  });

  final ShellSession? session;
  final bool active;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final session = this.session;
    if (session == null) return child;
    return ListenableBuilder(
      listenable: Listenable.merge([session, session.painted]),
      builder: (context, child) {
        final tokens = context.tokens;
        final lit = switch ((session.recovering, session.awaitingHost)) {
          (true, _) => tokens.warning,
          (_, true) => active ? tokens.accent : tokens.textPrimary,
          _ => null,
        };
        if (lit == null) return child!;
        return ScanSweep(base: tokens.textDisabled, lit: lit, child: child!);
      },
      child: child,
    );
  }
}
