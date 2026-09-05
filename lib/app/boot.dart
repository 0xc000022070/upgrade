import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../design/colors.dart';
import '../design/components/dither_field.dart';
import '../design/effects/glitch.dart';
import '../design/motion.dart';
import '../design/spacing.dart';
import '../design/typography.dart';

/// One line of the boot log. The steps are recorded by `main()` as it
/// actually performs them, so the log is a report and not a decoration: if a
/// step is removed from startup its line disappears with it.
class BootStep {
  const BootStep(this.label, this.status);

  final String label;
  final String status;
}

/// Plays the log, then hard-cuts to [child]. Cold start only: the gate lives
/// above the shell and is built once, so a resume never replays it.
class BootGate extends StatefulWidget {
  const BootGate({super.key, required this.steps, required this.child});

  final List<BootStep> steps;
  final Widget child;

  @override
  State<BootGate> createState() => _BootGateState();
}

class _BootGateState extends State<BootGate> {
  Timer? _timer;
  Timer? _cut;
  int _shown = 0;
  bool _done = false;
  bool _started = false;
  TimingsCallback? _present;

  /// A screen-level event at panel scale, fired by [_settle].
  final _entry = GlitchController();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (MediaQuery.disableAnimationsOf(context) || widget.steps.isEmpty) {
      setState(() => _done = true);
      return;
    }
    // The first line is already on screen when the log opens, and the last tick
    // holds the finished log for one step: without it the completed log is
    // never a frame, since the reveal and the cut land together.
    _shown = 1;
    // Counting frames does not work here. A post-frame callback runs after
    // build and paint but before the raster thread has put anything on the
    // display, and on a release cold start the first frames are drawn while the
    // splash window is still on top: a roll started there spends two or three
    // lines where nobody can see them, and measurement on device showed the log
    // opening at three lines with only 110-140ms of it visible. A timings
    // callback is the one signal that a frame was actually rasterised and
    // presented, so the roll starts on the frame the user has really seen.
    _present = (_) {
      SchedulerBinding.instance.removeTimingsCallback(_present!);
      _present = null;
      _roll();
    };
    SchedulerBinding.instance.addTimingsCallback(_present!);
    SchedulerBinding.instance.scheduleFrame();
  }

  void _roll() {
    if (!mounted || _done) return;
    // The 40ms is a floor, not a budget to divide: a line the eye cannot
    // separate from the one above it is not a log. A long step list overruns
    // the cap rather than compressing, and [_cut] ends it there so startup is
    // never held for the log.
    //
    // Not `Timer.periodic`. A periodic timer keeps its original schedule, so
    // ticks the busy startup isolate makes it miss all fire the moment it frees
    // up: on device that turned the last three lines into 17ms apart, which is
    // the flicker the floor exists to prevent. Rescheduling from the tick that
    // just ran makes the step a real gap between reveals.
    _tick();
    _cut = Timer(Effects.bootCap, () {
      if (!mounted) return;
      setState(() => _done = true);
      _stop();
    });
  }

  void _tick() {
    _timer = Timer(Effects.bootLineStep, () {
      if (!mounted) return;
      setState(() => _shown++);
      if (_shown > widget.steps.length) {
        _settle();
      } else {
        _tick();
      }
    });
  }

  /// The screen-level glitch event. Fired on the log's arrival instead, the
  /// tear owns every frame the log has — the roll is six 40ms lines and the
  /// glitch is 225ms — so the eye never sees the clean log the corruption is
  /// supposed to be of. Here it tears a finished log and then puts it back, and
  /// the sequence still lands inside [Effects.bootCap], which [_cut] enforces.
  void _settle() {
    _entry.fire();
    _timer = Timer(Effects.glitchDuration, () {
      if (!mounted) return;
      setState(() => _done = true);
      _stop();
    });
  }

  void _stop() {
    if (_present != null) {
      SchedulerBinding.instance.removeTimingsCallback(_present!);
      _present = null;
    }
    _timer?.cancel();
    _timer = null;
    _cut?.cancel();
    _cut = null;
  }

  @override
  void dispose() {
    _stop();
    _entry.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_done) return widget.child;
    return _BootScreen(
      steps: widget.steps.take(_shown).toList(),
      entry: _entry,
    );
  }
}

class _BootScreen extends StatelessWidget {
  const _BootScreen({required this.steps, required this.entry});

  final List<BootStep> steps;
  final GlitchController entry;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: SpectacleColors.backgroundPrimary,
      child: DitherField(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(Spacing.xl),
            // The gate is [MaterialApp.home], so it has no Material above it
            // and inherits WidgetsApp's error text style: every log line came
            // out with a yellow double underline that no one had noticed
            // against the accent column. The lines carry their own style and
            // only ever inherited that decoration.
            child: DefaultTextStyle(
              style: SpectacleText.value,
              // Bottom-aligned by [Align] rather than by the column, so the
              // column is only as tall as the log. The glitch blocks are
              // fractions of the box they are given: over a full-height column
              // most of a set lands in the empty two thirds above the log and
              // tears nothing, which on device left one visible torn frame out
              // of four.
              child: Align(
                alignment: Alignment.bottomLeft,
                child: GlitchPanel(
                  controller: entry,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final step in steps)
                        Padding(
                          padding: const EdgeInsets.only(bottom: Spacing.xs),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  step.label,
                                  style: SpectacleText.value,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: Spacing.md),
                              Text(
                                step.status,
                                style: SpectacleText.value.copyWith(
                                  color: SpectacleColors.accent,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
