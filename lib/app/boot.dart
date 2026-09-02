import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../design/colors.dart';
import '../design/components/dither_field.dart';
import '../design/motion.dart';
import '../design/spacing.dart';
import '../design/typography.dart';

/// One line of the SPEC.md §16c.1 log. The steps are recorded by `main()` as it
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
    // §16c.1's 40ms is a floor, not a budget to divide: a line the eye cannot
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
      setState(() {
        _shown++;
        if (_shown > widget.steps.length) _done = true;
      });
      if (_done) {
        _stop();
      } else {
        _tick();
      }
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_done) return widget.child;
    return _BootScreen(steps: widget.steps.take(_shown).toList());
  }
}

class _BootScreen extends StatelessWidget {
  const _BootScreen({required this.steps});

  final List<BootStep> steps;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: HotlineColors.backgroundPrimary,
      child: DitherField(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(Spacing.xl),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                for (final step in steps)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Spacing.xs),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            step.label,
                            style: HotlineText.value,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: Spacing.md),
                        Text(
                          step.status,
                          style: HotlineText.value.copyWith(
                            color: HotlineColors.accent,
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
    );
  }
}
