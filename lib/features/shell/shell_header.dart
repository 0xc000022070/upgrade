import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../data/repositories/host_repository.dart';
import '../../design/colors.dart';
import '../../design/components/key_cell.dart';
import '../../design/components/panel.dart';
import '../../design/icons/spectacle_icon.dart';
import '../../design/icons/spectacle_icons.dart';
import '../../design/spacing.dart';
import '../../design/typography.dart';
import '../../platform/shell/shell_connection.dart';
import 'shell_sessions.dart';

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

/// How much of the header the tabs may take before they start to scroll inside
/// it. Nine tabs are wider than a phone is, and the title is worth keeping a
/// readable share of the row.
const _tabsShare = 0.55;

/// The route's whole chrome: the host, its tabs, what the shell calls itself,
/// and the way to close the one on screen — one row, because everything else
/// on this route is the terminal.
class ShellHeader extends StatelessWidget {
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
                      shellReason(widget.kind, widget.host.name),
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
