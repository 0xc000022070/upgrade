import 'package:flutter/widgets.dart';

import '../../design/typography.dart';

/// The mark on a row that has been handed to an agent.
///
/// A word rather than a glyph: there is no icon that reads as "a machine is
/// holding this", and the trailing edge already carries mono values, so the
/// smallest tracked label sits there without inventing a shape.
class SentTag extends StatelessWidget {
  const SentTag({super.key});

  @override
  Widget build(BuildContext context) =>
      const Text('SENT', style: DazzleText.label);
}
