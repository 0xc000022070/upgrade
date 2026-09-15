import 'package:flutter/material.dart';

import '../../design/colors.dart';
import '../../design/icons/dazzle_icon.dart';
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
        _HomeAction(
          label: 'MANAGE PLUGINS',
          icon: DazzleIcons.plugins,
          onTap: () => _open(() => openPluginManagement(context)),
        ),
        const SizedBox(width: Spacing.sm),
        _HomeAction(
          label: 'SETTINGS',
          icon: DazzleIcons.settings,
          onTap: () => _open(() => openSettings(context)),
        ),
      ],
    );
  }
}

class _HomeAction extends StatefulWidget {
  const _HomeAction({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final DazzleIcons icon;
  final VoidCallback onTap;

  @override
  State<_HomeAction> createState() => _HomeActionState();
}

class _HomeActionState extends State<_HomeAction> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final color = _down ? DazzleColors.accent : DazzleColors.textSecondary;
    return Tooltip(
      message: widget.label,
      child: Semantics(
        button: true,
        label: widget.label,
        onTap: widget.onTap,
        excludeSemantics: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _down = true),
          onTapCancel: () => setState(() => _down = false),
          onTapUp: (_) => setState(() => _down = false),
          onTap: widget.onTap,
          child: SizedBox.square(
            dimension: 48,
            child: Center(
              child: DazzleIcon(
                widget.icon,
                size: IconSizes.toolbar,
                color: color,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
