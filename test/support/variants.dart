import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dazzle/design/dynamic_tokens.dart';
import 'package:dazzle/design/tokens.dart';

/// One shape the app is read on, in the dp the spec is written in.
///
/// Sizes were picked per test before this file, which meant the fold and the
/// content column were only exercised where somebody had remembered them. A
/// route that runs over [surfaces] is a route that has been read on every
/// shape the app actually meets.
class Surface {
  const Surface(this.name, this.width, this.height);

  /// The emulator and faraday closed: 1080x2400 at the 2.625 the panel
  /// reports. The narrow case, and the one every layout has to fit.
  static const phone = Surface('phone', 411, 914);

  /// faraday open, which the toolchain simulates as `wm size 2232x2310` at
  /// that same density. Wide enough to be past [Layout.columnMax] and short
  /// enough that a route which only ever ran tall stops fitting.
  static const fold = Surface('fold', 850, 880);

  /// Past the 600dp cap with room to spare, so the content column is centred
  /// and the gutter is not a rounding error.
  static const wide = Surface('wide', 700, 1600);

  /// Not a device: the long strip a test uses when the point is what a route
  /// contains rather than how it fits. Deliberately outside [surfaces].
  static const strip = Surface('strip', 400, 2400);

  final String name;
  final double width;
  final double height;

  @override
  String toString() => name;
}

/// The shapes a route-level test is expected to hold on.
final surfaces = ValueVariant<Surface>({
  Surface.phone,
  Surface.fold,
  Surface.wide,
});

/// Puts [tester] on [surface] for the rest of the test.
///
/// The ratio is pinned to 1 so the numbers a test writes are the dp the spec
/// is written in, which is the convention every hand-sized test already used.
void useSurface(WidgetTester tester, Surface surface) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = ui.Size(surface.width, surface.height);
  addTearDown(tester.view.reset);
}

/// One of the three palettes the app can be wearing.
///
/// THEME's system setting is not one palette but two: the tokens are built
/// from the platform's own scheme, and light is where the house's assumption
/// of a dark ground is tested. The user reads the app on the light one, so it
/// belongs in the variant rather than in whichever test remembered it.
class Palette {
  const Palette(this.name, this.tokens);

  static final house = Palette('house', DazzleTokens.house);

  static final systemLight = Palette(
    'system light',
    dazzleTokensForSystem(
      platformBrightness: Brightness.light,
      lightDynamic: null,
      darkDynamic: null,
    ),
  );

  static final systemDark = Palette(
    'system dark',
    dazzleTokensForSystem(
      platformBrightness: Brightness.dark,
      lightDynamic: null,
      darkDynamic: null,
    ),
  );

  final String name;
  final DazzleTokens tokens;

  /// Wired the way `DazzleApp` wires it, so `context.tokens` under a test's
  /// `MaterialApp` resolves to this palette.
  ThemeData get theme => ThemeData(extensions: [tokens]);

  @override
  String toString() => name;
}

/// The palettes a themed test is expected to hold on.
final palettes = ValueVariant<Palette>({
  Palette.house,
  Palette.systemLight,
  Palette.systemDark,
});
