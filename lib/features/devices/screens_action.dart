import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/agents/agents.dart';
import 'package:upgrade/design/components/toolbar_icon_action.dart';
import 'package:upgrade/design/icons/upgrade_icons.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/features/devices/device_dock.dart';

class ScreensAction extends ConsumerWidget {
  const ScreensAction({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dock = ref.watch(deviceDockProvider);
    final hosts = ref.watch(screenHostsProvider);
    return ListenableBuilder(
      listenable: dock,
      builder: (context, _) {
        if (!dock.holding && (hosts?.isEmpty ?? true)) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.only(right: Spacing.sm),
          child: ToolbarIconAction(
            key: const ValueKey('screens-action'),
            label: 'SCREENS',
            icon: UpgradeIcons.screens,
            onTap: dock.ask,
          ),
        );
      },
    );
  }
}
