import 'package:flutter/material.dart';

import 'colors.dart';
import 'typography.dart';

@immutable
class TerminalPalette {
  const TerminalPalette({
    required this.foreground,
    required this.background,
    required this.cursor,
    required this.ansi,
  });

  final Color foreground;
  final Color background;
  final Color cursor;

  final List<Color> ansi;
}

@immutable
class SyntaxPalette {
  const SyntaxPalette({
    required this.keyword,
    required this.type,
    required this.string,
    required this.number,
    required this.comment,
    required this.annotation,
  });

  final Color keyword;
  final Color type;
  final Color string;
  final Color number;
  final Color comment;
  final Color annotation;

  static const house = SyntaxPalette(
    keyword: SyntaxColors.keyword,
    type: SyntaxColors.type,
    string: SyntaxColors.string,
    number: SyntaxColors.number,
    comment: SyntaxColors.comment,
    annotation: SyntaxColors.annotation,
  );

  SyntaxPalette lerpTo(SyntaxPalette other, double t) => SyntaxPalette(
    keyword: Color.lerp(keyword, other.keyword, t)!,
    type: Color.lerp(type, other.type, t)!,
    string: Color.lerp(string, other.string, t)!,
    number: Color.lerp(number, other.number, t)!,
    comment: Color.lerp(comment, other.comment, t)!,
    annotation: Color.lerp(annotation, other.annotation, t)!,
  );
}

/// Geometry is not here: it does not change with the theme, so it stays the plain
/// constants in `spacing.dart`.
@immutable
class DazzleTokens extends ThemeExtension<DazzleTokens> {
  const DazzleTokens({
    required this.brightness,
    required this.backgroundPrimary,
    required this.backgroundSecondary,
    required this.surfacePrimary,
    required this.surfaceSecondary,
    required this.borderSubtle,
    required this.borderNormal,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.textDisabled,
    required this.accent,
    required this.accentMuted,
    required this.warning,
    required this.warningMuted,
    required this.danger,
    required this.syntax,
    required this.scrim,
    required this.mediaBackdrop,
    required this.selectionWash,
    required this.selectionWashCurrent,
    required this.terminalSelectionWash,
    required this.diffMapWindow,
    required this.diffAddedGround,
    required this.diffRemovedGround,
    required this.diffCappedGround,
    required this.diffAddedRun,
    required this.diffRemovedRun,
    required this.terminal,
    required this.screenTitle,
    required this.breadcrumb,
    required this.panelHeader,
    required this.rowKicker,
    required this.rowTitle,
    required this.rowTitleLead,
    required this.rowSubtitle,
    required this.value,
    required this.valueStrong,
    required this.label,
    required this.heroName,
    required this.heroPercent,
    required this.noteBody,
    required this.buildStamp,
    required this.capture,
    required this.prose,
    required this.navLabel,
    required this.pipHeadline,
    required this.pipAgent,
    required this.pipState,
    required this.pipMeta,
  });

  final Brightness brightness;

  final Color backgroundPrimary;
  final Color backgroundSecondary;
  final Color surfacePrimary;
  final Color surfaceSecondary;
  final Color borderSubtle;
  final Color borderNormal;
  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;
  final Color textDisabled;
  final Color accent;
  final Color accentMuted;
  final Color warning;
  final Color warningMuted;
  final Color danger;
  final SyntaxPalette syntax;

  final Color scrim;

  final Color mediaBackdrop;

  final Color selectionWash;

  final Color selectionWashCurrent;

  final Color terminalSelectionWash;

  final Color diffMapWindow;
  final Color diffAddedGround;
  final Color diffRemovedGround;
  final Color diffCappedGround;
  final Color diffAddedRun;
  final Color diffRemovedRun;

  final TerminalPalette terminal;

