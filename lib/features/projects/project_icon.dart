import 'package:flutter/widgets.dart';

import 'package:striked/data/project_icons.dart';
import 'package:striked/design/spacing.dart';
import 'package:striked/design/tokens.dart';

class ProjectIcon extends StatelessWidget {
  const ProjectIcon(
    this.icon, {
    super.key,
    this.size = IconSizes.lg,
    this.color,
  });

  final ProjectIconKind icon;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final paint = color ?? context.tokens.textSecondary;
    // Read the white artwork as a mask; alpha alone also tints black edge residue.
    return ColorFiltered(
      colorFilter: ColorFilter.matrix([
        0,
        0,
        0,
        0,
        paint.r * 255,
        0,
        0,
        0,
        0,
        paint.g * 255,
        0,
        0,
        0,
        0,
        paint.b * 255,
        0.2126 * paint.a,
        0.7152 * paint.a,
        0.0722 * paint.a,
        paint.a,
        -255 * paint.a,
      ]),
      child: Image.asset(
        icon.asset,
        width: size,
        height: size,
        filterQuality: FilterQuality.medium,
        excludeFromSemantics: true,
      ),
    );
  }
}
