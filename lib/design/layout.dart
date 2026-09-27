import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// The breakpoint and the cap are deliberately the same number: a 600 cap under 600dp of
/// width is already a no-op, so the narrow case needs no branch of its own.
abstract final class Layout {
  static const columnMax = 600.0;

  static double gutterFor(double width, {double maxWidth = columnMax}) =>
      math.max(0, (width - maxWidth) / 2);
}

/// Unconditional at every width, only the constraint moves. A wrapper inserted above
/// 600dp and removed below changes the element tree on the resize, and every [State]
/// under it is discarded and rebuilt.
class ContentColumn extends StatelessWidget {
  const ContentColumn({
    super.key,
    required this.child,
    this.maxWidth = Layout.columnMax,
  });

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return Align(
      // An [Align] offered a bounded height takes all of it; the factor makes the height the
      // child's own and leaves the width alone.
      heightFactor: 1,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}
