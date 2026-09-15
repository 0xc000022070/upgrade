import 'package:flutter/widgets.dart';

import '../tokens.dart';
import '../spacing.dart';

/// The rule between two cells of a bar. One widget rather than one per bar:
/// every strip in the app that puts cells side by side draws the same line
/// between them, and a strip is not the place to decide how wide it is.
class CellDivider extends StatelessWidget {
  const CellDivider({super.key});

  @override
  Widget build(BuildContext context) =>
      Container(width: Borders.hairline, color: context.tokens.borderSubtle);
}
