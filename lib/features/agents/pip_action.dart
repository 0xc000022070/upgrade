import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/pip.dart';
import '../../design/tokens.dart';
import '../../design/components/panel.dart';
import '../../design/icons/dazzle_icons.dart';

class PipAffordance extends ConsumerWidget {
  const PipAffordance({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      switch (ref.watch(pipActionProvider)) {
        PipAction.absent => const SizedBox.shrink(),
        PipAction.quiet => PanelAffordance(
          'PIP',
          icon: DazzleIcons.pip,
          color: context.tokens.textDisabled,
        ),
        PipAction.live => PanelAffordance(
          'PIP',
          icon: DazzleIcons.pip,
          onTap: () => ref.read(pipSurfaceProvider).enter(),
        ),
      };
}
