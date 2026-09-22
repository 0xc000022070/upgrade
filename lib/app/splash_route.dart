import 'dart:async';

import 'package:flutter/widgets.dart';

import '../design/components/ascii_mascot.dart';
import '../design/spacing.dart';
import '../design/tokens.dart';
import '../platform/alert_actions.dart';
import 'alerts_boot.dart';

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
    alertOpenHandler = deferAlertOpen;
    pinOpenHandler = deferPinOpen;
  }

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
    if (identical(alertOpenHandler, deferAlertOpen)) alertOpenHandler = null;
    if (identical(pinOpenHandler, deferPinOpen)) pinOpenHandler = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return ColoredBox(
      color: tokens.backgroundPrimary,
      child: Padding(
        padding: const EdgeInsets.all(Spacing.screenEdge),
        child: Center(
          child: AsciiMascot.filling(
            state: 'splash',
            animated: false,
            colour: tokens.textPrimary,
            accent: tokens.accent,
            onDone: _played,
          ),
        ),
      ),
    );
  }
}
