import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'colors.dart';
import 'motion.dart';
import 'spacing.dart';
import 'typography.dart';

/// Material is used as a substrate only. Everything that would leak a Material
/// look — ripples, elevation tints, drop shadows, rounded defaults, overscroll
/// glow, the zoom page transition — is neutralized here so components can be
/// built from the Hotline tokens alone.
abstract final class HotlineTheme {
  static ThemeData build() {
    const colorScheme = ColorScheme.dark(
      primary: HotlineColors.accent,
      onPrimary: HotlineColors.backgroundPrimary,
      secondary: HotlineColors.accentMuted,
      onSecondary: HotlineColors.backgroundPrimary,
      surface: HotlineColors.surfacePrimary,
      onSurface: HotlineColors.textPrimary,
      error: HotlineColors.danger,
      onError: HotlineColors.textPrimary,
      outline: HotlineColors.borderNormal,
      outlineVariant: HotlineColors.borderSubtle,
      surfaceTint: Colors.transparent,
      shadow: Colors.transparent,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: HotlineColors.backgroundPrimary,
      canvasColor: HotlineColors.backgroundPrimary,
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
        color: HotlineColors.textSecondary,
        size: IconSizes.lg,
      ),
      dividerTheme: const DividerThemeData(
        color: HotlineColors.borderSubtle,
        thickness: Borders.hairline,
        space: Borders.hairline,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: HotlineColors.backgroundPrimary,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: HotlineText.screenTitle,
      ),
      textSelectionTheme: const TextSelectionThemeData(
        cursorColor: HotlineColors.accent,
        selectionColor: Color(0x33B7FF2A),
        selectionHandleColor: HotlineColors.accent,
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
    headlineLarge: HotlineText.screenTitle,
    headlineMedium: HotlineText.heroName,
    titleMedium: HotlineText.rowTitle,
    titleSmall: HotlineText.panelHeader,
    bodyMedium: HotlineText.prose,
    bodySmall: HotlineText.rowSubtitle,
    labelLarge: HotlineText.value,
    labelMedium: HotlineText.navLabel,
    labelSmall: HotlineText.label,
  );
}

/// Overscroll glow is a Material tell; a hard stop reads as a real instrument.
final class HotlineScrollBehavior extends MaterialScrollBehavior {
  const HotlineScrollBehavior();

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
