import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import 'package:upgrade/design/motion.dart';
import 'package:upgrade/design/tokens.dart';

abstract interface class SheetDrag {
  void dragStart();

  void dragBy(double pixels, double height);

  void dragEnd(double velocity);

  void dragCancel();
}

const _gripWidth = 36.0;
const _gripHeight = 2.0;
const _gripInset = 5.0;

/// A release faster than this, in px/s, decides on its own: downward leaves, upward
/// stays. Slower, where the finger left the sheet decides.
const _sheetFling = 700.0;

/// A slow release past this share of the sheet's rise leaves.
const _sheetLeaveShare = 1 / 3;

abstract class DragSheetRoute<T> extends PopupRoute<T> implements SheetDrag {
  Key get frameKey;

  Key get ruleKey;

  Widget buildSheet(BuildContext context);

  /// Held for the route's life: a curved animation listens to its parent, and one made in
  /// a build is one nobody disposes.
  CurvedAnimation? _curved;

  /// A tap on the grip ends in the recognizer's cancel with no start before it, and that
  /// is not a drag.
  bool _dragging = false;

  @override
  Color get barrierColor => navigator!.context.tokens.scrim;

  @override
  bool get barrierDismissible => true;

  @override
  Duration get transitionDuration => Motion.normal;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return SheetFrame(
      frameKey: frameKey,
      ruleKey: ruleKey,
      child: buildSheet(context),
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // The gesture flag outlives the finger until the settle lands, so the curve does not
    // swap under a sheet that is still moving.
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

  @override
  void dragStart() {
    _dragging = true;
    navigator!.didStartUserGesture();
  }

  /// The slide is the screen's height, so a finger's pixel is that share off the rise.
  @override
  void dragBy(double pixels, double height) {
    final next = controller!.value - pixels / height;
    controller!.value = next.clamp(0.0, 1.0);
  }

  @override
  void dragEnd(double velocity) {
    if (!_dragging) return;
    final leave = velocity.abs() > _sheetFling
        ? velocity > 0
        : controller!.value < 1 - _sheetLeaveShare;
    _settle(leave: leave);
  }

  @override
  void dragCancel() {
    if (_dragging) _settle(leave: false);
  }

  void _settle({required bool leave}) {
    _dragging = false;
    final nav = navigator!;
    final ctl = controller!;
    if (leave) {
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

class SheetFrame extends StatelessWidget {
  const SheetFrame({
    super.key,
    required this.frameKey,
    required this.ruleKey,
    required this.child,
  });

  final Key frameKey;

  final Key ruleKey;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return Align(
      alignment: Alignment.bottomCenter,
      child: SizedBox(
        key: frameKey,
        height: media.size.height - media.padding.top,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // The frame already stands clear of the status bar.
            MediaQuery.removePadding(
              context: context,
              removeTop: true,
              child: DecoratedBox(
                // In front of the child: the route paints its own ground over the whole box, and a rule
                // behind it would be painted out.
                position: DecorationPosition.foreground,
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(color: context.tokens.borderNormal),
                  ),
                ),
                child: child,
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: IgnorePointer(child: _SheetRule(ruleKey: ruleKey)),
            ),
          ],
        ),
      ),
    );
  }
}

class _SheetRule extends StatelessWidget {
  const _SheetRule({required this.ruleKey});

  final Key ruleKey;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _gripInset + _gripHeight,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: SizedBox(
          key: ruleKey,
          width: _gripWidth,
          height: _gripHeight,
          child: ColoredBox(color: context.tokens.textDisabled),
        ),
      ),
    );
  }
}

class SheetGrip extends StatefulWidget {
  const SheetGrip({super.key, required this.child});

  final Widget child;

  @override
  State<SheetGrip> createState() => _SheetGripState();
}

class _SheetGripState extends State<SheetGrip> {
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
      behavior: HitTestBehavior.opaque,
      // The sheet is under the finger from the first pixel, not from the nineteenth.
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
