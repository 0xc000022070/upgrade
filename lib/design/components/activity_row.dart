import 'package:flutter/widgets.dart';

import '../../data/views.dart';
import '../spacing.dart';
import '../typography.dart';

/// One line of the audit stream. The mocks set RECENT tighter
/// than a list: no glyph, no rule, no tap — what changed on the left, where it
/// happened and how long ago on the right.
class ActivityRow extends StatelessWidget {
  const ActivityRow({super.key, required this.entry, required this.timeLabel});

  final ActivityEntry entry;
  final String timeLabel;

  @override
  Widget build(BuildContext context) {
    final where = entry.context ?? entry.label.toUpperCase();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: RowMetrics.streamPadding),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Expanded(
            child: Text(
              entry.detail == null
                  ? entry.title
                  : '${entry.title}   ${entry.detail}',
              style: HotlineText.value.copyWith(
                color: HotlineText.rowTitle.color,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: Spacing.lg),
          Text('${where.toUpperCase()}  $timeLabel', style: HotlineText.label),
        ],
      ),
    );
  }
}
