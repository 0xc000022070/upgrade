import 'package:flutter/animation.dart';

/// Motion from SPEC.md §16: quick, deterministic, sharp. 100-220ms, no springs,
/// no overshoot. Curves stay in the ease family for that reason.
abstract final class Motion {
  static const instant = Duration(milliseconds: 100);
  static const fast = Duration(milliseconds: 140);
  static const normal = Duration(milliseconds: 180);
  static const deliberate = Duration(milliseconds: 220);

  static const enter = Curves.easeOutCubic;
  static const exit = Curves.easeInCubic;
  static const transition = Curves.easeInOutCubic;
}

/// SPEC.md §16b/§16c effect timings. These are frame counts times a step, not
/// durations to interpolate over: every effect below is a discrete flipbook, so
/// the step is the unit that matters and the total is what the spec caps.
abstract final class Effects {
  /// Icon glitch: 4 frames x 55ms = 220ms, inside the 180-260ms window.
  static const glitchFrames = 4;
  static const glitchStep = Duration(milliseconds: 55);

  /// How long a fired glitch owns its icon, for callers that have to keep the
  /// icon mounted that long.
  static const glitchDuration = Duration(milliseconds: 55 * glitchFrames);

  /// Text decode: a 3-character window sweeping left to right, 4 x 40ms.
  static const decodeSteps = 4;
  static const decodeStep = Duration(milliseconds: 40);
  static const decodeWindow = 3;
  static const decodeGlyphs = r'/\|-_';

  /// §16c.4 title smear on tab change: 2 frames, well under the 120ms cap.
  static const smearFrames = 2;

  /// §16b.1 static background: 8 fps, the bottom of the section's 8-12 range.
  /// The low rate is the effect, and on a phone every frame this costs is a
  /// frame an idle screen would not otherwise have asked for.
  static const staticStep = Duration(milliseconds: 125);

  /// §16c.6: a wait shorter than this shows nothing rather than a spinner.
  static const spinnerThreshold = Duration(milliseconds: 200);
  static const spinnerStep = Duration(milliseconds: 80);

  /// §16c.1 boot log.
  static const bootLineStep = Duration(milliseconds: 40);
  static const bootCap = Duration(milliseconds: 600);

  /// §16b autonomous ticks: one event every 20-40s, never two at once.
  static const tickMin = Duration(seconds: 20);
  static const tickSpread = Duration(seconds: 20);
}
