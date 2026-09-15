import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/host_repository.dart';
import '../../design/tokens.dart';
import '../../design/components/panel.dart';
import '../../design/spacing.dart';
import '../screen/host_screen.dart';
import '../screen/screen_preview.dart';

/// The last frame a host's screen showed, blurred just enough that the layout
/// reads and the text does not. The whole tile is the way into the screen
/// route; the corner label only says so.
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
                  // Sigma 2 in the stored frame's own pixels: the tile is drawn
                  // at very nearly the width the frame was written at, so the
                  // blur means the same thing on every screen size.
                  imageFilter: ui.ImageFilter.blur(sigmaX: 2, sigmaY: 2),
                  // The bytes, not the path: the writer replaces the file in
                  // place, and an image keyed on a path that never changes
                  // would draw the frame before this one forever.
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
                // On its own ground: the label sits over whatever the frame
                // happens to be, and a light frame swallows muted ink.
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