  final TextStyle screenTitle;
  final TextStyle breadcrumb;
  final TextStyle panelHeader;
  final TextStyle rowKicker;
  final TextStyle rowTitle;
  final TextStyle rowTitleLead;
  final TextStyle rowSubtitle;
  final TextStyle value;
  final TextStyle valueStrong;
  final TextStyle label;
  final TextStyle heroName;
  final TextStyle heroPercent;
  final TextStyle noteBody;
  final TextStyle buildStamp;
  final TextStyle capture;
  final TextStyle prose;
  final TextStyle navLabel;
  final TextStyle pipHeadline;
  final TextStyle pipAgent;
  final TextStyle pipState;
  final TextStyle pipMeta;

  static const house = DazzleTokens(
    brightness: Brightness.dark,
    backgroundPrimary: DazzleColors.backgroundPrimary,
    backgroundSecondary: DazzleColors.backgroundSecondary,
    surfacePrimary: DazzleColors.surfacePrimary,
    surfaceSecondary: DazzleColors.surfaceSecondary,
    borderSubtle: DazzleColors.borderSubtle,
    borderNormal: DazzleColors.borderNormal,
    textPrimary: DazzleColors.textPrimary,
    textSecondary: DazzleColors.textSecondary,
    textMuted: DazzleColors.textMuted,
    textDisabled: DazzleColors.textDisabled,
    accent: DazzleColors.accent,
    accentMuted: DazzleColors.accentMuted,
    warning: DazzleColors.warning,
    warningMuted: DazzleColors.warningMuted,
    danger: DazzleColors.danger,
    syntax: SyntaxPalette.house,
    scrim: Color(0x99000000),
    mediaBackdrop: Color(0xFF000000),
    selectionWash: Color(0x33B7FF2A),
    selectionWashCurrent: Color(0x88B7FF2A),
    terminalSelectionWash: Color(0x55B7FF2A),
    diffMapWindow: Color(0x1FE8E8E3),
    diffAddedGround: Color(0x1AB7FF2A),
    diffRemovedGround: Color(0x1FB84A4A),
    diffCappedGround: Color(0x1FD6A34B),
    diffAddedRun: Color(0x40B7FF2A),
    diffRemovedRun: Color(0x4DB84A4A),
    terminal: _houseTerminal,
    screenTitle: DazzleText.screenTitle,
    breadcrumb: DazzleText.breadcrumb,
    panelHeader: DazzleText.panelHeader,
    rowKicker: DazzleText.rowKicker,
    rowTitle: DazzleText.rowTitle,
    rowTitleLead: DazzleText.rowTitleLead,
    rowSubtitle: DazzleText.rowSubtitle,
    value: DazzleText.value,
    valueStrong: DazzleText.valueStrong,
    label: DazzleText.label,
    heroName: DazzleText.heroName,
    heroPercent: DazzleText.heroPercent,
    noteBody: DazzleText.noteBody,
    buildStamp: DazzleText.buildStamp,
    capture: DazzleText.capture,
    prose: DazzleText.prose,
    navLabel: DazzleText.navLabel,
    pipHeadline: DazzleText.pipHeadline,
    pipAgent: DazzleText.pipAgent,
    pipState: DazzleText.pipState,
    pipMeta: DazzleText.pipMeta,
  );

  static const _houseTerminal = TerminalPalette(
    foreground: DazzleColors.textPrimary,
    background: Color(0xFF000000),
    cursor: DazzleColors.accent,
    ansi: [
      DazzleColors.backgroundPrimary,
      Color(0xFFCD3131),
      DazzleColors.accent,
      Color(0xFFE5E510),
      Color(0xFF2472C8),
      Color(0xFFBC3FBC),
      Color(0xFF11A8CD),
      DazzleColors.textPrimary,
      DazzleColors.textDisabled,
      Color(0xFFF14C4C),
      DazzleColors.accentMuted,
      Color(0xFFF5F543),
      Color(0xFF3B8EEA),
      Color(0xFFD670D6),
      Color(0xFF29B8DB),
      Color(0xFFFFFFFF),
    ],
  );

