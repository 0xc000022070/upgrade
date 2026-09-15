import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/pip.dart';
import '../../design/colors.dart';
import '../../design/components/panel.dart';
import '../../design/icons/dazzle_icons.dart';

/// `PIP` wherever AGENTS has a header: lit while there is live work to park in
/// the corner, dim while there is not, and gone only where there is no window
/// to open at all. The glyph is a window with a tile in its corner, so the
/// word is not the only thing telling it apart from `VIEW ALL`.
class PipAffordance extends ConsumerWidget {
  const PipAffordance({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      switch (ref.watch(pipActionProvider)) {
        PipAction.absent => const SizedBox.shrink(),
        PipAction.quiet => const PanelAffordance(
          'PIP',
          icon: DazzleIcons.pip,
          color: DazzleColors.textDisabled,
        ),
        PipAction.live => PanelAffordance(
          'PIP',
          icon: DazzleIcons.pip,
          onTap: () => ref.read(pipSurfaceProvider).enter(),
        ),
      };
}
