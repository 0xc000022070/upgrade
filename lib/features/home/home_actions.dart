import 'package:flutter/material.dart';

import '../../design/components/toolbar_icon_action.dart';
import '../../design/icons/dazzle_icons.dart';
import '../../design/spacing.dart';
import '../plugins/plugin_management_screen.dart';
import '../settings/settings_screen.dart';

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
          icon: DazzleIcons.plugins,
          onTap: () => _open(() => openPluginManagement(context)),
        ),
        const SizedBox(width: Spacing.sm),
        ToolbarIconAction(
          label: 'SETTINGS',
          icon: DazzleIcons.settings,
          onTap: () => _open(() => openSettings(context)),
        ),
      ],
    );
  }
}
