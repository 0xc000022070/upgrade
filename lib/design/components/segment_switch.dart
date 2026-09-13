import 'package:flutter/widgets.dart';

import '../colors.dart';
import '../spacing.dart';
import '../typography.dart';

/// Two or more cells that pick which of a screen's lists is drawn, sitting
/// under the screen title and over the panel stack.
///
/// The active cell is marked the way the nav bar marks the active tab: a rule
/// of [BarSizes.inlineThickness] across the whole cell, in the accent, with the
/// inactive cells carrying a transparent one so nothing shifts when the pick
/// moves. Active means one thing in this app, and this does not invent a
/// second.
///
/// The pick is the caller's state. Nothing here is persisted: a screen that
/// remembers which list it was on across a cold start is answering a question
/// the user did not ask.
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
    final color = active ? DazzleColors.accent : DazzleColors.textMuted;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Column(
        children: [
          // The whole cell is the hit, not the word: a two-cell row across a
          // phone gives each half more than enough width, and a target the
          // size of the text would be the smallest one on the screen.
          SizedBox(
            height: TapTargets.minHeight,
            child: Center(
              child: Text(
                label,
                style: DazzleText.rowKicker.copyWith(color: color),
              ),
            ),
          ),
          Container(
            height: BarSizes.inlineThickness,
            color: active ? DazzleColors.accent : const Color(0x00000000),
          ),
        ],
      ),
    );
  }
}
