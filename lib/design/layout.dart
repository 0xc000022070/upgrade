import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// faraday's inner display is near square, and a line of mono
/// text run the full width of it stops being readable long before the layout
/// breaks. Past [columnMax] the content stops widening and centres instead.
///
/// The breakpoint and the cap are deliberately the same number: a 600 cap under
/// 600dp of width is already a no-op, so the narrow case needs no branch of its
/// own and cannot drift away from the wide one.
abstract final class Layout {
  static const columnMax = 600.0;

  /// The margin that centres a [columnMax] column inside [width]. Zero below
  /// the cap, so a phone keeps exactly the padding its caller asked for.
  static double gutterFor(double width) => math.max(0, (width - columnMax) / 2);
}

/// Caps and centres [child] without ever changing the shape of the tree: the
/// box is present at every width and only its constraint moves.
///
/// This is the whole reason a resize keeps what the user was holding. A
/// wrapper that
/// is inserted above 600dp and removed below it changes the element tree on the
/// resize, and every [State] under it — the capture field's controller, an open
/// sheet's mode — is discarded and rebuilt. An unconditional box cannot do
/// that, because a fold changes numbers and not widgets.
class ContentColumn extends StatelessWidget {
  const ContentColumn({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Align(
      // Horizontally this fills and centres; vertically it must not. An
      // [Align] offered a bounded height takes all of it, which turned the nav
      // bar into a full-screen box with two tabs in the middle of it. The
      // factor makes the height the child's own and leaves the width alone.
      heightFactor: 1,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: Layout.columnMax),
        child: child,
      ),
    );
  }
}
