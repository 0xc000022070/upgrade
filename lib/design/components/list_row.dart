import 'package:flutter/widgets.dart';

import '../colors.dart';
import '../icons/spectacle_icon.dart';
import '../icons/spectacle_icons.dart';
import '../spacing.dart';
import '../typography.dart';
import 'progress_bar.dart';
import 'signal_text.dart';

/// Three columns and nothing else: a 14px glyph on the left when
/// the row is actionable, a mono line stack in the middle, and one right-hand
/// column carrying a short inline bar and a value.
///
/// The height is the content's, not a fixed step: the mocks land a one-line row
/// near 40, a two-line row near 57 and a three-line row near 70, which is what
/// a constant 12px of vertical padding and a 4px line gap produce.
class ListRow extends StatelessWidget {
  const ListRow({
    super.key,
    required this.title,
    this.kicker,
    this.subtitle,
    this.caption,
    this.leading,
    this.leadingWidth = IconSizes.glyph,
    this.value,
    this.valueColor,
    this.valueStrong = false,
    this.progress,
    this.node = false,
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.onLeadingTap,
    this.lead = false,
    this.titleColor,
    this.subtitleColor,
    this.decode = false,
  });

  /// The uppercase line above the title — the project a row belongs to.
  final String? kicker;

  final String title;

  /// Second line. On a blocked row this is the reason, in warning.
  final String? subtitle;

  /// Third line, always muted: the context a row came from.
  final String? caption;

  /// The 14px glyph slot. A row with no action leaves it empty and the text
  /// starts at the panel's padding.
  final Widget? leading;

  /// The selection checkbox is a mono `[ ]`, which needs 24 rather than
  /// the 14 a glyph takes. The slot widens; the gutter after it does not, so
  /// every other row on the screen keeps its left edge.
  final double leadingWidth;

  /// Percent, duration, time or count. One column, right-aligned.
  final String? value;
  final Color? valueColor;
  final bool valueStrong;

  /// 0..1. Draws the 56x2 inline bar immediately left of [value].
  final double? progress;

  /// The diamond that marks a row as opening something.
  final bool node;

  /// Escape hatch for a row whose right edge is a control rather than a value.
  final Widget? trailing;

  final VoidCallback? onTap;

  /// No trailing `...`: the sheet is a long press, so a row keeps
  /// its right column for data.
  ///
  /// It is also the way into selection mode on a drop row. It carries no
  /// argument: the mode is the panel's, and the row only says which one was
  /// held.
  final VoidCallback? onLongPress;

  /// The checkbox glyph toggles done without opening the quick view,
  /// with a 40px target. It is an overlay rather than a wrapper around
  /// [leading], because a hit outside the 14px glyph slot never reaches a
  /// child of it. 40 is wider than the 26px gutter, so the target does take
  /// the first two characters of the title with it — the alternative is a
  /// 14px target, which the spec rules out.
  final VoidCallback? onLeadingTap;

  /// The one row a screen is built around gets a 13px title instead of 12.
  final bool lead;

  final Color? titleColor;
  final Color? subtitleColor;
  final bool decode;

  @override
  Widget build(BuildContext context) {
    final base = lead ? SpectacleText.rowTitleLead : SpectacleText.rowTitle;
    final titleStyle = titleColor == null
        ? base
        : base.copyWith(color: titleColor);

    // The glyph sits on the title's line, not on the row's centre: a three
    // line row would otherwise park it next to the reason. Every other line
    // indents past the slot so the whole stack keeps one left edge.
    final indent = leading == null ? 0.0 : leadingWidth + Spacing.lg;

    Widget indented(Widget child) => Padding(
      padding: EdgeInsets.only(left: indent),
      child: child,
    );

    final lines = <Widget>[
      if (kicker != null)
        indented(
          Text(
            kicker!.toUpperCase(),
            style: SpectacleText.rowKicker,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (leading != null) ...[
            SizedBox(
              width: leadingWidth,
              height: titleStyle.fontSize! * titleStyle.height!,
              child: Center(child: leading),
            ),
            const SizedBox(width: Spacing.lg),
          ],
          Expanded(
            child: SignalText(
              title,
              style: titleStyle,
              decodeOnEntry: decode,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      if (subtitle != null)
        indented(
          Text(
            subtitle!,
            style: subtitleColor == null
                ? SpectacleText.rowSubtitle
                : SpectacleText.rowSubtitle.copyWith(color: subtitleColor),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      if (caption != null)
        indented(
          Text(
            caption!,
            style: SpectacleText.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
    ];

    final content = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: RowMetrics.minHeight),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: RowMetrics.padding),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < lines.length; i++) ...[
                    if (i > 0) const SizedBox(height: RowMetrics.lineGap),
                    lines[i],
                  ],
                ],
              ),
            ),
            if (progress != null) ...[
              const SizedBox(width: Spacing.lg),
              SizedBox(
                width: BarSizes.inlineWidth,
                child: ProgressBar(value: progress!),
              ),
            ],
            if (value != null) ...[
              const SizedBox(width: Spacing.lg),
              Text(
                value!,
                textAlign: TextAlign.right,
                style:
                    (valueStrong
                            ? SpectacleText.valueStrong
                            : SpectacleText.value)
                        .copyWith(color: valueColor),
              ),
            ],
            if (node) ...[
              const SizedBox(width: Spacing.md),
              const SpectacleIcon(
                SpectacleIcons.progressMarker,
                size: IconSizes.glyph,
                color: SpectacleColors.textDisabled,
              ),
            ],
            if (trailing != null) ...[
              const SizedBox(width: Spacing.sm),
              trailing!,
            ],
          ],
        ),
      ),
    );

    Widget body = content;
    if (onLeadingTap != null) {
      body = Stack(
        children: [
          content,
          // Last child, so it is hit-tested first and its recognizer enters
          // the arena before the row's — the inner tap wins.
          Positioned(
            left: 0,
            top: 0,
            width: TapTargets.checkbox,
            height: TapTargets.checkbox,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onLeadingTap,
            ),
          ),
        ],
      );
    }

    if (onTap == null && onLongPress == null) return body;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPress: onLongPress,
      child: body,
    );
  }
}

/// Rows inside a panel are separated by a 1px rule that runs the full
/// inner width, the way a table rules its lines.
class ListRowGroup extends StatelessWidget {
  const ListRowGroup({super.key, required this.children, this.ruled = true});

  final List<Widget> children;

  /// HOME's PROJECTS panel stacks its rows unruled: each row is already three
  /// lines tall, and a rule between them turns the panel into a grid.
  final bool ruled;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0 && ruled)
            Container(
              height: Borders.hairline,
              color: SpectacleColors.borderSubtle,
            ),
          children[i],
        ],
      ],
    );
  }
}
