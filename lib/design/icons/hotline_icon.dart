import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../colors.dart';
import '../effects/glitch.dart';
import '../spacing.dart';
import 'hotline_icons.dart';

/// The only way icons reach the tree. Every asset is monochrome `currentColor`,
/// so colouring is a theme decision here rather than a property of the file.
class HotlineIcon extends StatelessWidget {
  const HotlineIcon(
    this.icon, {
    super.key,
    this.size = IconSizes.lg,
    this.color = HotlineColors.textSecondary,
    this.signal = false,
    this.glitch,
  });

  final HotlineIcons icon;
  final double size;
  final Color color;

  /// Renders the nodes-only variant (SPEC.md §16b glitch frame 2).
  final bool signal;

  /// When attached, a [GlitchController.fire] plays the §16b frame sequence on
  /// this icon. Reduce-motion drops it entirely rather than shortening it.
  final GlitchController? glitch;

  Widget _svg({required bool asSignal, required Color paint}) {
    return SvgPicture.asset(
      asSignal ? icon.signalAsset : icon.asset,
      width: size,
      height: size,
      theme: SvgTheme(currentColor: paint),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rest = _svg(asSignal: signal, paint: color);
    final controller = glitch;
    if (controller == null || MediaQuery.disableAnimationsOf(context)) {
      return rest;
    }
    return GlitchedIcon(controller: controller, rest: rest, frame: _svg);
  }
}

/// The icons a [GlitchController] is ever attached to: the two nav glyphs
/// (§16b tab change, autonomous tick, capture landing), the task checkbox and
/// the capture target glyph.
const glitchIcons = [
  HotlineIcons.home,
  HotlineIcons.projects,
  HotlineIcons.checkboxChecked,
  HotlineIcons.checkboxEmpty,
  HotlineIcons.submit,
];

/// A glitch frame swaps both the asset and the colour, and flutter_svg keys its
/// cache on the pair — so the first play of a sequence decodes entries it has
/// never seen and renders nothing until each one lands, which on device shows
/// up as the icon blinking out for a frame. Warming the pairs is what makes the
/// first flipbook run as clean as the tenth.
///
/// Deliberately not awaited by `main()`: it gates nothing, and §16b forbids an
/// effect that delays input readiness. The §16c.1 log outlasts it either way.
Future<void> warmGlitchIcons() {
  const paints = [HotlineColors.textPrimary, HotlineColors.accent];
  return Future.wait([
    for (final icon in glitchIcons)
      for (final paint in paints)
        for (final asset in [icon.asset, icon.signalAsset])
          SvgAssetLoader(
            asset,
            theme: SvgTheme(currentColor: paint),
          ).loadBytes(null),
  ]);
}

/// Split out so a widget test can assert the glitch layer exists (or, under
/// reduce-motion, does not) without having to rasterise an SVG.
class GlitchedIcon extends StatelessWidget {
  const GlitchedIcon({
    super.key,
    required this.controller,
    required this.rest,
    required this.frame,
  });

  final GlitchController controller;

  /// What the icon looks like when nothing is happening, which is almost always.
  final Widget rest;
  final Widget Function({required bool asSignal, required Color paint}) frame;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        // Frames, in order: displaced slices, signal variant, accent, settle.
        // Only the accent frame changes colour, so the sequence reads as the
        // icon breaking up rather than as a colour animation.
        return switch (controller.frame) {
          0 => GlitchSlices(
            seed: controller.seed,
            child: frame(asSignal: false, paint: HotlineColors.textPrimary),
          ),
          1 => frame(asSignal: true, paint: HotlineColors.textPrimary),
          2 => frame(asSignal: false, paint: HotlineColors.accent),
          3 => GlitchSlices(
            seed: controller.seed + 1,
            magnitude: 1,
            child: frame(asSignal: false, paint: HotlineColors.textPrimary),
          ),
          _ => child!,
        };
      },
      child: rest,
    );
  }
}
