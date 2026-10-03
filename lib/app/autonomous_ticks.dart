import 'dart:async';
import 'dart:math';

import 'package:flutter/widgets.dart';

import '../design/motion.dart';

/// Exactly one event fires at a time, and the interval is seeded once per session: a run
/// is reproducible from its seed and never repeats the same rhythm across launches.
class AutonomousTicks extends StatefulWidget {
  const AutonomousTicks({super.key, required this.onTick, required this.child});

  final VoidCallback onTick;
  final Widget child;

  @override
  State<AutonomousTicks> createState() => _AutonomousTicksState();
}

class _AutonomousTicksState extends State<AutonomousTicks>
    with WidgetsBindingObserver {
  final _random = Random(DateTime.now().millisecondsSinceEpoch);

  Timer? _timer;
  bool _foreground = true;
  bool _reduceMotion = false;
  bool _onStage = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    _onStage = TickerMode.valuesOf(context).enabled;
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _sync();
  }

  bool get _run => _foreground && _onStage && !_reduceMotion;

  void _sync() {
    final run = _run;
    if (run == (_timer != null)) return;
    if (run) {
      _schedule();
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  void _schedule() {
    _timer = Timer(
      Effects.tickMin +
          Duration(
            milliseconds: _random.nextInt(Effects.tickSpread.inMilliseconds),
          ),
      () {
        _timer = null;
        widget.onTick();
        if (mounted && _run) _schedule();
      },
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
