import 'package:flutter/widgets.dart';

import '../spacing.dart';
import '../tokens.dart';
import 'meta.dart';

class MetaRow extends StatelessWidget {
  const MetaRow(this.label, this.value, {super.key, this.maxLines = 1});

  final String label;
  final String value;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 108, child: Text(label, style: context.tokens.label)),
          Expanded(child: Meta(value, maxLines: maxLines)),
        ],
      ),
    );
  }
}
