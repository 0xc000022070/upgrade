import 'package:flutter/painting.dart';

import 'colors.dart';

abstract final class FontFamilies {
  /// Screen titles and the one display number.
  static const display = 'Barlow Condensed';

  /// Long-form prose. The mocks kept it to the action sheet's body copy.
  static const ui = 'IBM Plex Sans';

  /// Everything structural. Mono is the default, not the exception.
  static const mono = 'IBM Plex Mono';

  /// The icons a shell prompt draws — git branch, host, nix snowflake —
  /// that live in Nerd Fonts' private-use range. A fallback, not a
  /// typeface: it carries no letterforms of its own to compete with mono.
  static const monoSymbols = 'Symbols Nerd Font Mono';

  /// Reported by the boot log.
  static const count = 4;
}

/// Sized off the 360dp mocks in design/explorations/screens.
/// The scale is mono-dominant and small: size carries almost no hierarchy, so
/// colour, column position and the 9/10/12 step do the separating.
abstract final class SpectacleText {
  /// The screen title. The trailing `_` cursor is appended by the
  /// scaffold, not baked in, so a title can still be decoded glyph by glyph.
  static const screenTitle = TextStyle(
    fontFamily: FontFamilies.display,
    fontSize: 29,
    height: 1.0,
    fontWeight: FontWeight.w700,
    letterSpacing: 1.0,
    color: SpectacleColors.textPrimary,
  );

  /// `/ PERSONAL CONTROL PLANE` above every title.
  static const breadcrumb = TextStyle(
    fontFamily: FontFamilies.mono,
    fontSize: 10,
    height: 1.3,
    fontWeight: FontWeight.w400,
    letterSpacing: 0.5,
    color: SpectacleColors.textMuted,
  );

  /// The header strip inside a panel, and its right affordance.
  static const panelHeader = TextStyle(
    fontFamily: FontFamilies.mono,
    fontSize: 10,
    height: 1.3,
    fontWeight: FontWeight.w400,
    letterSpacing: 1.5,
    color: SpectacleColors.textMuted,
  );

  /// The small uppercase line above a row title — the project a row belongs to.
  static const rowKicker = TextStyle(
    fontFamily: FontFamilies.mono,
    fontSize: 9,
    height: 1.3,
    fontWeight: FontWeight.w400,
    letterSpacing: 0.8,
    color: SpectacleColors.textSecondary,
  );

  /// Row anatomy: title over subtitle over caption, all mono.
  static const rowTitle = TextStyle(
    fontFamily: FontFamilies.mono,
    fontSize: 12,
    height: 1.3,
    fontWeight: FontWeight.w400,
    color: SpectacleColors.textPrimary,
  );

  /// The single row on a screen that is the screen's whole point — HOME's next
  /// action. One step up is the entire emphasis it gets.
  static const rowTitleLead = TextStyle(
    fontFamily: FontFamilies.mono,
    fontSize: 13,
    height: 1.3,
    fontWeight: FontWeight.w400,
    color: SpectacleColors.textPrimary,
  );

  static const rowSubtitle = TextStyle(
    fontFamily: FontFamilies.mono,
    fontSize: 10,
    height: 1.3,
    fontWeight: FontWeight.w400,
    color: SpectacleColors.textMuted,
  );

  /// The single right-hand column — percent, duration, time, count.
  static const value = TextStyle(
    fontFamily: FontFamilies.mono,
    fontSize: 10,
    height: 1.3,
    fontWeight: FontWeight.w400,
    color: SpectacleColors.textMuted,
  );

  static const valueStrong = TextStyle(
    fontFamily: FontFamilies.mono,
    fontSize: 10,
    height: 1.3,
    fontWeight: FontWeight.w500,
    color: SpectacleColors.textPrimary,
  );

  /// The smallest tracked line. Tags, field names, `n OF m TASKS`.
  static const label = TextStyle(
    fontFamily: FontFamilies.mono,
    fontSize: 9,
    height: 1.3,
    fontWeight: FontWeight.w400,
    letterSpacing: 0.8,
    color: SpectacleColors.textMuted,
  );

  /// The project name in the hero card.
  static const heroName = TextStyle(
    fontFamily: FontFamilies.display,
    fontSize: 20,
    height: 1.1,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.4,
    color: SpectacleColors.textPrimary,
  );

