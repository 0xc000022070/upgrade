import 'package:flutter/material.dart';

import '../tokens.dart';
import '../spacing.dart';
import 'list_row.dart';

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

  final String? subtitle;

  final String? value;
  final bool indent;
  final bool selected;

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
            titleColor: dim ? context.tokens.textMuted : null,
            valueColor: dim ? context.tokens.textMuted : null,
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
          color: context.tokens.accent,
          borderRadius: BorderRadius.circular(Radii.sharp),
        ),
        child: Row(
          children: [
            Text(
              '// ',
              style: context.tokens.valueStrong.copyWith(
                color: context.tokens.backgroundPrimary,
              ),
            ),
            Expanded(
              child: Text(
                label,
                style: context.tokens.rowTitle.copyWith(
                  color: context.tokens.backgroundPrimary,
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
