import 'package:flutter/widgets.dart';

import '../colors.dart';
import '../motion.dart';

/// A 2px rule that fills. No rounded caps, no gradient, no percentage baked in
/// — the number is metadata and lives next to the bar, not inside it.
class ProgressBar extends StatelessWidget {
  const ProgressBar({
    super.key,
    required this.value,
    this.head,
    this.headSize = 8,
    this.thickness = 2,
  });

  /// 0..1. A goal with no tasks is 0, never indeterminate.
  final double value;

  /// A diamond marker is reserved for the fill edge; passing it in
  /// keeps the bar itself free of animation state.
  final Widget? head;
  final double headSize;

  /// Secondary goals draw a 1px rule so the main goal's 2px bar stays the one
  /// the eye lands on.
  final double thickness;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return TweenAnimationBuilder<double>(
          tween: Tween(end: value.clamp(0.0, 1.0)),
          duration: Motion.normal,
          curve: Motion.transition,
          builder: (context, animated, child) {
            final width = constraints.maxWidth * animated;
            return SizedBox(
              height: head == null ? thickness : headSize,
              child: Stack(
                alignment: Alignment.centerLeft,
                clipBehavior: Clip.none,
                children: [
                  Container(
                    height: thickness,
                    color: HotlineColors.borderNormal,
                  ),
                  Container(
                    height: thickness,
                    width: width,
                    color: HotlineColors.accent,
                  ),
                  if (head != null)
                    Positioned(
                      left: width - headSize / 2,
                      child: SizedBox.square(dimension: headSize, child: head),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
