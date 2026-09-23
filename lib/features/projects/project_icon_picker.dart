import 'package:flutter/material.dart';

import '../../data/project_icons.dart';
import '../../design/components/panel.dart';
import '../../design/icons/dazzle_icon.dart';
import '../../design/icons/dazzle_icons.dart';
import '../../design/spacing.dart';
import '../../design/tokens.dart';
import 'project_icon.dart';

class ProjectIconPicker extends StatelessWidget {
  const ProjectIconPicker({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final String? value;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) => Panel(
    title: 'PROJECT ICON',
    child: LayoutBuilder(
      builder: (context, constraints) => Wrap(
        spacing: Spacing.md,
        runSpacing: Spacing.md,
        children: [
          for (final icon in <ProjectIconKind?>[
            null,
            ...ProjectIconKind.values,
          ])
            SizedBox(
              width: (constraints.maxWidth - Spacing.md * 2) / 3,
              child: _Choice(
                icon: icon,
                selected: ProjectIconKind.fromId(value) == icon,
                onTap: () => onChanged(icon?.name),
              ),
            ),
        ],
      ),
    ),
  );
}

class _Choice extends StatelessWidget {
  const _Choice({
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final ProjectIconKind? icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final color = selected ? tokens.accent : tokens.textSecondary;
    return Semantics(
      label: icon?.label,
      selected: selected,
      child: TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(
          foregroundColor: color,
          minimumSize: const Size(88, 80),
          padding: const EdgeInsets.all(Spacing.md),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.sharp),
            side: BorderSide(
              color: selected ? tokens.accent : tokens.borderSubtle,
            ),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon case final icon?)
              ProjectIcon(icon, size: IconSizes.hero, color: color)
            else
              DazzleIcon(DazzleIcons.close, size: IconSizes.hero, color: color),
            if (icon == null) ...[
              const SizedBox(height: Spacing.sm),
              Text('NO ICON', style: tokens.label.copyWith(color: color)),
            ],
          ],
        ),
      ),
    );
  }
}
