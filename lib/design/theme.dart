import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'colors.dart';
import 'motion.dart';
import 'spacing.dart';
import 'typography.dart';

/// Material is used as a substrate only. Everything that would leak a Material
/// look — ripples, elevation tints, drop shadows, rounded defaults, overscroll
/// glow, the zoom page transition — is neutralized here so components can be
/// built from the Dazzle tokens alone.
abstract final class DazzleTheme {
  static ThemeData build() {
    const colorScheme = ColorScheme.dark(
      primary: DazzleColors.accent,
      onPrimary: DazzleColors.backgroundPrimary,
      secondary: DazzleColors.accentMuted,
      onSecondary: DazzleColors.backgroundPrimary,
      surface: DazzleColors.surfacePrimary,
      onSurface: DazzleColors.textPrimary,
      error: DazzleColors.danger,
      onError: DazzleColors.textPrimary,
      outline: DazzleColors.borderNormal,
      outlineVariant: DazzleColors.borderSubtle,
      surfaceTint: Colors.transparent,
      shadow: Colors.transparent,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: DazzleColors.backgroundPrimary,
      canvasColor: DazzleColors.backgroundPrimary,
      shadowColor: Colors.transparent,
      visualDensity: VisualDensity.compact,

      // No ripple, no highlight bloom, no hover wash.
      splashFactory: NoSplash.splashFactory,
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
      hoverColor: Colors.transparent,
      focusColor: Colors.transparent,

      fontFamily: FontFamilies.ui,
      textTheme: _textTheme,
      iconTheme: const IconThemeData(
        color: DazzleColors.textSecondary,
        size: IconSizes.lg,
      ),
      dividerTheme: const DividerThemeData(
        color: DazzleColors.borderSubtle,
        thickness: Borders.hairline,
        space: Borders.hairline,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: DazzleColors.backgroundPrimary,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: DazzleText.screenTitle,
      ),
      textSelectionTheme: const TextSelectionThemeData(
        cursorColor: DazzleColors.accent,
        selectionColor: Color(0x33B7FF2A),
        selectionHandleColor: DazzleColors.accent,
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: _SignalPageTransition(),
          TargetPlatform.linux: _SignalPageTransition(),
        },
      ),
    );
  }

  static const _textTheme = TextTheme(
    headlineLarge: DazzleText.screenTitle,
    headlineMedium: DazzleText.heroName,
    titleMedium: DazzleText.rowTitle,
    titleSmall: DazzleText.panelHeader,
    bodyMedium: DazzleText.prose,
    bodySmall: DazzleText.rowSubtitle,
    labelLarge: DazzleText.value,
    labelMedium: DazzleText.navLabel,
    labelSmall: DazzleText.label,
  );
}

/// Overscroll glow is a Material tell; a hard stop reads as a real instrument.
final class DazzleScrollBehavior extends MaterialScrollBehavior {
  const DazzleScrollBehavior();

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

/// Short opacity plus a small directional shift, replacing
/// Material's zoom transition.
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
