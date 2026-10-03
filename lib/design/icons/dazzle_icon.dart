import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../colors.dart';
import '../effects/glitch.dart';
import '../spacing.dart';
import 'dazzle_icons.dart';

class DazzleIcon extends StatelessWidget {
  const DazzleIcon(
    this.icon, {
    super.key,
    this.size = IconSizes.lg,
    this.color = DazzleColors.textSecondary,
    this.signal = false,
    this.glitch,
  });

  final DazzleIcons icon;
  final double size;
  final Color color;

  final bool signal;

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
    return GlitchedIcon(
      controller: controller,
      rest: rest,
      frame: ({required Color paint}) => _svg(asSignal: signal, paint: paint),
    );
  }
}

const glitchIcons = [
  DazzleIcons.home,
  DazzleIcons.projects,
  DazzleIcons.hosts,
  DazzleIcons.checkboxChecked,
  DazzleIcons.checkboxEmpty,
  DazzleIcons.submit,
  DazzleIcons.device,
];

/// flutter_svg keys its cache on the asset/colour pair, so the first play of a sequence
/// decodes entries it has never seen and renders nothing until each one lands. Not
/// awaited by `main()`: it gates nothing.
Future<void> warmGlitchIcons() {
  const paints = [DazzleColors.textPrimary, DazzleColors.accent];
  return Future.wait([
    for (final icon in glitchIcons)
      for (final paint in paints)
        SvgAssetLoader(
          icon.asset,
          theme: SvgTheme(currentColor: paint),
        ).loadBytes(null),
  ]);
}

class GlitchedIcon extends StatelessWidget {
  const GlitchedIcon({
    super.key,
    required this.controller,
    required this.rest,
    required this.frame,
  });

  final GlitchController controller;

  final Widget rest;
  final Widget Function({required Color paint}) frame;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        // The block set grows across the sequence rather than decaying, and the last frame is
        // the clean glyph: the flipbook ends on the shape it corrupted.
        return switch (controller.frame) {
          0 => GlitchBlocks(
            seed: controller.seed,
            blocks: 2,
            fragments: 0,
            child: frame(paint: DazzleColors.textPrimary),
          ),
          1 => GlitchBlocks(
            seed: controller.seed + 1,
            blocks: 3,
            fragments: 2,
            child: frame(paint: DazzleColors.textPrimary),
          ),
          2 => GlitchBlocks(
            seed: controller.seed + 2,
            blocks: 3,
            fragments: 0,
            tone: false,
            child: frame(paint: DazzleColors.accent),
          ),
          3 => GlitchBlocks(
            seed: controller.seed + 3,
            blocks: 5,
            fragments: 3,
            child: frame(paint: DazzleColors.textPrimary),
          ),
          _ => child!,
        };
      },
      child: rest,
    );
  }
}
