import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../data/enums.dart';
import '../effects/glitch.dart';
import '../spacing.dart';
import '../tokens.dart';
import 'slide_steps.dart';

/// The floor has no numeral: it is the one step read by subtraction alone.
const priorityNumerals = <Priority, String>{
  Priority.normal: 'I',
  Priority.high: 'II',
  Priority.critical: 'III',
};

class PriorityInk {
  const PriorityInk({this.title, this.value});

  final Color? title;
  final Color? value;
}

PriorityInk priorityInk(BuildContext context, Priority priority) =>
    priority == Priority.low
    ? PriorityInk(
        title: context.tokens.textMuted,
        value: context.tokens.textDisabled,
      )
    : const PriorityInk();

Color priorityMarkColor(BuildContext context, Priority priority) =>
    switch (priority) {
      Priority.low => context.tokens.textDisabled,
      Priority.normal => context.tokens.textMuted,
      Priority.high => context.tokens.textSecondary,
      Priority.critical => context.tokens.accent,
    };

typedef PriorityPulse = ({Duration beat, int blocks, int fragments});

/// Null below [Priority.high]: a panel where every row twitches marks nothing.
PriorityPulse? priorityPulse(Priority priority) => switch (priority) {
  Priority.low || Priority.normal => null,
  Priority.high => (
    beat: const Duration(milliseconds: 2600),
    blocks: 2,
    fragments: 1,
  ),
  Priority.critical => (
    beat: const Duration(milliseconds: 1100),
    blocks: 5,
    fragments: 3,
  ),
};

class PriorityMark extends StatefulWidget {
  const PriorityMark({
    super.key,
    required this.priority,
    required this.seed,
    this.dim = false,
  });

  final Priority priority;

  /// Spreads the first beat and picks the corruption, so two rows on the same step never
  /// tear in lockstep.
  final int seed;

  final bool dim;

  @override
  State<PriorityMark> createState() => _PriorityMarkState();
}

class _PriorityMarkState extends State<PriorityMark> {
  final _glitch = GlitchController();
  Timer? _stagger;
  Timer? _pulse;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _schedule();
  }

  @override
  void didUpdateWidget(PriorityMark oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.priority != oldWidget.priority ||
        widget.dim != oldWidget.dim ||
        widget.seed != oldWidget.seed) {
      _schedule();
    }
  }

  @override
  void dispose() {
    _stagger?.cancel();
    _pulse?.cancel();
    _glitch.dispose();
    super.dispose();
  }

  void _schedule() {
    _stagger?.cancel();
    _pulse?.cancel();
    _stagger = null;
    _pulse = null;
    _glitch.stop();

    final pulse = widget.dim ? null : priorityPulse(widget.priority);
    if (pulse == null || MediaQuery.disableAnimationsOf(context)) return;

    final beat = pulse.beat;
    _stagger = Timer(
      Duration(milliseconds: widget.seed.abs() % beat.inMilliseconds),
      () {
        _stagger = null;
        _fire();
        _pulse = Timer.periodic(beat, (_) => _fire());
      },
    );
  }

  void _fire() => _glitch.fire(seed: widget.seed);

  @override
  Widget build(BuildContext context) {
    final numeral = priorityNumerals[widget.priority];
    if (numeral == null) return const SizedBox(width: RowMetrics.markWidth);

    final pulse = widget.dim ? null : priorityPulse(widget.priority);
    final glyph = Text(
      numeral,
      textAlign: TextAlign.right,
      style: context.tokens.rowKicker.copyWith(
        color: widget.dim
            ? context.tokens.textDisabled
            : priorityMarkColor(context, widget.priority),
      ),
    );

    return SizedBox(
      width: RowMetrics.markWidth,
      child: pulse == null
          ? glyph
          : GlitchPanel(
              controller: _glitch,
              blocks: pulse.blocks,
              fragments: pulse.fragments,
              child: glyph,
            ),
    );
  }
}

class PrioritySlide extends StatelessWidget {
  const PrioritySlide({
    super.key,
    required this.priority,
    required this.onChanged,
    required this.child,
    this.enabled = true,
  });

  final Priority priority;
  final ValueChanged<Priority> onChanged;
  final Widget child;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final up = priority.raised;
    final down = priority.lowered;
    return SlideSteps(
      enabled: enabled,
      onUp: up == null ? null : () => onChanged(up),
      onDown: down == null ? null : () => onChanged(down),
      child: child,
    );
  }
}
