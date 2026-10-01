import 'dart:async';

import 'package:flutter/widgets.dart';

import '../motion.dart';

/// Repaints [child] in [base] with a hard-edged band of [lit] stepping across it, left to
/// right and round again. It holds off for the spinner's threshold, so a wait that ends
/// at once is never drawn.
class ScanSweep extends StatefulWidget {
  const ScanSweep({
    super.key,
    required this.base,
    required this.lit,
    required this.child,
  });

  static const steps = 12;
  static const band = 10.0;

  final Color base;
  final Color lit;
  final Widget child;

  @override
  State<ScanSweep> createState() => _ScanSweepState();
}

class _ScanSweepState extends State<ScanSweep> with WidgetsBindingObserver {
  Timer? _timer;
  Timer? _hold;
  bool _due = false;
  int _step = 0;
  bool _foreground = true;
  bool _visible = true;
  bool _still = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _hold = Timer(Effects.spinnerThreshold, () {
      if (!mounted) return;
      setState(() => _due = true);
      _sync();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible = TickerMode.valuesOf(context).enabled;
    _still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _sync();
  }

  void _sync() {
    final run = _due && _foreground && _visible && !_still;
    if (run == (_timer != null)) return;
    if (!run) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    _timer = Timer.periodic(Effects.spinnerStep, (_) {
      if (mounted) setState(() => _step = (_step + 1) % ScanSweep.steps);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hold?.cancel();
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_still || !_due) return widget.child;
    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (bounds) {
        final band = ScanSweep.band / bounds.width;
        final travel = 1 + band;
        final start = -band + travel * _step / (ScanSweep.steps - 1);
        final from = start.clamp(0.0, 1.0);
        final to = (start + band).clamp(0.0, 1.0);
        return LinearGradient(
          colors: [
            widget.base,
            widget.base,
            widget.lit,
            widget.lit,
            widget.base,
            widget.base,
          ],
          stops: [0, from, from, to, to, 1],
        ).createShader(bounds);
      },
      child: widget.child,
    );
  }
}
