import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:striked/design/dynamic_tokens.dart';
import 'package:striked/design/tokens.dart';

void main() {
  group('strikedTokensFromScheme', () {
    const scheme = ColorScheme(
      brightness: Brightness.light,
      primary: Color(0xFF111111),
      onPrimary: Color(0xFFFFFFFF),
      secondary: Color(0xFF222222),
      onSecondary: Color(0xFFFFFFFF),
      tertiary: Color(0xFF333333),
      onTertiary: Color(0xFFFFFFFF),
      error: Color(0xFF444444),
      onError: Color(0xFFFFFFFF),
      surface: Color(0xFF555555),
      onSurface: Color(0xFF666666),
      onSurfaceVariant: Color(0xFF777777),
      outline: Color(0xFF888888),
      outlineVariant: Color(0xFF999999),
      surfaceContainer: Color(0xFFAAAAAA),
      surfaceContainerLow: Color(0xFFBBBBBB),
      surfaceContainerHigh: Color(0xFFCCCCCC),
    );

    test('chrome follows the scheme', () {
      final tokens = strikedTokensFromScheme(scheme);
      expect(tokens.brightness, Brightness.light);
      expect(tokens.backgroundPrimary, scheme.surface);
      expect(tokens.backgroundSecondary, scheme.surfaceContainerLow);
      expect(tokens.surfacePrimary, scheme.surfaceContainer);
      expect(tokens.surfaceSecondary, scheme.surfaceContainerHigh);
      expect(tokens.borderSubtle, scheme.outlineVariant);
      expect(tokens.borderNormal, scheme.outline);
      expect(tokens.textPrimary, scheme.onSurface);
      expect(tokens.textSecondary, scheme.onSurfaceVariant);
      expect(tokens.accent, scheme.primary);
      expect(tokens.accentMuted, scheme.secondary);
      expect(tokens.warning, scheme.tertiary);
      expect(tokens.danger, scheme.error);
    });

    test('every text role is recoloured but keeps its house shape', () {
      final tokens = strikedTokensFromScheme(scheme);
      expect(tokens.screenTitle.color, scheme.onSurface);
      expect(
        tokens.screenTitle.fontFamily,
        StrikedTokens.house.screenTitle.fontFamily,
      );
      expect(
        tokens.screenTitle.fontSize,
        StrikedTokens.house.screenTitle.fontSize,
      );
      expect(tokens.heroPercent.color, scheme.primary);
      expect(
        tokens.panelHeader.color,
        isNot(StrikedTokens.house.panelHeader.color),
      );
    });

    test('code and diff palettes stay the house palette', () {
      final tokens = strikedTokensFromScheme(scheme);
      expect(tokens.syntax, StrikedTokens.house.syntax);
      expect(tokens.terminal, StrikedTokens.house.terminal);
      expect(tokens.diffAddedGround, StrikedTokens.house.diffAddedGround);
      expect(tokens.diffRemovedGround, StrikedTokens.house.diffRemovedGround);
      expect(tokens.mediaBackdrop, StrikedTokens.house.mediaBackdrop);
    });
  });

  group('strikedTokensForSystem', () {
    test('a dynamic scheme for the platform brightness wins when offered', () {
      const light = ColorScheme.light(primary: Color(0xFF00FF00));
      const dark = ColorScheme.dark(primary: Color(0xFFFF00FF));

      final atDark = strikedTokensForSystem(
        platformBrightness: Brightness.dark,
        lightDynamic: light,
        darkDynamic: dark,
      );
      expect(atDark.accent, dark.primary);
      expect(atDark.brightness, Brightness.dark);

      final atLight = strikedTokensForSystem(
        platformBrightness: Brightness.light,
        lightDynamic: light,
        darkDynamic: dark,
      );
      expect(atLight.accent, light.primary);
      expect(atLight.brightness, Brightness.light);
    });

    test('a seeded scheme stands in when the platform offers none', () {
      final tokens = strikedTokensForSystem(
        platformBrightness: Brightness.dark,
        lightDynamic: null,
        darkDynamic: null,
      );
      expect(tokens.brightness, Brightness.dark);
      expect(
        tokens.backgroundPrimary,
        isNot(StrikedTokens.house.backgroundPrimary),
      );
    });
  });
}
