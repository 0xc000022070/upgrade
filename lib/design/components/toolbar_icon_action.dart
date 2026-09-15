import 'package:flutter/material.dart';

import '../colors.dart';
import '../icons/dazzle_icon.dart';
import '../icons/dazzle_icons.dart';
import '../spacing.dart';

class ToolbarIconAction extends StatefulWidget {
  const ToolbarIconAction({
    super.key,
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final DazzleIcons icon;
  final VoidCallback onTap;

  @override
  State<ToolbarIconAction> createState() => _ToolbarIconActionState();
}

class _ToolbarIconActionState extends State<ToolbarIconAction> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final color = _down ? DazzleColors.accent : DazzleColors.textSecondary;
    return Tooltip(
      message: widget.label,
      child: Semantics(
        container: true,
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
