import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../colors.dart';
import '../effects/glitch.dart';
import '../spacing.dart';
import 'upgrade_icons.dart';

class UpgradeIcon extends StatelessWidget {
  const UpgradeIcon(
    this.icon, {
    super.key,
    this.size = IconSizes.lg,
    this.color = UpgradeColors.textSecondary,
    this.signal = false,
    this.glitch,
    this.steps = iconGlitchSteps,
  });

  final UpgradeIcons icon;
  final double size;
  final Color color;

  final bool signal;

  final GlitchController? glitch;

  final List<GlitchStep> steps;

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
      steps: steps,
      frame: ({required Color paint}) => _svg(asSignal: signal, paint: paint),
    );
  }
}

const glitchIcons = [
  UpgradeIcons.home,
  UpgradeIcons.projects,
  UpgradeIcons.hosts,
  UpgradeIcons.checkboxChecked,
  UpgradeIcons.checkboxEmpty,
  UpgradeIcons.submit,
  UpgradeIcons.phone,
  UpgradeIcons.voice,
];

/// flutter_svg keys its cache on the asset/colour pair, so the first play of a sequence
/// decodes entries it has never seen and renders nothing until each one lands. Not
/// awaited by `main()`: it gates nothing.
Future<void> warmGlitchIcons() {
  const paints = [UpgradeColors.textPrimary, UpgradeColors.accent];
  return Future.wait([
    for (final icon in glitchIcons)
      for (final paint in paints)
        SvgAssetLoader(
          icon.asset,
          theme: SvgTheme(currentColor: paint),
        ).loadBytes(null),
  ]);
}

@immutable
class GlitchStep {
  const GlitchStep({
    required this.blocks,
    this.fragments = 0,
    this.accent = false,
    this.coverage = glitchCoverage,
    this.reach = 1,
  });

  final int blocks;
  final int fragments;

  final bool accent;

  final double coverage;
  final double reach;
}

// The block set grows across the sequence rather than decaying, and the last frame is
// the clean glyph: the flipbook ends on the shape it corrupted.
const iconGlitchSteps = [
  GlitchStep(blocks: 2),
  GlitchStep(blocks: 3, fragments: 2),
  GlitchStep(blocks: 3, accent: true),
  GlitchStep(blocks: 5, fragments: 3),
];

const tearGlitchSteps = [
  GlitchStep(blocks: 4, fragments: 2, coverage: 0.5, reach: 2),
  GlitchStep(blocks: 6, fragments: 3, coverage: 0.5, reach: 2),
  GlitchStep(blocks: 5, accent: true, coverage: 0.5, reach: 2),
  GlitchStep(blocks: 7, fragments: 3, coverage: 0.5, reach: 2),
  GlitchStep(blocks: 6, fragments: 2, coverage: 0.5, reach: 2),
  GlitchStep(blocks: 5, accent: true, coverage: 0.5, reach: 2),
  GlitchStep(blocks: 8, fragments: 3, coverage: 0.5, reach: 2),
];

class GlitchedIcon extends StatelessWidget {
  const GlitchedIcon({
    super.key,
    required this.controller,
    required this.rest,
    required this.frame,
    this.steps = iconGlitchSteps,
  });

  final GlitchController controller;

  final Widget rest;
  final Widget Function({required Color paint}) frame;
  final List<GlitchStep> steps;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        final index = controller.frame;
        if (index < 0 || index >= steps.length) return child!;
        final step = steps[index];
        return GlitchBlocks(
          seed: controller.seed + index,
          blocks: step.blocks,
          fragments: step.fragments,
          tone: !step.accent,
          coverage: step.coverage,
          reach: step.reach,
          child: frame(
            paint: step.accent
                ? UpgradeColors.accent
                : UpgradeColors.textPrimary,
          ),
        );
      },
      child: rest,
    );
  }
}
