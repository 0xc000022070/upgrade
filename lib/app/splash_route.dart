import 'dart:async';

import 'package:flutter/widgets.dart';

import '../design/tokens.dart';
import '../design/sprite.dart';
import '../platform/alert_actions.dart';
import 'alerts_boot.dart';

/// Cold start by construction rather than by a flag: the route is the navigator's first,
/// it replaces itself with Home, and nothing pushes it again. It sits above
/// `AlertsHost` rather than below it — a splash inside the Home route would take the
/// watcher reconciliation and the `OPEN` handler down with it.

/// Long enough that the last frame is a beat rather than a flicker, short enough that the
/// whole route stays well under the 2.5 s budget.
const splashHold = Duration(milliseconds: 420);

class SplashRoute extends StatefulWidget {
  const SplashRoute({super.key, required this.next});

  final WidgetBuilder next;

  @override
  State<SplashRoute> createState() => _SplashRouteState();
}

class _SplashRouteState extends State<SplashRoute> {
  Timer? _handover;
  bool _handedOver = false;

  @override
  void initState() {
    super.initState();
    // An alert's `OPEN` is delivered as soon as Android brings the activity up, which is
    // inside this route's window.
    alertOpenHandler = deferAlertOpen;
    pinOpenHandler = deferPinOpen;
  }

  /// The sprite holds its last frame, so `onDone` arrives exactly once — but a rebuilt
  /// sheet would call it again, and the handover must not be scheduled twice.
  void _played() {
    if (_handedOver) return;
    _handedOver = true;
    _handover = Timer(splashHold, _toHome);
  }

  void _toHome() {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder<void>(
        pageBuilder: (context, _, _) => widget.next(context),
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
      ),
    );
  }

  @override
  void dispose() {
    _handover?.cancel();
    // Only if `AlertsHost` has not already claimed it: the replacement route is built before
    // this one is disposed.
    if (identical(alertOpenHandler, deferAlertOpen)) alertOpenHandler = null;
    if (identical(pinOpenHandler, deferPinOpen)) pinOpenHandler = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: context.tokens.backgroundPrimary,
      child: Center(
        child: Sprite(state: 'splash', scale: 4, onDone: _played),
      ),
    );
  }
}
