import 'package:flutter/widgets.dart';

import 'package:striked/data/enums.dart';
import 'package:striked/design/tokens.dart';
import 'package:striked/design/spacing.dart';

class StatusTag extends StatelessWidget {
  const StatusTag(this.label, {super.key, required Color this.color})
    : projectStatus = null;

  const StatusTag.project(ProjectStatus status, {super.key})
    : label = null,
      color = null,
      projectStatus = status;

  final String? label;
  final Color? color;
  final ProjectStatus? projectStatus;

  static Color _projectColor(StrikedTokens tokens, ProjectStatus status) =>
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
