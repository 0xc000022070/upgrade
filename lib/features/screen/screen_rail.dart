import 'package:flutter/widgets.dart';

import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/design/icons/upgrade_icon.dart';
import 'package:upgrade/design/icons/upgrade_icons.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/platform/device.dart';

/// Small on purpose: the framework's own touch slop is the gate on whether this was a
/// deliberate horizontal pull at all, and only what comes after it is counted here. The
/// rail sits a hair from the left edge, so a drag towards it has barely twenty logical
/// pixels of room.
const _dragThreshold = 4.0;

const _handleWidth = 8.0;

/// Android's back gesture eats a pointer that goes down within about 24 px of the edge,
/// so a handle only as wide as it is drawn can never be dragged back: the region has to
/// reach past that zone, and the part of it that is not the handle is transparent.
const _footprintWidth =
    Spacing.md + TapTargets.minHeight + Borders.hairline * 2;

const _slide = Duration(milliseconds: 140);

class ScreenRail extends StatefulWidget {
  const ScreenRail({
    super.key,
    required this.keyboardOpen,
    required this.stripOpen,
    required this.cropArmed,
    required this.scrollArmed,
    required this.hidden,
    required this.onKeyboard,
    required this.onStrip,
    required this.onCrop,
    required this.onScroll,
    required this.onHide,
    required this.onShow,
  });

  final bool keyboardOpen;
  final bool stripOpen;

  final bool cropArmed;
  final bool scrollArmed;

  final bool hidden;

  final VoidCallback onKeyboard;
  final VoidCallback onStrip;
  final VoidCallback onCrop;
  final VoidCallback onScroll;
  final VoidCallback onHide;
  final VoidCallback onShow;

  @override
  State<ScreenRail> createState() => _ScreenRailState();
}

class _ScreenRailState extends State<ScreenRail> {
  /// Accumulated across one drag rather than read off its end velocity: a slow deliberate
  /// pull ends at almost no velocity and still means what it says.
  double _dragged = 0;

  /// An [Alignment] y, so a resize never strands the rail off the picture.
  double _along = 0;

  void _onMove(DragUpdateDetails details, double room) {
    if (room <= 0) return;
    setState(
      () => _along = (_along + details.delta.dy * 2 / room).clamp(-1, 1),
    );
  }

  void _onDragEnd(bool toward) {
    if (toward) {
      if (_dragged > _dragThreshold) widget.onShow();
    } else if (_dragged < -_dragThreshold) {
      widget.onHide();
    }
  }

  final _handleKey = GlobalKey();
  final _panelKey = GlobalKey();

  /// Read from the alignment rather than the painted box, so a slide in flight already
  /// reports where it lands.
  void _exclude(bool current) {
    if (!mounted) return;
    final parent = context.findRenderObject() as RenderBox?;
    final child =
        (widget.hidden ? _handleKey : _panelKey).currentContext
                ?.findRenderObject()
            as RenderBox?;
    final shown =
        current &&
        parent != null &&
        parent.hasSize &&
        child != null &&
        child.hasSize;
    Device.excludeGestures(this, [
      if (shown)
        Alignment(-1, _along)
            .inscribe(child.size, Offset.zero & parent.size)
            .shift(parent.localToGlobal(Offset.zero)),
    ], MediaQuery.devicePixelRatioOf(context));
  }

  @override
  void dispose() {
    Device.excludeGestures(this, const [], 1);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final current = ModalRoute.of(context)?.isCurrent ?? true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _exclude(current));
    return LayoutBuilder(
      builder: (context, constraints) => Align(
        alignment: Alignment(-1, _along),
        child: AnimatedSwitcher(
          duration: _slide,
          // The default builder centres the outgoing child on the incoming one, which would walk
          // the handle in from the middle of the picture.
          layoutBuilder: (current, previous) => Stack(
            alignment: Alignment.centerLeft,
            children: [...previous, ?current],
          ),
          transitionBuilder: (child, animation) => SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(-1, 0),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
          child: widget.hidden
              ? _handle(constraints.maxHeight - TapTargets.minHeight)
              : _rail(),
        ),
      ),
    );
  }

  Widget _handle(double room) {
    return GestureDetector(
      key: const ValueKey('rail-handle'),
      // Translucent: drags win at the touch slop, taps and long presses reach the host.
      behavior: HitTestBehavior.translucent,
      onVerticalDragUpdate: (details) => _onMove(details, room),
      onHorizontalDragStart: (_) => _dragged = 0,
      onHorizontalDragUpdate: (details) => _dragged += details.delta.dx,
      onHorizontalDragEnd: (_) => _onDragEnd(true),
      child: Semantics(
        label: 'RAIL',
        button: true,
        onTap: widget.onShow,
        child: SizedBox(
          key: _handleKey,
          width: _footprintWidth,
          height: TapTargets.minHeight,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Container(
              width: _handleWidth,
              height: TapTargets.minHeight,
              decoration: BoxDecoration(
                color: context.tokens.textMuted,
                border: Border.all(
                  color: context.tokens.surfacePrimary,
                  width: Borders.hairline,
                ),
                borderRadius: const BorderRadius.horizontal(
                  right: Radius.circular(Radii.sharp),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _rail() {
    return GestureDetector(
      key: const ValueKey('rail-panel'),
      // Opaque, so the same footprint belongs to the rail shown as hidden, the padding beside
      // the panel included. The toggles are children and still take their own taps first.
      behavior: HitTestBehavior.opaque,
      onHorizontalDragStart: (_) => _dragged = 0,
      onHorizontalDragUpdate: (details) => _dragged += details.delta.dx,
      onHorizontalDragEnd: (_) => _onDragEnd(false),
      child: Padding(
        key: _panelKey,
        padding: const EdgeInsets.only(left: Spacing.md),
        // [Panel] stretches its body to the width it is offered, so an unbounded one here is a
        // full-width bar with the toggles centred in it.
        child: SizedBox(
          width: TapTargets.minHeight + Borders.hairline * 2,
          child: Panel(
            bodyPadding: EdgeInsets.zero,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _RailToggle(
                  key: const ValueKey('rail-keyboard'),
                  icon: UpgradeIcons.keyboard,
                  label: 'KEYBOARD',
                  active: widget.keyboardOpen,
                  onTap: widget.onKeyboard,
                ),
                _RailToggle(
                  key: const ValueKey('rail-keys'),
                  icon: UpgradeIcons.keys,
                  label: 'KEYS',
                  active: widget.stripOpen,
                  onTap: widget.onStrip,
                ),
                _RailToggle(
                  key: const ValueKey('rail-crop'),
                  icon: UpgradeIcons.crop,
                  label: 'CROP',
                  active: widget.cropArmed,
                  onTap: widget.onCrop,
                ),
                _RailToggle(
                  key: const ValueKey('rail-scroll'),
                  icon: UpgradeIcons.scroll,
                  label: 'SCROLL',
                  active: widget.scrollArmed,
                  onTap: widget.onScroll,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RailToggle extends StatelessWidget {
  const _RailToggle({
    super.key,
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final UpgradeIcons icon;

  /// Not drawn. The rail is glyphs only, and this is what each one is called to a screen
  /// reader and to a test.
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tint = active ? context.tokens.accent : context.tokens.textMuted;
    return Semantics(
      label: label,
      toggled: active,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          width: TapTargets.minHeight,
          height: TapTargets.minHeight,
          child: Center(
            child: UpgradeIcon(icon, size: IconSizes.toolbar, color: tint),
          ),
        ),
      ),
    );
  }
}
