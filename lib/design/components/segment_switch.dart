import 'package:flutter/widgets.dart';

import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/design/spacing.dart';

class SegmentSwitch extends StatelessWidget {
  const SegmentSwitch({
    super.key,
    required this.labels,
    required this.currentIndex,
    required this.onSelected,
  });

  final List<String> labels;
  final int currentIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < labels.length; i++)
          Expanded(
            child: _Segment(
              label: labels[i],
              active: i == currentIndex,
              onTap: () => onSelected(i),
            ),
          ),
      ],
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = active ? context.tokens.accent : context.tokens.textMuted;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Column(
        children: [
          SizedBox(
            height: TapTargets.minHeight,
            child: Center(
              child: Text(
                label,
                style: context.tokens.rowKicker.copyWith(color: color),
              ),
            ),
          ),
          Container(
            height: BarSizes.inlineThickness,
            color: active ? context.tokens.accent : const Color(0x00000000),
          ),
        ],
      ),
    );
  }
}
