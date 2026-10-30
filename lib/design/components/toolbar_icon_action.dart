import 'package:flutter/material.dart';

import 'package:striked/design/tokens.dart';
import 'package:striked/design/icons/striked_icon.dart';
import 'package:striked/design/icons/striked_icons.dart';
import 'package:striked/design/spacing.dart';

class ToolbarIconAction extends StatefulWidget {
  const ToolbarIconAction({
    super.key,
    required this.label,
    required this.icon,
    required this.onTap,
    this.lit = false,
  });

  final String label;
  final StrikedIcons icon;
  final VoidCallback onTap;

  final bool lit;

  @override
  State<ToolbarIconAction> createState() => _ToolbarIconActionState();
}

class _ToolbarIconActionState extends State<ToolbarIconAction> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final on = _down || widget.lit;
    final color = on ? context.tokens.accent : context.tokens.textSecondary;
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
              child: Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: context.tokens.surfacePrimary,
                  border: Border.all(
                    color: on ? color : context.tokens.borderNormal,
                    width: Borders.hairline,
                  ),
                ),
                child: StrikedIcon(
                  widget.icon,
                  size: IconSizes.toolbar,
                  color: color,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
