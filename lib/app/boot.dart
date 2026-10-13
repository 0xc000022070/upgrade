import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/design/components/dither_field.dart';
import 'package:upgrade/design/effects/glitch.dart';
import 'package:upgrade/design/motion.dart';
import 'package:upgrade/design/spacing.dart';

/// Recorded by `main()` as it performs the step, so a step removed from startup takes
/// its line with it.
class BootStep {
  const BootStep(this.label, this.status);

  final String label;
  final String status;
}

/// Cold start only: the gate lives above the shell and is built once, so a resume never
/// replays it.
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
  int _beats = 0;
  bool _done = false;
  bool _started = false;
  TimingsCallback? _present;

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
    // The first beat is already on screen when the log opens, and the last one holds the
    // finished log: without it the completed log is never a frame, since the reveal and
    // the tear land together.
    // Counting frames does not work here. A post-frame callback runs after build and paint
    // but before the raster thread has put anything on the display, and on a release cold
    // start the first frames are drawn while the splash window is still on top: measured on
    // device, a roll started there opened at three lines with only 110-140 ms of it
    // visible. A timings callback is the one signal that a frame was really rasterised.
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
    // A longer step list shows more lines a beat rather than taking more beats, so a step
    // added to startup costs no time. Not `Timer.periodic`, which keeps its original
    // schedule — ticks the busy startup isolate makes it miss all fire the moment it frees
    // up, which on device put the last three lines 17 ms apart.
    _tick();
    _cut = Timer(Effects.bootCap, () {
      if (!mounted) return;
      setState(() => _done = true);
      _stop();
    });
  }

  int get _stride => (widget.steps.length / Effects.bootBeats).ceil();

  void _tick() {
    _timer = Timer(Effects.bootLineStep, () {
      if (!mounted) return;
      setState(() => _beats++);
      if (_stride * _beats >= widget.steps.length) {
        _settle();
      } else {
        _tick();
      }
    });
  }

  /// Fired on the log's arrival instead, the tear owns every frame the log has — the roll
  /// is six 40 ms beats and the glitch is 225 ms — so the eye never sees the clean log the
  /// corruption is supposed to be of.
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
      steps: widget.steps.take(_stride * (_beats + 1)).toList(),
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
      color: context.tokens.backgroundPrimary,
      child: DitherField(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(Spacing.xl),
            // The gate is [MaterialApp.home], so it has no Material above it and inherits
            // WidgetsApp's error text style: every log line came out with a yellow double underline.
            child: DefaultTextStyle(
              style: context.tokens.value,
              // Bottom-aligned by [Align] rather than by the column, so the column is only as tall as
              // the log: the glitch blocks are fractions of the box they are given, and over a
              // full-height column most of a set tears the empty space above the log.
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
                                  style: context.tokens.value,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: Spacing.md),
                              Text(
                                step.status,
                                style: context.tokens.value.copyWith(
                                  color: context.tokens.accent,
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
