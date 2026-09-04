import 'package:flutter/animation.dart';

/// Motion is quick, deterministic and sharp: 100-220ms, no springs,
/// no overshoot. Curves stay in the ease family for that reason.
abstract final class Motion {
  static const instant = Duration(milliseconds: 100);

  /// The one duration the spec names in milliseconds: the toolbar's row swap
  /// and the focus scrim both cross-fade in 120ms, between [instant] and
  /// [fast].
  static const accessory = Duration(milliseconds: 120);
  static const fast = Duration(milliseconds: 140);
  static const normal = Duration(milliseconds: 180);
  static const deliberate = Duration(milliseconds: 220);

  static const enter = Curves.easeOutCubic;
  static const exit = Curves.easeInCubic;
  static const transition = Curves.easeInOutCubic;
}

/// Effect timings. These are frame counts times a step, not
/// durations to interpolate over: every effect below is a discrete flipbook, so
/// the step is the unit that matters and the total is what the spec caps.
abstract final class Effects {
  /// Icon glitch: 5 frames x 45ms = 225ms, inside the 180-260ms window.
  /// The fifth frame is the clean glyph — the sequence has to land on
  /// the shape it corrupted, so the last frame is never a torn one.
  static const glitchFrames = 5;
  static const glitchStep = Duration(milliseconds: 45);

  /// How long a fired glitch owns its icon, for callers that have to keep the
  /// icon mounted that long.
  static const glitchDuration = Duration(milliseconds: 45 * glitchFrames);

  /// Text decode: a 3-character window sweeping left to right, 4 x 40ms.
  static const decodeSteps = 4;
  static const decodeStep = Duration(milliseconds: 40);
  static const decodeWindow = 3;
  static const decodeGlyphs = r'/\|-_';

  /// Title smear on tab change: 2 frames, well under the 120ms cap.
  static const smearFrames = 2;

  /// Static background: 8 fps, the bottom of the 8-12 range.
  /// The low rate is the effect, and on a phone every frame this costs is a
  /// frame an idle screen would not otherwise have asked for.
  static const staticStep = Duration(milliseconds: 125);

  /// A wait shorter than this shows nothing rather than a spinner.
  static const spinnerThreshold = Duration(milliseconds: 200);
  static const spinnerStep = Duration(milliseconds: 80);

  /// Boot log.
  static const bootLineStep = Duration(milliseconds: 40);
  static const bootCap = Duration(milliseconds: 600);

  /// Autonomous ticks: one event every 20-40s, never two at once.
  static const tickMin = Duration(seconds: 20);
  static const tickSpread = Duration(seconds: 20);
}