  @override
  DazzleTokens copyWith({
    Brightness? brightness,
    Color? backgroundPrimary,
    Color? backgroundSecondary,
    Color? surfacePrimary,
    Color? surfaceSecondary,
    Color? borderSubtle,
    Color? borderNormal,
    Color? textPrimary,
    Color? textSecondary,
    Color? textMuted,
    Color? textDisabled,
    Color? accent,
    Color? accentMuted,
    Color? warning,
    Color? warningMuted,
    Color? danger,
    SyntaxPalette? syntax,
    Color? scrim,
    Color? mediaBackdrop,
    Color? selectionWash,
    Color? selectionWashCurrent,
    Color? terminalSelectionWash,
    Color? diffMapWindow,
    Color? diffAddedGround,
    Color? diffRemovedGround,
    Color? diffCappedGround,
    Color? diffAddedRun,
    Color? diffRemovedRun,
    TerminalPalette? terminal,
    TextStyle? screenTitle,
    TextStyle? breadcrumb,
    TextStyle? panelHeader,
    TextStyle? rowKicker,
    TextStyle? rowTitle,
    TextStyle? rowTitleLead,
    TextStyle? rowSubtitle,
    TextStyle? value,
    TextStyle? valueStrong,
    TextStyle? label,
    TextStyle? heroName,
    TextStyle? heroPercent,
    TextStyle? noteBody,
    TextStyle? buildStamp,
    TextStyle? capture,
    TextStyle? prose,
    TextStyle? navLabel,
    TextStyle? pipHeadline,
    TextStyle? pipAgent,
    TextStyle? pipState,
    TextStyle? pipMeta,
  }) {
    return DazzleTokens(
      brightness: brightness ?? this.brightness,
      backgroundPrimary: backgroundPrimary ?? this.backgroundPrimary,
      backgroundSecondary: backgroundSecondary ?? this.backgroundSecondary,
      surfacePrimary: surfacePrimary ?? this.surfacePrimary,
      surfaceSecondary: surfaceSecondary ?? this.surfaceSecondary,
      borderSubtle: borderSubtle ?? this.borderSubtle,
      borderNormal: borderNormal ?? this.borderNormal,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textMuted: textMuted ?? this.textMuted,
      textDisabled: textDisabled ?? this.textDisabled,
      accent: accent ?? this.accent,
      accentMuted: accentMuted ?? this.accentMuted,
      warning: warning ?? this.warning,
      warningMuted: warningMuted ?? this.warningMuted,
      danger: danger ?? this.danger,
      syntax: syntax ?? this.syntax,
      scrim: scrim ?? this.scrim,
      mediaBackdrop: mediaBackdrop ?? this.mediaBackdrop,
      selectionWash: selectionWash ?? this.selectionWash,
      selectionWashCurrent: selectionWashCurrent ?? this.selectionWashCurrent,
      terminalSelectionWash:
          terminalSelectionWash ?? this.terminalSelectionWash,
      diffMapWindow: diffMapWindow ?? this.diffMapWindow,
      diffAddedGround: diffAddedGround ?? this.diffAddedGround,
      diffRemovedGround: diffRemovedGround ?? this.diffRemovedGround,
      diffCappedGround: diffCappedGround ?? this.diffCappedGround,
      diffAddedRun: diffAddedRun ?? this.diffAddedRun,
      diffRemovedRun: diffRemovedRun ?? this.diffRemovedRun,
      terminal: terminal ?? this.terminal,
      screenTitle: screenTitle ?? this.screenTitle,
      breadcrumb: breadcrumb ?? this.breadcrumb,
      panelHeader: panelHeader ?? this.panelHeader,
      rowKicker: rowKicker ?? this.rowKicker,
      rowTitle: rowTitle ?? this.rowTitle,
      rowTitleLead: rowTitleLead ?? this.rowTitleLead,
      rowSubtitle: rowSubtitle ?? this.rowSubtitle,
      value: value ?? this.value,
      valueStrong: valueStrong ?? this.valueStrong,
      label: label ?? this.label,
      heroName: heroName ?? this.heroName,
      heroPercent: heroPercent ?? this.heroPercent,
      noteBody: noteBody ?? this.noteBody,
      buildStamp: buildStamp ?? this.buildStamp,
      capture: capture ?? this.capture,
      prose: prose ?? this.prose,
      navLabel: navLabel ?? this.navLabel,
      pipHeadline: pipHeadline ?? this.pipHeadline,
      pipAgent: pipAgent ?? this.pipAgent,
      pipState: pipState ?? this.pipState,
      pipMeta: pipMeta ?? this.pipMeta,
    );
  }

