import 'package:flutter/widgets.dart';

import 'package:striked/design/tokens.dart';
import 'package:striked/design/motion.dart';

class ProgressBar extends StatelessWidget {
  const ProgressBar({
    super.key,
    required this.value,
    this.head,
    this.headSize = 8,
    this.thickness = 2,
  });

  final double value;

  final Widget? head;
  final double headSize;

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
                    color: context.tokens.borderNormal,
                  ),
                  Container(
                    height: thickness,
                    width: width,
                    color: context.tokens.accent,
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
