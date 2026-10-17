import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:striked/data/repositories/host_repository.dart';
import 'package:striked/design/tokens.dart';
import 'package:striked/design/components/panel.dart';
import 'package:striked/design/spacing.dart';
import 'package:striked/features/screen/host_screen.dart';
import 'package:striked/features/screen/screen_preview.dart';

class ScreenPreviewTile extends ConsumerWidget {
  const ScreenPreviewTile({super.key, required this.host});

  final Host host;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preview = ref.watch(screenPreviewProvider(host.id)).valueOrNull;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => openHostScreen(context, host),
      child: AspectRatio(
        aspectRatio: preview?.aspect ?? 16 / 9,
        child: ColoredBox(
          color: context.tokens.backgroundPrimary,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (preview != null)
                ImageFiltered(
                  // Sigma 2 in the stored frame's own pixels: the tile is drawn at very nearly the width
                  // the frame was written at.
                  imageFilter: ui.ImageFilter.blur(sigmaX: 2, sigmaY: 2),
                  // The bytes, not the path: the writer replaces the file in place, and an image keyed on
                  // a path that never changes would draw the frame before this one forever.
                  child: Image.memory(
                    preview.bytes,
                    fit: BoxFit.cover,
                    filterQuality: FilterQuality.low,
                    gaplessPlayback: true,
                  ),
                )
              else
                Center(
                  child: Text(
                    'NO FRAME YET',
                    style: context.tokens.value.copyWith(fontSize: 11),
                  ),
                ),
              Positioned(
                right: Spacing.sm,
                bottom: Spacing.sm,
                child: ColoredBox(
                  color: context.tokens.backgroundPrimary,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: Spacing.sm,
                      vertical: Spacing.xs,
                    ),
                    child: const PanelAffordance('SCREEN'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
