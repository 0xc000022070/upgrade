import 'package:flutter/widgets.dart';

import '../../design/colors.dart';
import '../../design/spacing.dart';
import '../../platform/workspace/workspace_model.dart';
import 'diff_jump.dart';

/// A hunk header with the symbol git found at the front of it.
///
/// Git writes `@@ -a,b +c,d @@ void main()`, which on a phone is a header whose
/// useful half is off the right edge behind coordinates the gutter is already
/// carrying line by line. The two halves are swapped, and a header git found
/// no symbol for is left exactly as it came.
String hunkHeadline(String raw) {
  final cut = raw.indexOf('@@', 2);
  if (cut < 0) return raw;
  final symbol = raw.substring(cut + 2).trim();
  if (symbol.isEmpty) return raw;
  return '$symbol  ${raw.substring(0, cut + 2)}';
}

/// The rows carrying a hunk header, in the order they are drawn.
List<int> hunkRows(List<DiffLine> lines) => [
  for (var at = 0; at < lines.length; at++)
    if (lines[at].kind == DiffLineKind.hunk) at,
];

/// Which hunk a row is inside, as an index into [rows]: the last header at or
/// above it, and null for the rows above the first header.
///
/// A search and not a scan: this is asked again on every frame the pane
/// scrolls, and a file has as many rows as it has lines.
int? hunkAt(List<int> rows, int row) {
  var low = 0;
  var high = rows.length - 1;
  var found = -1;
  while (low <= high) {
    final mid = (low + high) ~/ 2;
    if (rows[mid] <= row) {
      found = mid;
      low = mid + 1;
    } else {
      high = mid - 1;
    }
  }
  return found < 0 ? null : found;
}

/// The hunk header of the hunk being read, held at the top of the pane while
/// its own row is off the screen above.
class HunkPin extends StatelessWidget {
  const HunkPin({
    super.key,
    required this.rows,
    required this.jumps,
    required this.rowHeight,
    required this.rowAt,
  });

  /// The rows carrying a header, from [hunkRows].
  final List<int> rows;

  final DiffJumps jumps;

  /// Every row is this tall, so where a row is, is arithmetic.
  final double rowHeight;

  /// Draws the header for a row. The pane draws its own rows and the pin is
  /// the same row again, so the two can never disagree about how one looks.
  final Widget Function(int row) rowAt;

  void _toTop(int row) => jumps.to(row * rowHeight);

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: jumps.scroll,
    builder: (context, _) {
      if (rows.isEmpty || !jumps.scroll.hasClients) {
        return const SizedBox.shrink();
      }
      final pixels = jumps.scroll.position.pixels;
      final at = hunkAt(rows, (pixels / rowHeight).floor());
      // A header still on the screen speaks for itself. The pin stands in for
      // it only once the top edge has started cutting it.
      if (at == null || rows[at] * rowHeight >= pixels) {
        return const SizedBox.shrink();
      }
      // The header coming up pushes the held one off the top rather than
      // landing on it, so the pane never shows two headers in one place.
      final next = at + 1 < rows.length
          ? rows[at + 1] * rowHeight - pixels
          : double.infinity;
      final push = next < rowHeight ? rowHeight - next : 0.0;
      return ClipRect(
        child: SizedBox(
          height: rowHeight,
          child: Transform.translate(
            offset: Offset(0, -push),
            child: GestureDetector(
              onTap: () => _toTop(rows[at]),
              child: Stack(
                children: [
                  rowAt(rows[at]),
                  // Held and inline, the row is the same row, and the two mean
                  // different things: one says a range begins here, the other
                  // that the reader is deep inside one. The rule is what says
                  // the code goes on underneath.
                  //
                  // At the weight the panels are ruled at it disappears: this
                  // edge lands on whichever ground the line below it has, and
                  // half of those are the diff's own two.
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Container(
                      height: Borders.hairline,
                      color: DazzleColors.textDisabled,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}
