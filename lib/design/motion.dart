import 'package:flutter/animation.dart';

abstract final class Motion {
  static const instant = Duration(milliseconds: 100);

  static const accessory = Duration(milliseconds: 120);
  static const fast = Duration(milliseconds: 140);
  static const normal = Duration(milliseconds: 180);
  static const deliberate = Duration(milliseconds: 220);

  static const enter = Curves.easeOutCubic;
  static const exit = Curves.easeInCubic;
  static const transition = Curves.easeInOutCubic;
}

/// Frame counts times a step, not durations to interpolate over: every effect below is a
/// discrete flipbook.
abstract final class Effects {
  static const glitchFrames = 5;
  static const glitchStep = Duration(milliseconds: 45);

  static const glitchDuration = Duration(milliseconds: 45 * glitchFrames);

  static const decodeSteps = 4;
  static const decodeStep = Duration(milliseconds: 40);
  static const decodeWindow = 3;
  static const decodeGlyphs = r'/\|-_';

  static const smearFrames = 2;

  static const staticStep = Duration(milliseconds: 125);

  static const spinnerThreshold = Duration(milliseconds: 200);
  static const spinnerStep = Duration(milliseconds: 80);

  static const bootLineStep = Duration(milliseconds: 40);
  static const bootCap = Duration(milliseconds: 600);

  static const tickMin = Duration(seconds: 20);
  static const tickSpread = Duration(seconds: 20);
}
