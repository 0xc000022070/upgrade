import 'package:flutter/widgets.dart';

import '../../data/enums.dart';
import '../tokens.dart';
import '../spacing.dart';

/// Bordered, never filled: status is information, not a coloured surface
/// (accent stays sparse).
class StatusTag extends StatelessWidget {
  const StatusTag(this.label, {super.key, required Color this.color})
    : projectStatus = null;

  const StatusTag.project(ProjectStatus status, {super.key})
    : label = null,
      color = null,
      projectStatus = status;

  /// Set directly, or null when built from [projectStatus] — resolved
  /// against the live tokens in [build].
  final String? label;
  final Color? color;
  final ProjectStatus? projectStatus;

  static Color _projectColor(DazzleTokens tokens, ProjectStatus status) =>
      switch (status) {
        ProjectStatus.active => tokens.accent,
        ProjectStatus.paused => tokens.textSecondary,
        ProjectStatus.archived => tokens.textDisabled,
      };

  @override
  Widget build(BuildContext context) {
    final status = projectStatus;
    final label = this.label ?? status!.name.toUpperCase();
    final color = this.color ?? _projectColor(context.tokens, status!);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.sm, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: color, width: Borders.hairline),
        borderRadius: BorderRadius.circular(Radii.sharp),
      ),
      child: Text(label, style: context.tokens.label.copyWith(color: color)),
    );
  }
}
