import 'package:flutter/widgets.dart';

import '../tokens.dart';
import '../spacing.dart';

class CellDivider extends StatelessWidget {
  const CellDivider({super.key});

  @override
  Widget build(BuildContext context) =>
      Container(width: Borders.hairline, color: context.tokens.borderSubtle);
}
