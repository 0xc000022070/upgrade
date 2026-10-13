import 'package:flutter/material.dart';

import 'package:upgrade/design/components/toolbar_icon_action.dart';
import 'package:upgrade/design/icons/upgrade_icons.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/features/plugins/plugin_management_screen.dart';
import 'package:upgrade/features/settings/settings_screen.dart';

class HomeActions extends StatelessWidget {
  const HomeActions({super.key, this.beforeOpen});

  final VoidCallback? beforeOpen;

  void _open(VoidCallback action) {
    beforeOpen?.call();
    action();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ToolbarIconAction(
          label: 'MANAGE PLUGINS',
          icon: UpgradeIcons.plugins,
          onTap: () => _open(() => openPluginManagement(context)),
        ),
        const SizedBox(width: Spacing.sm),
        ToolbarIconAction(
          label: 'SETTINGS',
          icon: UpgradeIcons.settings,
          onTap: () => _open(() => openSettings(context)),
        ),
      ],
    );
  }
}