  @override
  DazzleTokens lerp(ThemeExtension<DazzleTokens>? other, double t) {
    if (other is! DazzleTokens) return this;
    Color c(Color a, Color b) => Color.lerp(a, b, t)!;
    TextStyle s(TextStyle a, TextStyle b) => TextStyle.lerp(a, b, t)!;
    return DazzleTokens(
      // A brightness does not blend: the crossfade in the colours is the transition, and the
      // platform brightness flips once it is done.
      brightness: t < 0.5 ? brightness : other.brightness,
      backgroundPrimary: c(backgroundPrimary, other.backgroundPrimary),
      backgroundSecondary: c(backgroundSecondary, other.backgroundSecondary),
      surfacePrimary: c(surfacePrimary, other.surfacePrimary),
      surfaceSecondary: c(surfaceSecondary, other.surfaceSecondary),
      borderSubtle: c(borderSubtle, other.borderSubtle),
      borderNormal: c(borderNormal, other.borderNormal),
      textPrimary: c(textPrimary, other.textPrimary),
      textSecondary: c(textSecondary, other.textSecondary),
      textMuted: c(textMuted, other.textMuted),
      textDisabled: c(textDisabled, other.textDisabled),
      accent: c(accent, other.accent),
      accentMuted: c(accentMuted, other.accentMuted),
      warning: c(warning, other.warning),
      warningMuted: c(warningMuted, other.warningMuted),
      danger: c(danger, other.danger),
      syntax: syntax.lerpTo(other.syntax, t),
      scrim: c(scrim, other.scrim),
      mediaBackdrop: c(mediaBackdrop, other.mediaBackdrop),
      selectionWash: c(selectionWash, other.selectionWash),
      selectionWashCurrent: c(selectionWashCurrent, other.selectionWashCurrent),
      terminalSelectionWash: c(
        terminalSelectionWash,
        other.terminalSelectionWash,
      ),
      diffMapWindow: c(diffMapWindow, other.diffMapWindow),
      diffAddedGround: c(diffAddedGround, other.diffAddedGround),
      diffRemovedGround: c(diffRemovedGround, other.diffRemovedGround),
      diffCappedGround: c(diffCappedGround, other.diffCappedGround),
      diffAddedRun: c(diffAddedRun, other.diffAddedRun),
      diffRemovedRun: c(diffRemovedRun, other.diffRemovedRun),
      // A terminal palette does not blend either — there is no sensible midpoint for an ANSI
      // colour table.
      terminal: t < 0.5 ? terminal : other.terminal,
      screenTitle: s(screenTitle, other.screenTitle),
      breadcrumb: s(breadcrumb, other.breadcrumb),
      panelHeader: s(panelHeader, other.panelHeader),
      rowKicker: s(rowKicker, other.rowKicker),
      rowTitle: s(rowTitle, other.rowTitle),
      rowTitleLead: s(rowTitleLead, other.rowTitleLead),
      rowSubtitle: s(rowSubtitle, other.rowSubtitle),
      value: s(value, other.value),
      valueStrong: s(valueStrong, other.valueStrong),
      label: s(label, other.label),
      heroName: s(heroName, other.heroName),
      heroPercent: s(heroPercent, other.heroPercent),
      noteBody: s(noteBody, other.noteBody),
      buildStamp: s(buildStamp, other.buildStamp),
      capture: s(capture, other.capture),
      prose: s(prose, other.prose),
      navLabel: s(navLabel, other.navLabel),
      pipHeadline: s(pipHeadline, other.pipHeadline),
      pipAgent: s(pipAgent, other.pipAgent),
      pipState: s(pipState, other.pipState),
      pipMeta: s(pipMeta, other.pipMeta),
    );
  }
}

extension DazzleTokensContext on BuildContext {
  DazzleTokens get tokens => Theme.of(this).extension<DazzleTokens>()!;
}
