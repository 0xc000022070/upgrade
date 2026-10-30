import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/pip.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/design/icons/upgrade_icons.dart';

class PipAffordance extends ConsumerWidget {
  const PipAffordance({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      switch (ref.watch(pipActionProvider)) {
        PipAction.absent => const SizedBox.shrink(),
        PipAction.quiet => PanelAffordance(
          'PIP',
          icon: UpgradeIcons.pip,
          color: context.tokens.textDisabled,
        ),
        PipAction.live => PanelAffordance(
          'PIP',
          icon: UpgradeIcons.pip,
          onTap: () => ref.read(pipSurfaceProvider).enter(),
        ),
      };
}
