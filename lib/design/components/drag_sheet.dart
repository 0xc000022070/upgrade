import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../motion.dart';
import '../tokens.dart';

/// What a sheet's grip drives. The route is what holds the animation, so the
/// drag is answered there and not by the widget under the finger.
abstract interface class SheetDrag {
  void dragStart();

  /// A finger's pixels, against the height they are a share of.
  void dragBy(double pixels, double height);

  void dragEnd(double velocity);

  void dragCancel();
}

/// The rule on the sheet's top edge, which is the whole of what says a surface
/// is a sheet. It is drawn over the row under it rather than above it: the
/// sheet stands flush under the status bar, and the row is the grip.
const _gripWidth = 36.0;
const _gripHeight = 2.0;
const _gripInset = 5.0;

/// A release faster than this, in px/s, decides on its own: downward leaves,
/// upward stays. Slower, where the finger left the sheet decides.
const _sheetFling = 700.0;

/// A slow release past this share of the sheet's rise leaves; short of it,
/// the sheet comes back.
const _sheetLeaveShare = 1 / 3;

/// A modal sheet the finger can take down: the route beneath stays under a
/// wash, the sheet rises from the bottom, and a drag on its grip moves it with
/// the finger.
///
/// The wash is the app's scrim: what shows through it is the screen the sheet
/// was opened from, and it should still read as that screen.
abstract class DragSheetRoute<T> extends PopupRoute<T> implements SheetDrag {
  /// The sheet's box, for a test that measures where the sheet stands.
  Key get frameKey;

  /// The short rule on the top edge.
  Key get ruleKey;

  /// What the sheet holds under its top edge.
  Widget buildSheet(BuildContext context);

  /// Held for the route's life rather than made per frame: a curved animation
  /// listens to its parent, and one made in a build is one nobody disposes.
  CurvedAnimation? _curved;

  /// Up between a drag's start and its landing. A tap on the grip ends in the
  /// recognizer's cancel with no start before it, and that is not a drag.
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
  @override
  void dragStart() {
    _dragging = true;
    navigator!.didStartUserGesture();
  }

  /// A finger's pixel is that share of the screen's height off the rise:
  /// the slide is the screen's height, so the two move one to one.
  @override
  void dragBy(double pixels, double height) {
    final next = controller!.value - pixels / height;
    controller!.value = next.clamp(0.0, 1.0);
  }

  /// A fast release decides by its direction, a slow one by where the sheet
  /// is. Downward is positive, as the screen's y is.
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
class SheetFrame extends StatelessWidget {
  const SheetFrame({
    super.key,
    required this.frameKey,
    required this.ruleKey,
    required this.child,
  });

  /// On the box and not on the frame: the frame fills the screen, and where
  /// the sheet stands is the top edge of the box inside it.
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
            // The frame already stands clear of the status bar, so the safe
            // area inside the route must not stand clear of it again.
            MediaQuery.removePadding(
              context: context,
              removeTop: true,
              child: DecoratedBox(
                // In front of the child: the route paints its own ground over
                // the whole box, and a rule behind it would be painted out.
                position: DecorationPosition.foreground,
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(color: context.tokens.borderNormal),
                  ),
                ),
                child: child,
              ),
            ),
            // Over the first rows of what the sheet holds, and out of the way
            // of its cells: the rule is a sign, and the row under it is the
            // grip.
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

/// The short rule under the sheet's top edge.
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

/// A row as the sheet's grip: a vertical drag on it moves the sheet with the
/// finger, and the release decides whether the sheet leaves or comes back.
/// Nothing at all when the route is a page, which is how a test pumps it.
///
/// The route's own controller is what the drag moves, the way the iOS back
/// swipe moves a page's: the transition already knows how to draw the sheet
/// at any point of its rise, and popping from a part-way value runs the rest
/// of the slide from there.
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
