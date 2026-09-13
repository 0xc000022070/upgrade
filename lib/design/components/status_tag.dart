import 'package:flutter/widgets.dart';

import '../../data/enums.dart';
import '../colors.dart';
import '../spacing.dart';
import '../typography.dart';

/// Bordered, never filled: status is information, not a coloured surface
/// (accent stays sparse).
class StatusTag extends StatelessWidget {
  const StatusTag(this.label, {super.key, required this.color});

  StatusTag.project(ProjectStatus status, {super.key})
    : label = status.name.toUpperCase(),
      color = _projectColors[status]!;

  final String label;
  final Color color;

  static const _projectColors = {
    ProjectStatus.active: DazzleColors.accent,
    ProjectStatus.paused: DazzleColors.textSecondary,
    ProjectStatus.archived: DazzleColors.textDisabled,
  };

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.sm, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: color, width: Borders.hairline),
        borderRadius: BorderRadius.circular(Radii.sharp),
      ),
      child: Text(label, style: DazzleText.label.copyWith(color: color)),
    );
  }
}
