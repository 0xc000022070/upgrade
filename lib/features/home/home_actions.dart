import 'package:flutter/material.dart';

import 'package:upgrade/design/components/anchor_menu.dart';
import 'package:upgrade/design/components/toolbar_icon_action.dart';
import 'package:upgrade/design/icons/upgrade_icons.dart';
import 'package:upgrade/features/plugins/plugin_management_screen.dart';
import 'package:upgrade/features/settings/settings_screen.dart';

class HomeActions extends StatefulWidget {
  const HomeActions({super.key, this.beforeOpen, this.entries = const []});

  final VoidCallback? beforeOpen;
  final List<MenuEntry> entries;

  @override
  State<HomeActions> createState() => _HomeActionsState();
}

class _HomeActionsState extends State<HomeActions> {
  bool _open = false;

  void _push(VoidCallback action) {
    widget.beforeOpen?.call();
    action();
  }

  Future<void> _menu(BuildContext anchor) async {
    setState(() => _open = true);
    await showAnchorMenu(
      anchor,
      title: 'MORE',
      entries: [
        ...widget.entries,
        MenuEntry(
          'MANAGE PLUGINS',
          UpgradeIcons.plugins,
          () => _push(() => openPluginManagement(context)),
        ),
        MenuEntry(
          'SETTINGS',
          UpgradeIcons.settings,
          () => _push(() => openSettings(context)),
        ),
      ],
    );
    if (mounted) setState(() => _open = false);
  }

  @override
  Widget build(BuildContext context) => Builder(
    builder: (anchor) => ToolbarIconAction(
      label: 'MORE',
      icon: UpgradeIcons.more,
      lit: _open,
      onTap: () => _menu(anchor),
    ),
  );
}
