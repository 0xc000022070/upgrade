import 'package:flutter/painting.dart';

import 'colors.dart';

abstract final class FontFamilies {
  /// Screen titles and the one display number (SPEC.md §38.2, §38.6).
  static const display = 'Barlow Condensed';

  /// Long-form prose. The mocks kept it to the action sheet's body copy.
  static const ui = 'IBM Plex Sans';

  /// Everything structural. §38.2 makes mono the default, not the exception.
  static const mono = 'IBM Plex Mono';

  /// Reported by the §16c.1 boot log.
  static const count = 3;
}

/// SPEC.md §38.2, sized off the 360dp mocks in design/explorations/screens.
/// The scale is mono-dominant and small: size carries almost no hierarchy, so
/// colour, column position and the 9/10/12 step do the separating.
abstract final class HotlineText {
  /// §38.5: the screen title. The trailing `_` cursor is appended by the
  /// scaffold, not baked in, so a title can still be decoded glyph by glyph.
  static const screenTitle = TextStyle(
    fontFamily: FontFamilies.display,
    fontSize: 29,
    height: 1.0,
    fontWeight: FontWeight.w700,
    letterSpacing: 1.0,
    color: HotlineColors.textPrimary,
  );

  /// §38.5: `/ PERSONAL CONTROL PLANE` above every title.
  static const breadcrumb = TextStyle(
    fontFamily: FontFamilies.mono,
    fontSize: 10,
    height: 1.3,
    fontWeight: FontWeight.w400,
    letterSpacing: 0.5,
    color: HotlineColors.textMuted,
  );

  /// §38.1: the header strip inside a panel, and its right affordance.
  static const panelHeader = TextStyle(
    fontFamily: FontFamilies.mono,
    fontSize: 10,
    height: 1.3,
    fontWeight: FontWeight.w400,
    letterSpacing: 1.5,
    color: HotlineColors.textMuted,
  );

  /// The small uppercase line above a row title — the project a row belongs to.
  static const rowKicker = TextStyle(
    fontFamily: FontFamilies.mono,
    fontSize: 9,
    height: 1.3,
    fontWeight: FontWeight.w400,
    letterSpacing: 0.8,
    color: HotlineColors.textSecondary,
  );

  /// §38.4 row anatomy: title over subtitle over caption, all mono.
  static const rowTitle = TextStyle(
    fontFamily: FontFamilies.mono,
    fontSize: 12,
    height: 1.3,
    fontWeight: FontWeight.w400,
    color: HotlineColors.textPrimary,
  );

  /// The single row on a screen that is the screen's whole point — HOME's next
  /// action. One step up is the entire emphasis it gets.
  static const rowTitleLead = TextStyle(
    fontFamily: FontFamilies.mono,
    fontSize: 13,
    height: 1.3,
    fontWeight: FontWeight.w400,
    color: HotlineColors.textPrimary,
  );

  static const rowSubtitle = TextStyle(
    fontFamily: FontFamilies.mono,
    fontSize: 10,
    height: 1.3,
    fontWeight: FontWeight.w400,
    color: HotlineColors.textMuted,
  );

  /// §38.4: the single right-hand column — percent, duration, time, count.
  static const value = TextStyle(
    fontFamily: FontFamilies.mono,
    fontSize: 10,
    height: 1.3,
    fontWeight: FontWeight.w400,
    color: HotlineColors.textMuted,
  );

  static const valueStrong = TextStyle(
    fontFamily: FontFamilies.mono,
    fontSize: 10,
    height: 1.3,
    fontWeight: FontWeight.w500,
    color: HotlineColors.textPrimary,
  );

  /// §38.2: the smallest tracked line. Tags, field names, `n OF m TASKS`.
  static const label = TextStyle(
    fontFamily: FontFamilies.mono,
    fontSize: 9,
    height: 1.3,
    fontWeight: FontWeight.w400,
    letterSpacing: 0.8,
    color: HotlineColors.textMuted,
  );

  /// §38.6: the project name in the hero card.
  static const heroName = TextStyle(
    fontFamily: FontFamilies.display,
    fontSize: 20,
    height: 1.1,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.4,
    color: HotlineColors.textPrimary,
  );

  /// §38.6: the one big number on the screen.
  static const heroPercent = TextStyle(
    fontFamily: FontFamilies.display,
    fontSize: 28,
    height: 1.0,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.2,
    color: HotlineColors.accent,
  );

  /// A note body is read, not scanned, so it keeps a taller line box than a row
  /// — but the mocks carry no Sans on either screen, so it stays mono.
  static const noteBody = TextStyle(
    fontFamily: FontFamilies.mono,
    fontSize: 11,
    height: 1.45,
    fontWeight: FontWeight.w400,
    color: HotlineColors.textPrimary,
  );

  /// §39.16's build line: one step above [value] because it is meant to be read
  /// off a screen and typed into a bug report, and dim because it is a stamp
  /// and not a fact anyone acts on.
  static const buildStamp = TextStyle(
    fontFamily: FontFamilies.mono,
    fontSize: 11,
    height: 1.3,
    fontWeight: FontWeight.w400,
    color: HotlineColors.textMuted,
  );

  /// §38.9: the capture field's placeholder, one step above a row title so the
  /// bar reads as an input rather than another list line.
  static const capture = TextStyle(
    fontFamily: FontFamilies.mono,
    fontSize: 14,
    height: 1.2,
    fontWeight: FontWeight.w400,
    color: HotlineColors.textMuted,
  );

  /// The remaining Sans: the action sheet's explanatory copy.
  static const prose = TextStyle(
    fontFamily: FontFamilies.ui,
    fontSize: 12,
    height: 1.45,
    fontWeight: FontWeight.w400,
    color: HotlineColors.textSecondary,
  );

  /// §38.8: glyph over a tracked mono label.
  static const navLabel = TextStyle(
    fontFamily: FontFamilies.mono,
    fontSize: 10,
    height: 1.2,
    fontWeight: FontWeight.w400,
    letterSpacing: 1.0,
    color: HotlineColors.textMuted,
  );
}
