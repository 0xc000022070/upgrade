import 'package:flutter/material.dart';

import 'package:striked/design/colors.dart';
import 'package:striked/design/tokens.dart';
import 'package:striked/design/typography.dart';

/// Only the chrome moves. [SyntaxPalette], the terminal's ANSI table and the diff
/// grounds stay the house's: they are read against always-dark surfaces.
StrikedTokens strikedTokensFromScheme(ColorScheme scheme) {
  TextStyle recolor(TextStyle base, Color color) => base.copyWith(color: color);

  final textPrimary = scheme.onSurface;
  final textSecondary = scheme.onSurfaceVariant;
  final textMuted = scheme.onSurfaceVariant;
  final textDisabled = scheme.onSurface.withValues(alpha: 0.38);
  final accent = scheme.primary;

  return StrikedTokens(
    brightness: scheme.brightness,
    backgroundPrimary: scheme.surface,
    backgroundSecondary: scheme.surfaceContainerLow,
    surfacePrimary: scheme.surfaceContainer,
    surfaceSecondary: scheme.surfaceContainerHigh,
    borderSubtle: scheme.outlineVariant,
    borderNormal: scheme.outline,
    textPrimary: textPrimary,
    textSecondary: textSecondary,
    textMuted: textMuted,
    textDisabled: textDisabled,
    accent: accent,
    accentMuted: scheme.secondary,
    warning: scheme.tertiary,
    warningMuted: scheme.tertiary.withValues(alpha: 0.7),
    danger: scheme.error,
    syntax: SyntaxPalette.house,
    scrim: StrikedTokens.house.scrim,
    mediaBackdrop: StrikedTokens.house.mediaBackdrop,
    selectionWash: accent.withValues(alpha: 0.20),
    selectionWashCurrent: accent.withValues(alpha: 0.53),
    terminalSelectionWash: accent.withValues(alpha: 0.33),
    diffMapWindow: StrikedTokens.house.diffMapWindow,
    diffAddedGround: StrikedTokens.house.diffAddedGround,
    diffRemovedGround: StrikedTokens.house.diffRemovedGround,
    diffCappedGround: StrikedTokens.house.diffCappedGround,
    diffAddedRun: StrikedTokens.house.diffAddedRun,
    diffRemovedRun: StrikedTokens.house.diffRemovedRun,
    terminal: StrikedTokens.house.terminal,
    screenTitle: recolor(StrikedText.screenTitle, textPrimary),
    breadcrumb: recolor(StrikedText.breadcrumb, textMuted),
    panelHeader: recolor(StrikedText.panelHeader, textMuted),
    rowKicker: recolor(StrikedText.rowKicker, textSecondary),
    rowTitle: recolor(StrikedText.rowTitle, textPrimary),
    rowTitleLead: recolor(StrikedText.rowTitleLead, textPrimary),
    rowSubtitle: recolor(StrikedText.rowSubtitle, textMuted),
    value: recolor(StrikedText.value, textMuted),
    valueStrong: recolor(StrikedText.valueStrong, textPrimary),
    label: recolor(StrikedText.label, textMuted),
    heroName: recolor(StrikedText.heroName, textPrimary),
    heroPercent: recolor(StrikedText.heroPercent, accent),
    noteBody: recolor(StrikedText.noteBody, textPrimary),
    buildStamp: recolor(StrikedText.buildStamp, textMuted),
    capture: recolor(StrikedText.capture, textMuted),
    prose: recolor(StrikedText.prose, textSecondary),
    navLabel: recolor(StrikedText.navLabel, textMuted),
    pipHeadline: recolor(StrikedText.pipHeadline, textPrimary),
    pipAgent: recolor(StrikedText.pipAgent, textPrimary),
    pipState: recolor(StrikedText.pipState, textSecondary),
    pipMeta: recolor(StrikedText.pipMeta, textSecondary),
  );
}

StrikedTokens strikedTokensForSystem({
  required Brightness platformBrightness,
  required ColorScheme? lightDynamic,
  required ColorScheme? darkDynamic,
}) {
  final dynamicScheme = platformBrightness == Brightness.dark
      ? darkDynamic
      : lightDynamic;
  final scheme =
      dynamicScheme ??
      ColorScheme.fromSeed(
        seedColor: StrikedColors.accent,
        brightness: platformBrightness,
      );
  return strikedTokensFromScheme(scheme);
}