  /// The one big number on the screen.
  static const heroPercent = TextStyle(
    fontFamily: FontFamilies.display,
    fontSize: 28,
    height: 1.0,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.2,
    color: SpectacleColors.accent,
  );

  /// A note body is read, not scanned, so it keeps a taller line box than a row
  /// — but the mocks carry no Sans on either screen, so it stays mono.
  static const noteBody = TextStyle(
    fontFamily: FontFamilies.mono,
    fontSize: 11,
    height: 1.45,
    fontWeight: FontWeight.w400,
    color: SpectacleColors.textPrimary,
  );

  /// The settings build line: one step above [value] because it is meant to be
  /// read
  /// off a screen and typed into a bug report, and dim because it is a stamp
  /// and not a fact anyone acts on.
  static const buildStamp = TextStyle(
    fontFamily: FontFamilies.mono,
    fontSize: 11,
    height: 1.3,
    fontWeight: FontWeight.w400,
    color: SpectacleColors.textMuted,
  );

  /// The capture field's placeholder, one step above a row title so the
  /// bar reads as an input rather than another list line.
  static const capture = TextStyle(
    fontFamily: FontFamilies.mono,
    fontSize: 14,
    height: 1.2,
    fontWeight: FontWeight.w400,
    color: SpectacleColors.textMuted,
  );

  /// The remaining Sans: the action sheet's explanatory copy.
  static const prose = TextStyle(
    fontFamily: FontFamilies.ui,
    fontSize: 12,
    height: 1.45,
    fontWeight: FontWeight.w400,
    color: SpectacleColors.textSecondary,
  );

  /// Glyph over a tracked mono label.
  static const navLabel = TextStyle(
    fontFamily: FontFamilies.mono,
    fontSize: 10,
    height: 1.2,
    fontWeight: FontWeight.w400,
    letterSpacing: 1.0,
    color: SpectacleColors.textMuted,
  );

  /// The corner window's own scale, which is deliberately not the one above.
  ///
  /// Every style before this was sized off a 360dp screen held at reading
  /// distance, where colour and column position carry the hierarchy and size
  /// barely has to. A picture-in-picture tile is two hundred points wide at the
  /// edge of the app the user actually went to, it has no columns to separate
  /// anything with, and the system is free to draw it smaller still. So size is
  /// the only channel left and the steps have to be ones the eye can resolve:
  /// 9, 11 and 13, each a fifth larger than the one under it. What was there
  /// before stepped twenty to ten in one jump, which reads as a banner over
  /// fine print rather than as a heading over rows.
  ///
  /// All three are mono. The display face is condensed, and condensed
  /// letterforms at this size, on a window the compositor is scaling down, lose
  /// the strokes that tell them apart.
  static const pipHeadline = TextStyle(
    fontFamily: FontFamilies.mono,
    fontSize: 13,
    height: 1.2,
    // Medium is the heaviest mono in the bundle: asking for anything over it
    // resolves back to this and the line reads as claiming a weight it is not
    // drawn in. The step down to the rows is carried by size and tracking.
    fontWeight: FontWeight.w500,
    letterSpacing: 0.4,
    color: SpectacleColors.textPrimary,
  );

  /// The agent on a row of the corner window.
  static const pipAgent = TextStyle(
    fontFamily: FontFamilies.mono,
    fontSize: 11,
    height: 1.25,
    fontWeight: FontWeight.w500,
    color: SpectacleColors.textPrimary,
  );

  /// What that agent is doing, at the size of the name it belongs to so the two
  /// read as one line. Weight and colour separate them, not size.
  static const pipState = TextStyle(
    fontFamily: FontFamilies.mono,
    fontSize: 11,
    height: 1.25,
    fontWeight: FontWeight.w400,
    color: SpectacleColors.textSecondary,
  );

  /// The machine a row is on, and the count of the rows that did not fit.
  /// Secondary rather than muted: muted is a grey drawn for a screen in the
  /// hand, and it falls under four to one against this background, which is
  /// under the floor for text this small on a window across the room.
  static const pipMeta = TextStyle(
    fontFamily: FontFamilies.mono,
    fontSize: 9,
    height: 1.25,
    fontWeight: FontWeight.w400,
    letterSpacing: 0.6,
    color: SpectacleColors.textSecondary,
  );
}
