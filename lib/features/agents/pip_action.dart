import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:striked/application/pip.dart';
import 'package:striked/design/tokens.dart';
import 'package:striked/design/components/panel.dart';
import 'package:striked/design/icons/striked_icons.dart';

class PipAffordance extends ConsumerWidget {
  const PipAffordance({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      switch (ref.watch(pipActionProvider)) {
        PipAction.absent => const SizedBox.shrink(),
        PipAction.quiet => PanelAffordance(
          'PIP',
          icon: StrikedIcons.pip,
          color: context.tokens.textDisabled,
        ),
        PipAction.live => PanelAffordance(
          'PIP',
          icon: StrikedIcons.pip,
          onTap: () => ref.read(pipSurfaceProvider).enter(),
        ),
      };
}
