import 'dart:async';

import 'package:flutter/widgets.dart';

import '../colors.dart';
import '../motion.dart';

/// The only loading indicator in the app. A 3x3 grid of 2px
/// squares with one lit at a time, stepping clockwise around the ring — the
/// centre is part of the grid but never lights, which is what makes the motion
/// read as rotation rather than as a random blink.
class DotSpinner extends StatefulWidget {
  const DotSpinner({super.key});

  static const _ring = [0, 1, 2, 5, 8, 7, 6, 3];
  static const _cell = 4.0;
  static const _dot = 2.0;

  @override
  State<DotSpinner> createState() => _DotSpinnerState();
}

class _DotSpinnerState extends State<DotSpinner> {
  Timer? _timer;
  int _step = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(Effects.spinnerStep, (_) {
      if (mounted) setState(() => _step++);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lit = DotSpinner._ring[_step % DotSpinner._ring.length];
    return SizedBox(
      width: DotSpinner._cell * 3,
      height: DotSpinner._cell * 3,
      child: Stack(
        children: [
          for (var i = 0; i < 9; i++)
            Positioned(
              left: (i % 3) * DotSpinner._cell,
              top: (i ~/ 3) * DotSpinner._cell,
              width: DotSpinner._dot,
              height: DotSpinner._dot,
              child: ColoredBox(
                color: i == lit
                    ? HotlineColors.accent
                    : HotlineColors.textDisabled,
              ),
            ),
        ],
      ),
    );
  }
}

/// Again, "only when a wait exceeds 200ms". A local query almost never
/// does, so the spinner is gated behind the threshold rather than shown eagerly
/// and hidden a frame later.
class DelayedSpinner extends StatefulWidget {
  const DelayedSpinner({super.key});

  @override
  State<DelayedSpinner> createState() => _DelayedSpinnerState();
}

class _DelayedSpinnerState extends State<DelayedSpinner> {
  Timer? _timer;
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(Effects.spinnerThreshold, () {
      if (mounted) setState(() => _visible = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) return const SizedBox(height: 12);
    return const SizedBox(
      height: 12,
      child: Align(alignment: Alignment.centerLeft, child: DotSpinner()),
    );
  }
}
