/// Geometry measured off the 360dp mocks in design/explorations/screens: 20px
/// from the screen edge, 8px between panels, 8px inside one, and a 4px rhythm
/// between the lines of a row.
abstract final class Spacing {
  static const xs = 2.0;
  static const sm = 4.0;
  static const md = 8.0;
  static const lg = 12.0;
  static const xl = 16.0;
  static const xxl = 24.0;

  /// Panels stack with this gap and nothing else between them.
  static const panelGap = 8.0;

  /// Inner padding of every panel.
  static const panelPadding = 8.0;

  /// From the mocks: the panels are 320 wide on a 360 screen.
  static const screenEdge = 16.0;
}

/// A row is sized by its content, not by a fixed step: one line lands near 40,
/// two near 57, three near 70, which is what the mocks measure. [minHeight]
/// only stops a row with a single short line from collapsing.
abstract final class RowMetrics {
  static const padding = 10.0;
  static const lineGap = 4.0;
  static const minHeight = 36.0;

  /// The activity stream sets its lines tighter than a row: it is a log, and
  /// nothing in it is a tap target.
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
  /// The left slot on a row.
  static const glyph = 14.0;

  /// The task checkbox, which the mocks draw smaller than a status glyph.
  static const check = 12.0;

  /// The `>` and `+` that sit inside a panel's header strip.
  static const affordance = 11.0;

  static const sm = 16.0;

  /// The keyboard toolbar's Material glyphs, at 22px — between [sm] and [lg],
  /// and the one place in the app that is not on the 4px step. The key strip's
  /// glyph keys are the same 22, so the two share the token.
  static const toolbar = 22.0;

  static const md = 20.0;
  static const lg = 24.0;

  /// The project glyph in the hero card.
  static const hero = 32.0;
}

/// Density comes from padding, never from shrinking what a finger has to hit.
abstract final class TapTargets {
  static const minHeight = 44.0;

  /// The done checkbox is a 14px glyph with a 40px target around it.
  static const checkbox = 40.0;
}

/// The inline bar next to a percent. Never full width, never under the row —
/// the concept keeps progress inside the value column.
abstract final class BarSizes {
  static const inlineWidth = 56.0;
  static const inlineThickness = 2.0;
}
