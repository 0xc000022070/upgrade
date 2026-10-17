import 'dart:async';

import 'package:flutter/widgets.dart';

import 'package:striked/design/tokens.dart';
import 'package:striked/design/motion.dart';

class DotSpinner extends StatefulWidget {
  const DotSpinner({super.key});

  static const _ring = [0, 1, 2, 5, 8, 7, 6, 3];
  static const _cell = 4.0;
  static const _dot = 2.0;

  @override
  State<DotSpinner> createState() => _DotSpinnerState();
}

class _DotSpinnerState extends State<DotSpinner> with WidgetsBindingObserver {
  Timer? _timer;
  int _step = 0;
  bool _foreground = true;
  bool _visible = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible = TickerMode.valuesOf(context).enabled;
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _sync();
  }

  void _sync() {
    final run = _foreground && _visible;
    if (run == (_timer != null)) return;
    if (!run) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    _timer = Timer.periodic(Effects.spinnerStep, (_) {
      if (mounted) setState(() => _step++);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
                    ? context.tokens.accent
                    : context.tokens.textDisabled,
              ),
            ),
        ],
      ),
    );
  }
}

class DelayedSpinner extends StatefulWidget {
  const DelayedSpinner({super.key, this.alignment = Alignment.centerLeft});

  final Alignment alignment;

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
    return SizedBox(
      height: 12,
      child: Align(alignment: widget.alignment, child: const DotSpinner()),
    );
  }
}
