import 'package:flutter/painting.dart';

import 'colors.dart';

abstract final class FontFamilies {
  static const display = 'Barlow Condensed';

  static const ui = 'IBM Plex Sans';

  static const mono = 'IBM Plex Mono';

  static const monoSymbols = 'Symbols Nerd Font Mono';

  static const count = 4;
}

abstract final class DazzleText {
  static const screenTitle = TextStyle(
    fontFamily: FontFamilies.display,
    fontSize: 29,
    height: 1.0,
    fontWeight: FontWeight.w700,
    letterSpacing: 1.0,
    color: DazzleColors.textPrimary,
  );

  static const breadcrumb = TextStyle(
    fontFamily: FontFamilies.mono,
    fontSize: 11,
    height: 1.3,
    fontWeight: FontWeight.w400,
    letterSpacing: 0.5,
    color: DazzleColors.textMuted,
  );

  static const panelHeader = TextStyle(
    fontFamily: FontFamilies.mono,
    fontSize: 11,
    height: 1.3,
    fontWeight: FontWeight.w400,
    letterSpacing: 0.8,
    color: DazzleColors.textMuted,
  );

  static const rowKicker = TextStyle(
    fontFamily: FontFamilies.mono,
    fontSize: 11,
    height: 1.3,
    fontWeight: FontWeight.w400,
    letterSpacing: 0.8,
    color: DazzleColors.textSecondary,
  );

  static const rowTitle = TextStyle(
    fontFamily: FontFamilies.mono,
    fontSize: 14,
    height: 1.3,
    fontWeight: FontWeight.w400,
    color: DazzleColors.textPrimary,
  );

  static const rowTitleLead = TextStyle(
    fontFamily: FontFamilies.mono,
    fontSize: 15,
    height: 1.3,
    fontWeight: FontWeight.w400,
    color: DazzleColors.textPrimary,
  );

  static const rowSubtitle = TextStyle(
    fontFamily: FontFamilies.mono,
    fontSize: 12,
    height: 1.3,
    fontWeight: FontWeight.w400,
    color: DazzleColors.textMuted,
  );

  static const value = TextStyle(
    fontFamily: FontFamilies.mono,
    fontSize: 12,
    height: 1.3,
    fontWeight: FontWeight.w400,
    color: DazzleColors.textMuted,
  );

  static const valueStrong = TextStyle(
    fontFamily: FontFamilies.mono,
    fontSize: 12,
    height: 1.3,
    fontWeight: FontWeight.w500,
    color: DazzleColors.textPrimary,
  );

  static const label = TextStyle(
    fontFamily: FontFamilies.mono,
    fontSize: 11,
    height: 1.3,
    fontWeight: FontWeight.w400,
    letterSpacing: 0.8,
    color: DazzleColors.textMuted,
  );

  static const heroName = TextStyle(
    fontFamily: FontFamilies.display,
    fontSize: 20,
    height: 1.1,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.4,
    color: DazzleColors.textPrimary,
  );

  static const heroPercent = TextStyle(
    fontFamily: FontFamilies.display,
    fontSize: 28,
    height: 1.0,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.2,
    color: DazzleColors.accent,
  );

  static const noteBody = TextStyle(
    fontFamily: FontFamilies.mono,
    fontSize: 14,
    height: 1.45,
    fontWeight: FontWeight.w400,
    color: DazzleColors.textPrimary,
  );

  static const buildStamp = TextStyle(
    fontFamily: FontFamilies.mono,
    fontSize: 11,
    height: 1.3,
    fontWeight: FontWeight.w400,
    color: DazzleColors.textMuted,
  );

  static const capture = TextStyle(
    fontFamily: FontFamilies.mono,
    fontSize: 14,
    height: 1.2,
    fontWeight: FontWeight.w400,
    color: DazzleColors.textMuted,
  );

  static const prose = TextStyle(
    fontFamily: FontFamilies.ui,
    fontSize: 14,
    height: 1.45,
    fontWeight: FontWeight.w400,
    color: DazzleColors.textSecondary,
  );

  static const navLabel = TextStyle(
    fontFamily: FontFamilies.mono,
    fontSize: 10,
    height: 1.2,
    fontWeight: FontWeight.w400,
    letterSpacing: 1.0,
    color: DazzleColors.textMuted,
  );

  /// Deliberately not the scale above. A picture-in-picture tile has no columns to carry
  /// hierarchy with and the system may scale it down further, so size is the only channel
  /// left and the steps have to be ones the eye can resolve. All three are mono: condensed
  /// letterforms this small lose the strokes that tell them apart.
  static const pipHeadline = TextStyle(
    fontFamily: FontFamilies.mono,
    fontSize: 13,
    height: 1.2,
    // Medium is the heaviest mono in the bundle: asking for more resolves back to this.
    fontWeight: FontWeight.w500,
    letterSpacing: 0.4,
    color: DazzleColors.textPrimary,
  );

  static const pipAgent = TextStyle(
    fontFamily: FontFamilies.mono,
    fontSize: 11,
    height: 1.25,
    fontWeight: FontWeight.w500,
    color: DazzleColors.textPrimary,
  );

  static const pipState = TextStyle(
    fontFamily: FontFamilies.mono,
    fontSize: 11,
    height: 1.25,
    fontWeight: FontWeight.w400,
    color: DazzleColors.textSecondary,
  );

  static const pipMeta = TextStyle(
    fontFamily: FontFamilies.mono,
    fontSize: 9,
    height: 1.25,
    fontWeight: FontWeight.w400,
    letterSpacing: 0.6,
    color: DazzleColors.textSecondary,
  );
}
