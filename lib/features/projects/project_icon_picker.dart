import 'package:flutter/material.dart';

import 'package:upgrade/data/project_icons.dart';
import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/design/components/panel_sheet.dart';
import 'package:upgrade/design/components/picker_row.dart';
import 'package:upgrade/design/icons/upgrade_icon.dart';
import 'package:upgrade/design/icons/upgrade_icons.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/features/projects/project_icon.dart';

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
    bodyPadding: panelRowsPadding,
    child: PickerRow(
      label: ProjectIconKind.fromId(value)?.label.toUpperCase() ?? 'NO ICON',
      value: 'CHANGE',
      onTap: () => showPanelSheet<void>(
        context,
        title: 'PROJECT ICON',
        builder: (context) => PanelSheetBody(
          title: 'PROJECT ICON',
          children: [_choices(context)],
        ),
      ),
    ),
  );

  Widget _choices(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => Wrap(
      spacing: Spacing.md,
      runSpacing: Spacing.md,
      children: [
        for (final icon in <ProjectIconKind?>[null, ...ProjectIconKind.values])
          SizedBox(
            width: (constraints.maxWidth - Spacing.md * 2) / 3,
            child: _Choice(
              icon: icon,
              selected: ProjectIconKind.fromId(value) == icon,
              onTap: () {
                onChanged(icon?.name);
                Navigator.of(context).pop();
              },
            ),
          ),
      ],
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
              UpgradeIcon(
                UpgradeIcons.close,
                size: IconSizes.hero,
                color: color,
              ),
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
