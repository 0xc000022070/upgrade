import 'package:flutter/material.dart';

import '../colors.dart';
import '../spacing.dart';
import '../typography.dart';
import 'list_row.dart';

/// One row of a picker: the current value is the solid accent
/// block, everything else is a plain row. Used by the move and pair
/// pickers and by the settings screen, which is why it sits in the design layer
/// and not next to either of them.
class PickerRow extends StatelessWidget {
  const PickerRow({
    super.key,
    required this.label,
    required this.onTap,
    this.value,
    this.subtitle,
    this.indent = false,
    this.selected = false,
    this.dim = false,
  });

  final String label;

  /// A child project's row carries its parent path here,
  /// `INFRA / HOMELAB`, so a flat picker still says where a row sits.
  final String? subtitle;

  final String? value;
  final bool indent;
  final bool selected;

  /// A row whose condition is not met is drawn dim and does
  /// nothing. Dim rows elsewhere use [DazzleColors.textMuted], so this is
  /// the same reading and not a second one.
  final bool dim;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final row = selected
        ? _SelectedRow(label: label, onTap: onTap)
        : ListRow(
            title: label,
            subtitle: subtitle,
            value: value,
            titleColor: dim ? DazzleColors.textMuted : null,
            valueColor: dim ? DazzleColors.textMuted : null,
            onTap: onTap,
          );
    if (!indent) return row;
    return Padding(
      padding: const EdgeInsets.only(left: Spacing.xl),
      child: row,
    );
  }
}

class _SelectedRow extends StatelessWidget {
  const _SelectedRow({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: TapTargets.minHeight),
        margin: const EdgeInsets.symmetric(vertical: Spacing.sm),
        padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          color: DazzleColors.accent,
          borderRadius: BorderRadius.circular(Radii.sharp),
        ),
        child: Row(
          children: [
            Text(
              '// ',
              style: DazzleText.valueStrong.copyWith(
                color: DazzleColors.backgroundPrimary,
              ),
            ),
            Expanded(
              child: Text(
                label,
                style: DazzleText.rowTitle.copyWith(
                  color: DazzleColors.backgroundPrimary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
