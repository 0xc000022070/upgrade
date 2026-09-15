import 'package:flutter/widgets.dart';

import '../../design/tokens.dart';
import '../../design/components/panel.dart';
import '../../design/icons/dazzle_icon.dart';
import '../../design/icons/dazzle_icons.dart';
import '../../design/spacing.dart';

/// How far a drag has to carry past the point the recogniser claimed it. Small
/// on purpose: the framework's own touch slop is the gate on whether this was a
/// deliberate horizontal pull at all, and only what comes after it is counted
/// here. The rail sits a hair from the left edge, so a drag towards that edge
/// has barely twenty logical pixels of room — measuring the whole travel would
/// make hiding it a stunt.
const _dragThreshold = 4.0;

/// What is left of the rail once it is off screen: a sliver at the same
/// vertical centre, tall enough to hit. A 1 px keyline of the panel colour
/// around the dim fill, because dim grey on a light desktop is not a shape —
/// the first build's bare sliver could only be found by probing pixels.
const _handleWidth = 8.0;

/// The width the hidden rail keeps as its hit region: the left edge to where
/// the shown rail's right border was. Android's back gesture eats a pointer
/// that goes down within about 24 px of the edge, so a handle that is only as
/// wide as it is drawn can never be dragged back — the region has to reach
/// past that zone, and the part of it that is not the handle is transparent.
const _footprintWidth =
    Spacing.md + TapTargets.minHeight + Borders.hairline * 2;

const _slide = Duration(milliseconds: 140);

/// The rail: a vertical Panel on the left edge of the framebuffer area,
/// vertically centred, over the picture.
///
/// Two toggles, and they are independent — the strip without the keyboard is
/// the AVNC frame the user asked for, and the keyboard without the strip is
/// what typing at a full-screen editor wants. The rail does not hide itself on
/// a timer: the old `DONE` is gone precisely because the rail is what closes
/// whatever it opened, so it has to still be there to close it.
///
/// It does hide on a drag to the left, leaving [_handleWidth] of itself at the
/// edge to come back from, inside a [_footprintWidth] patch that still answers
/// to a drag or a tap. The recogniser is on that patch and on the rail and
/// nowhere else — a drag anywhere else on the picture is a pointer drag at the
/// host, and taking those would break the remote.
class ScreenRail extends StatefulWidget {
  const ScreenRail({
    super.key,
    required this.keyboardOpen,
    required this.stripOpen,
    required this.cropArmed,
    required this.hidden,
    required this.onKeyboard,
    required this.onStrip,
    required this.onCrop,
    required this.onHide,
    required this.onShow,
  });

  final bool keyboardOpen;
  final bool stripOpen;

  /// The third toggle is a mode rather than a layer: while it is up the
  /// pointer is the box being drawn and nothing reaches the host.
  final bool cropArmed;

  /// Held by the route, not here: it is state about this visit to the host's
  /// screen, and it goes when the route goes rather than following the user to
  /// the next machine.
  final bool hidden;

  final VoidCallback onKeyboard;
  final VoidCallback onStrip;
  final VoidCallback onCrop;
  final VoidCallback onHide;
  final VoidCallback onShow;

  @override
  State<ScreenRail> createState() => _ScreenRailState();
}

class _ScreenRailState extends State<ScreenRail> {
  /// Accumulated across one drag rather than read off its end velocity: a slow
  /// deliberate pull ends at almost no velocity and still means what it says.
  double _dragged = 0;

  void _onDragEnd(bool toward) {
    if (toward) {
      if (_dragged > _dragThreshold) widget.onShow();
    } else if (_dragged < -_dragThreshold) {
      widget.onHide();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Centred over the whole framebuffer area rather than pinned to a corner:
    // the same edge in portrait and in landscape, so a rotation keeps the rail
    // where the thumb left it.
    return Align(
      alignment: Alignment.centerLeft,
      child: AnimatedSwitcher(
        duration: _slide,
        // The default builder centres the outgoing child on the incoming one,
        // which would walk the handle in from the middle of the picture.
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
        child: widget.hidden ? _handle() : _rail(),
      ),
    );
  }

  Widget _handle() {
    return GestureDetector(
      key: const ValueKey('rail-handle'),
      // Opaque over the whole footprint, not over the drawn sliver: this is
      // the patch the gesture needs, and it is the one place on the picture
      // where a pointer belongs to the rail instead of to the host.
      behavior: HitTestBehavior.opaque,
      onTap: widget.onShow,
      onHorizontalDragStart: (_) => _dragged = 0,
      onHorizontalDragUpdate: (details) => _dragged += details.delta.dx,
      onHorizontalDragEnd: (_) => _onDragEnd(true),
      child: Semantics(
        label: 'RAIL',
        button: true,
        child: SizedBox(
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
      // Opaque, so the same footprint belongs to the rail shown as hidden,
      // the padding beside the panel included. The toggles are children and
      // still take their own taps first.
      behavior: HitTestBehavior.opaque,
      onHorizontalDragStart: (_) => _dragged = 0,
      onHorizontalDragUpdate: (details) => _dragged += details.delta.dx,
      onHorizontalDragEnd: (_) => _onDragEnd(false),
      child: Padding(
        padding: const EdgeInsets.only(left: Spacing.md),
        // [Panel] stretches its body to the width it is offered, so an
        // unbounded one here is a full-width bar with the toggles centred in
        // it. The rail is as wide as a toggle plus its own border.
        child: SizedBox(
          width: TapTargets.minHeight + Borders.hairline * 2,
          child: Panel(
            bodyPadding: EdgeInsets.zero,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _RailToggle(
                  key: const ValueKey('rail-keyboard'),
                  icon: DazzleIcons.keyboard,
                  label: 'KEYBOARD',
                  active: widget.keyboardOpen,
                  onTap: widget.onKeyboard,
                ),
                _RailToggle(
                  key: const ValueKey('rail-keys'),
                  icon: DazzleIcons.keys,
                  label: 'KEYS',
                  active: widget.stripOpen,
                  onTap: widget.onStrip,
                ),
                _RailToggle(
                  key: const ValueKey('rail-crop'),
                  icon: DazzleIcons.crop,
                  label: 'CROP',
                  active: widget.cropArmed,
                  onTap: widget.onCrop,
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

  final DazzleIcons icon;

  /// Not drawn. The rail is glyphs only, and this is what each one is called to
  /// a screen reader and to a test.
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Dim at rest, accent while the thing it toggles is up. A toggle needs no
    // press tint on top of that — the state it switches to is the feedback, and
    // it lands on the same frame.
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
            child: DazzleIcon(icon, size: IconSizes.toolbar, color: tint),
          ),
        ),
      ),
    );
  }
}
