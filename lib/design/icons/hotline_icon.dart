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

  /// Renders the nodes-only variant. It is no longer part of the glitch
  /// sequence — see [GlitchedIcon] — so this is now only a way to ask for the
  /// variant outright.
  final bool signal;

  /// When attached, a [GlitchController.fire] plays the glitch frame sequence
  /// on this icon. Reduce-motion drops it entirely rather than shortening it.
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
    // The glitch recolours the icon it was given; it never swaps the icon out
    // for a different one, so the variant is fixed here and not per frame.
    return GlitchedIcon(
      controller: controller,
      rest: rest,
      frame: ({required Color paint}) => _svg(asSignal: signal, paint: paint),
    );
  }
}

/// The icons a [GlitchController] is ever attached to: the three nav glyphs
/// (tab change, autonomous tick, capture landing), the task checkbox and the
/// capture target glyph.
const glitchIcons = [
  HotlineIcons.home,
  HotlineIcons.projects,
  HotlineIcons.hosts,
  HotlineIcons.checkboxChecked,
  HotlineIcons.checkboxEmpty,
  HotlineIcons.submit,
];

/// A glitch frame swaps the colour, and flutter_svg keys its cache on the
/// asset/colour pair — so the first play of a sequence decodes entries it has
/// never seen and renders nothing until each one lands, which on device shows
/// up as the icon blinking out for a frame. Warming the pairs is what makes the
/// first flipbook run as clean as the tenth.
///
/// Deliberately not awaited by `main()`: it gates nothing, and no effect may
/// delay input readiness. The boot log outlasts it either way.
Future<void> warmGlitchIcons() {
  const paints = [HotlineColors.textPrimary, HotlineColors.accent];
  return Future.wait([
    for (final icon in glitchIcons)
      for (final paint in paints)
        SvgAssetLoader(
          icon.asset,
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
  final Widget Function({required Color paint}) frame;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        // Frames, in order: a light tear, a heavier one, the accent, the
        // heaviest, then the clean glyph. The block set grows across the
        // sequence rather than decaying — the shape of the artist's study in
        // design/explorations/motion — so the icon comes apart and is then
        // simply there again.
        //
        // The nodes-only frame is gone. On a glyph like the checkbox the
        // signal variant is a single 5x5 diamond, so that frame left 0% of the
        // shape on screen and read as the icon blinking out, which the "at
        // least 70% intact" rule exists to prevent.
        return switch (controller.frame) {
          0 => GlitchBlocks(
            seed: controller.seed,
            blocks: 2,
            fragments: 0,
            child: frame(paint: HotlineColors.textPrimary),
          ),
          1 => GlitchBlocks(
            seed: controller.seed + 1,
            blocks: 3,
            fragments: 2,
            child: frame(paint: HotlineColors.textPrimary),
          ),
          // The single colour event of the sequence, so its blocks take no
          // luminance step and drop no fragments: the frame is one flat accent
          // shape, torn.
          2 => GlitchBlocks(
            seed: controller.seed + 2,
            blocks: 3,
            fragments: 0,
            tone: false,
            child: frame(paint: HotlineColors.accent),
          ),
          3 => GlitchBlocks(
            seed: controller.seed + 3,
            blocks: 5,
            fragments: 3,
            child: frame(paint: HotlineColors.textPrimary),
          ),
          // Frame 4 is the clean glyph held for one step, not the return to
          // rest: the flipbook itself ends on the shape.
          _ => child!,
        };
      },
      child: rest,
    );
  }
}
