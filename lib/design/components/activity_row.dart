import 'package:flutter/widgets.dart';

import 'package:upgrade/data/views.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/design/components/item_line.dart';

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
                  ? itemLine(entry.title).text
                  : '${itemLine(entry.title).text}   '
                        '${itemLine(entry.detail!).text}',
              style: context.tokens.value.copyWith(
                color: context.tokens.rowTitle.color,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: Spacing.lg),
          Text(
            '${where.toUpperCase()}  $timeLabel',
            style: context.tokens.label,
          ),
        ],
      ),
    );
  }
}
