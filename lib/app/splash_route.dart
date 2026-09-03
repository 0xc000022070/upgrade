import 'dart:async';

import 'package:flutter/widgets.dart';

import '../design/colors.dart';
import '../design/motion.dart';
import '../design/spacing.dart';
import '../design/sprite.dart';
import '../design/typography.dart';
import '../platform/alert_actions.dart';
import 'alerts_boot.dart';

/// The splash: the mascot's seven frames once, then the word.
///
/// Cold start only, and by construction rather than by a flag — the route is
/// the navigator's first, it replaces itself with Home, and nothing pushes it
/// again, so a resume comes back to whatever Home was showing.
///
/// It sits above `AlertsHost` in the stack rather than below it: the alerts
/// wiring lives in the Home route, so replacing this one leaves it untouched,
/// where a splash *inside* the Home route would have taken the watcher's
/// reconciliation and the `OPEN` handler down with it.

/// How long the word is held before Home takes the screen. Long enough to read
/// eight characters, short enough that the whole route — 1167ms of sprite,
/// [Motion.deliberate] of fade, this — stays under the 2.5s budget.
const splashHold = Duration(milliseconds: 420);

class SplashRoute extends StatefulWidget {
  const SplashRoute({super.key, required this.next});

  /// Home. Built only when the splash is done with the screen.
  final WidgetBuilder next;

  @override
  State<SplashRoute> createState() => _SplashRouteState();
}

class _SplashRouteState extends State<SplashRoute> {
  Timer? _handover;
  bool _word = false;

  @override
  void initState() {
    super.initState();
    // An alert's `OPEN` is delivered as soon as Android brings the activity up,
    // which is inside this route's window. Parking it in the flag a cold launch
    // already uses is what keeps the tap from being dropped; `AlertsHost` takes
    // the handler back when it mounts and replays the flag on its first frame.
    alertOpenHandler = deferAlertOpen;
  }

  /// The sprite holds its last frame from here on, so `onDone` arrives exactly
  /// once — but a rebuilt sheet would call it again, and the handover must not
  /// be scheduled twice.
  void _played() {
    if (_word) return;
    setState(() => _word = true);
    _handover = Timer(Motion.deliberate + splashHold, _toHome);
  }

  void _toHome() {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder<void>(
        pageBuilder: (context, _, _) => widget.next(context),
        // The boot log hard-cuts to the shell, and a fade here would cross two
        // very different grounds.
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
      ),
    );
  }

  @override
  void dispose() {
    _handover?.cancel();
    // Only if `AlertsHost` has not already claimed it: the replacement route is
    // built before this one is disposed, so by here the handler is usually its.
    if (identical(alertOpenHandler, deferAlertOpen)) alertOpenHandler = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: HotlineColors.backgroundPrimary,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Sprite(state: 'splash', scale: 4, onDone: _played),
            const SizedBox(height: Spacing.lg),
            // The word keeps its box from the first frame. Revealed by adding
            // it to the column instead, the sprite would slide up by a line
            // height on the one frame the eye is already on it.
            AnimatedOpacity(
              opacity: _word ? 1 : 0,
              duration: Motion.deliberate,
              curve: Motion.enter,
              child: const Text('HOTLINE_', style: HotlineText.screenTitle),
            ),
          ],
        ),
      ),
    );
  }
}
