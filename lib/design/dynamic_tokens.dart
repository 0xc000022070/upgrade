import 'package:flutter/material.dart';

import 'colors.dart';
import 'tokens.dart';
import 'typography.dart';

/// Turns a platform [ColorScheme] — Material You's tonal palette, or a seeded
/// fallback where the device has none — into a [DazzleTokens] instance.
///
/// Only the chrome moves. [SyntaxPalette], the terminal's ANSI table and the
/// diff grounds stay the house's: they exist so code and diffs stay legible
/// against the always-dark surfaces they are read on, and a wallpaper's hue
/// has no bearing on that legibility.
DazzleTokens dazzleTokensFromScheme(ColorScheme scheme) {
  TextStyle recolor(TextStyle base, Color color) =>
      base.copyWith(color: color);

  final textPrimary = scheme.onSurface;
  final textSecondary = scheme.onSurfaceVariant;
  final textMuted = scheme.onSurfaceVariant.withValues(alpha: 0.7);
  final textDisabled = scheme.onSurface.withValues(alpha: 0.38);
  final accent = scheme.primary;

  return DazzleTokens(
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
    danger: scheme.error,
    syntax: SyntaxPalette.house,
    scrim: DazzleTokens.house.scrim,
    mediaBackdrop: DazzleTokens.house.mediaBackdrop,
    selectionWash: accent.withValues(alpha: 0.20),
    selectionWashCurrent: accent.withValues(alpha: 0.53),
    terminalSelectionWash: accent.withValues(alpha: 0.33),
    diffMapWindow: DazzleTokens.house.diffMapWindow,
    diffAddedGround: DazzleTokens.house.diffAddedGround,
    diffRemovedGround: DazzleTokens.house.diffRemovedGround,
    diffCappedGround: DazzleTokens.house.diffCappedGround,
    diffAddedRun: DazzleTokens.house.diffAddedRun,
    diffRemovedRun: DazzleTokens.house.diffRemovedRun,
    terminal: DazzleTokens.house.terminal,
    screenTitle: recolor(DazzleText.screenTitle, textPrimary),
    breadcrumb: recolor(DazzleText.breadcrumb, textMuted),
    panelHeader: recolor(DazzleText.panelHeader, textMuted),
    rowKicker: recolor(DazzleText.rowKicker, textSecondary),
    rowTitle: recolor(DazzleText.rowTitle, textPrimary),
    rowTitleLead: recolor(DazzleText.rowTitleLead, textPrimary),
    rowSubtitle: recolor(DazzleText.rowSubtitle, textMuted),
    value: recolor(DazzleText.value, textMuted),
    valueStrong: recolor(DazzleText.valueStrong, textPrimary),
    label: recolor(DazzleText.label, textMuted),
    heroName: recolor(DazzleText.heroName, textPrimary),
    heroPercent: recolor(DazzleText.heroPercent, accent),
    noteBody: recolor(DazzleText.noteBody, textPrimary),
    buildStamp: recolor(DazzleText.buildStamp, textMuted),
    capture: recolor(DazzleText.capture, textMuted),
    prose: recolor(DazzleText.prose, textSecondary),
    navLabel: recolor(DazzleText.navLabel, textMuted),
    pipHeadline: recolor(DazzleText.pipHeadline, textPrimary),
    pipAgent: recolor(DazzleText.pipAgent, textPrimary),
    pipState: recolor(DazzleText.pipState, textSecondary),
    pipMeta: recolor(DazzleText.pipMeta, textSecondary),
  );
}

/// Resolves the `[ THEME ]` SYSTEM setting into tokens: Material You's tonal
/// palette when the platform hands one over, a [ColorScheme] seeded from the
/// house accent otherwise — so SYSTEM always tracks at least light/dark, even
/// on a device or OS version with no dynamic colour to offer.
DazzleTokens dazzleTokensForSystem({
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
        seedColor: DazzleColors.accent,
        brightness: platformBrightness,
      );
  return dazzleTokensFromScheme(scheme);
}
