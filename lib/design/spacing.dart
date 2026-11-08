import 'dart:async';
import 'dart:ui' show VoidCallback;

abstract final class Spacing {
  static const xs = 2.0;
  static const sm = 4.0;
  static const md = 8.0;
  static const lg = 12.0;
  static const xl = 16.0;
  static const xxl = 24.0;

  static const panelGap = 8.0;

  static const panelPadding = 8.0;

  static const screenEdge = 16.0;
}

abstract final class RowMetrics {
  static const padding = 10.0;
  static const lineGap = 4.0;
  static const minHeight = 36.0;

  /// Three mono characters at the kicker's size. Held whether a mark is drawn or not, so
  /// an unmarked row sits in the same grid as a marked one.
  static const markWidth = 20.0;

  static const streamPadding = 3.0;
}

abstract final class Radii {
  static const none = 0.0;
  static const sharp = 2.0;
  static const normal = 4.0;
}

abstract final class Borders {
  static const hairline = 1.0;
}

abstract final class IconSizes {
  static const glyph = 14.0;

  static const check = 12.0;

  static const affordance = 11.0;

  static const sm = 16.0;

  static const toolbar = 22.0;

  static const md = 20.0;
  static const lg = 24.0;

  static const hero = 32.0;
}

abstract final class Gestures {
  static const flick = 8.0;

  static const stick = 12.0;

  static const repeatDelay = Duration(milliseconds: 400);

  static const repeatInterval = Duration(milliseconds: 50);
}

/// Fires [fire] after [Gestures.repeatDelay] and then every [Gestures.repeatInterval] until
/// [stop]. The press's own first action belongs to the caller.
class KeyRepeat {
  Timer? _timer;

  void start(VoidCallback fire) {
    stop();
    _timer = Timer(Gestures.repeatDelay, () {
      fire();
      _timer = Timer.periodic(Gestures.repeatInterval, (_) => fire());
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}

abstract final class TapTargets {
  static const minHeight = 44.0;

  static const checkbox = 40.0;
}

abstract final class BarSizes {
  static const inlineWidth = 56.0;
  static const inlineThickness = 2.0;
}
