import 'package:flutter/material.dart';

import 'package:striked/design/components/toolbar_icon_action.dart';
import 'package:striked/design/icons/striked_icons.dart';
import 'package:striked/design/spacing.dart';
import 'package:striked/features/plugins/plugin_management_screen.dart';
import 'package:striked/features/settings/settings_screen.dart';

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
          icon: StrikedIcons.plugins,
          onTap: () => _open(() => openPluginManagement(context)),
        ),
        const SizedBox(width: Spacing.sm),
        ToolbarIconAction(
          label: 'SETTINGS',
          icon: StrikedIcons.settings,
          onTap: () => _open(() => openSettings(context)),
        ),
      ],
    );
  }
}
