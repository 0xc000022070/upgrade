import 'package:flutter/widgets.dart';

import '../tokens.dart';
import 'signal_text.dart';

/// The mono value column — counts, percentages, timestamps.
class Meta extends StatelessWidget {
  const Meta(
    this.text, {
    super.key,
    this.strong = false,
    this.color,
    this.maxLines = 1,
    this.align,
  });

  final String text;
  final bool strong;
  final Color? color;
  final int maxLines;
  final TextAlign? align;

  @override
  Widget build(BuildContext context) {
    final base = strong ? context.tokens.valueStrong : context.tokens.value;
    return SignalText(
      text,
      style: color == null ? base : base.copyWith(color: color),
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
      textAlign: align,
    );
  }
}
