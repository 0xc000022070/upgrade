import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'motion.dart';
import 'spacing.dart';
import 'tokens.dart';
import 'typography.dart';

/// Material is a substrate only. Everything that would leak a Material look — ripples,
/// elevation tints, shadows, rounded defaults, overscroll glow, the zoom transition — is
/// neutralized here.
abstract final class UpgradeTheme {
  static ThemeData build([UpgradeTokens tokens = UpgradeTokens.house]) {
    final schemeBuilder = tokens.brightness == Brightness.dark
        ? ColorScheme.dark
        : ColorScheme.light;
    final colorScheme = schemeBuilder(
      primary: tokens.accent,
      onPrimary: tokens.backgroundPrimary,
      secondary: tokens.accentMuted,
      onSecondary: tokens.backgroundPrimary,
      surface: tokens.surfacePrimary,
      onSurface: tokens.textPrimary,
      error: tokens.danger,
      onError: tokens.textPrimary,
      outline: tokens.borderNormal,
      outlineVariant: tokens.borderSubtle,
      surfaceTint: Colors.transparent,
      shadow: Colors.transparent,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: tokens.brightness,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: tokens.backgroundPrimary,
      canvasColor: tokens.backgroundPrimary,
      shadowColor: Colors.transparent,
      visualDensity: VisualDensity.compact,
      extensions: [tokens],

      splashFactory: NoSplash.splashFactory,
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
      hoverColor: Colors.transparent,
      focusColor: Colors.transparent,

      fontFamily: FontFamilies.ui,
      textTheme: _textTheme(tokens),
      iconTheme: IconThemeData(color: tokens.textSecondary, size: IconSizes.lg),
      dividerTheme: DividerThemeData(
        color: tokens.borderSubtle,
        thickness: Borders.hairline,
        space: Borders.hairline,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: tokens.backgroundPrimary,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: tokens.screenTitle,
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: tokens.accent,
        selectionColor: tokens.selectionWash,
        selectionHandleColor: tokens.accent,
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: _SignalPageTransition(),
          TargetPlatform.linux: _SignalPageTransition(),
        },
      ),
    );
  }

  static TextTheme _textTheme(UpgradeTokens tokens) => TextTheme(
    headlineLarge: tokens.screenTitle,
    headlineMedium: tokens.heroName,
    titleMedium: tokens.rowTitle,
    titleSmall: tokens.panelHeader,
    bodyMedium: tokens.prose,
    bodySmall: tokens.rowSubtitle,
    labelLarge: tokens.value,
    labelMedium: tokens.navLabel,
    labelSmall: tokens.label,
  );
}

final class UpgradeScrollBehavior extends MaterialScrollBehavior {
  const UpgradeScrollBehavior();

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => child;

  @override
  Set<PointerDeviceKind> get dragDevices => const {
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.stylus,
  };
}

final class _SignalPageTransition extends PageTransitionsBuilder {
  const _SignalPageTransition();

  @override
  Duration get transitionDuration => Motion.deliberate;

  @override
  Widget buildTransitions<T>(
    PageRoute<T>? route,
    BuildContext? context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Motion.enter,
      reverseCurve: Motion.exit,
    );

    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.02),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  }
}
