import 'package:flutter/material.dart';

import 'package:upgrade/design/colors.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/design/typography.dart';

/// Only the chrome moves. [SyntaxPalette], the terminal's ANSI table and the diff
/// grounds stay the house's: they are read against always-dark surfaces.
UpgradeTokens upgradeTokensFromScheme(ColorScheme scheme) {
  TextStyle recolor(TextStyle base, Color color) => base.copyWith(color: color);

  final textPrimary = scheme.onSurface;
  final textSecondary = scheme.onSurfaceVariant;
  final textMuted = scheme.onSurfaceVariant;
  final textDisabled = scheme.onSurface.withValues(alpha: 0.38);
  final accent = scheme.primary;

  return UpgradeTokens(
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
    scrim: UpgradeTokens.house.scrim,
    mediaBackdrop: UpgradeTokens.house.mediaBackdrop,
    selectionWash: accent.withValues(alpha: 0.20),
    selectionWashCurrent: accent.withValues(alpha: 0.53),
    terminalSelectionWash: accent.withValues(alpha: 0.33),
    diffMapWindow: UpgradeTokens.house.diffMapWindow,
    diffAddedGround: UpgradeTokens.house.diffAddedGround,
    diffRemovedGround: UpgradeTokens.house.diffRemovedGround,
    diffCappedGround: UpgradeTokens.house.diffCappedGround,
    diffAddedRun: UpgradeTokens.house.diffAddedRun,
    diffRemovedRun: UpgradeTokens.house.diffRemovedRun,
    terminal: UpgradeTokens.house.terminal,
    screenTitle: recolor(UpgradeText.screenTitle, textPrimary),
    breadcrumb: recolor(UpgradeText.breadcrumb, textMuted),
    panelHeader: recolor(UpgradeText.panelHeader, textMuted),
    rowKicker: recolor(UpgradeText.rowKicker, textSecondary),
    rowTitle: recolor(UpgradeText.rowTitle, textPrimary),
    rowTitleLead: recolor(UpgradeText.rowTitleLead, textPrimary),
    rowSubtitle: recolor(UpgradeText.rowSubtitle, textMuted),
    value: recolor(UpgradeText.value, textMuted),
    valueStrong: recolor(UpgradeText.valueStrong, textPrimary),
    label: recolor(UpgradeText.label, textMuted),
    heroName: recolor(UpgradeText.heroName, textPrimary),
    heroPercent: recolor(UpgradeText.heroPercent, accent),
    noteBody: recolor(UpgradeText.noteBody, textPrimary),
    buildStamp: recolor(UpgradeText.buildStamp, textMuted),
    capture: recolor(UpgradeText.capture, textMuted),
    prose: recolor(UpgradeText.prose, textSecondary),
    navLabel: recolor(UpgradeText.navLabel, textMuted),
    pipHeadline: recolor(UpgradeText.pipHeadline, textPrimary),
    pipAgent: recolor(UpgradeText.pipAgent, textPrimary),
    pipState: recolor(UpgradeText.pipState, textSecondary),
    pipMeta: recolor(UpgradeText.pipMeta, textSecondary),
  );
}

UpgradeTokens upgradeTokensForSystem({
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
        seedColor: UpgradeColors.accent,
        brightness: platformBrightness,
      );
  return upgradeTokensFromScheme(scheme);
}
