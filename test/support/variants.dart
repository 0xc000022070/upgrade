import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:upgrade/design/dynamic_tokens.dart';
import 'package:upgrade/design/tokens.dart';

/// One shape the app is read on, in the dp the spec is written in.
class Surface {
  const Surface(this.name, this.width, this.height);

  /// The emulator, and a Pixel 10 Pro Fold closed: 1080x2400 at the 2.625 the panel reports.
  static const phone = Surface('phone', 411, 914);

  /// A Pixel 10 Pro Fold open, which the toolchain simulates as `wm size 2232x2310` at that same
  /// density.
  static const fold = Surface('fold', 850, 880);

  /// Past the 600dp cap with room to spare.
  static const wide = Surface('wide', 700, 1600);

  /// Not a device: the long strip a test uses when the point is what a route contains
  /// rather than how it fits. Deliberately outside [surfaces].
  static const strip = Surface('strip', 400, 2400);

  final String name;
  final double width;
  final double height;

  @override
  String toString() => name;
}

final surfaces = ValueVariant<Surface>({
  Surface.phone,
  Surface.fold,
  Surface.wide,
});

/// The ratio is pinned to 1 so the numbers a test writes are the dp the spec is written
/// in.
void useSurface(WidgetTester tester, Surface surface) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = ui.Size(surface.width, surface.height);
  addTearDown(tester.view.reset);
}

/// THEME's system setting is not one palette but two: the tokens are built from the
/// platform's own scheme, and light is where the house's assumption of a dark ground is
/// tested.
class Palette {
  const Palette(this.name, this.tokens);

  static final house = Palette('house', UpgradeTokens.house);

  static final systemLight = Palette(
    'system light',
    upgradeTokensForSystem(
      platformBrightness: Brightness.light,
      lightDynamic: null,
      darkDynamic: null,
    ),
  );

  static final systemDark = Palette(
    'system dark',
    upgradeTokensForSystem(
      platformBrightness: Brightness.dark,
      lightDynamic: null,
      darkDynamic: null,
    ),
  );

  final String name;
  final UpgradeTokens tokens;

  ThemeData get theme => ThemeData(extensions: [tokens]);

  @override
  String toString() => name;
}

final palettes = ValueVariant<Palette>({
  Palette.house,
  Palette.systemLight,
  Palette.systemDark,
});
