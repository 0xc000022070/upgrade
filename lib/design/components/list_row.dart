import 'package:flutter/widgets.dart';

import '../tokens.dart';
import '../icons/dazzle_icon.dart';
import '../icons/dazzle_icons.dart';
import '../spacing.dart';
import 'item_line.dart';
import 'path_line.dart';
import 'progress_bar.dart';
import 'signal_text.dart';

class ListRow extends StatelessWidget {
  const ListRow({
    super.key,
    required this.title,
    this.literalTitle = false,
    this.kicker,
    this.subtitle,
    this.caption,
    this.leading,
    this.leadingWidth = IconSizes.glyph,
    this.value,
    this.valueSpans,
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
    this.mark,
    this.subtitleColor,
    this.decode = false,
  }) : assert(value == null || valueSpans == null, 'one value column');

  final String? kicker;

  final String title;

  final bool literalTitle;

  final String? subtitle;

  final String? caption;

  final Widget? leading;

  final double leadingWidth;

  final String? value;

  final List<TextSpan>? valueSpans;
  final Color? valueColor;
  final bool valueStrong;

  final double? progress;

  final bool node;

  final Widget? trailing;

  final VoidCallback? onTap;

  final VoidCallback? onLongPress;

  /// An overlay rather than a wrapper around [leading], because a hit outside the 14px
  /// glyph slot never reaches a child of it. 40 is wider than the 26px gutter, so the
  /// target does take the first two characters of the title with it.
  final VoidCallback? onLeadingTap;

  final bool lead;

  final Color? titleColor;

  /// Its own column outside the title, so the numerals line up down the panel however
  /// long the titles are.
  final Widget? mark;

  final Color? subtitleColor;
  final bool decode;

  @override
  Widget build(BuildContext context) {
    final base = lead ? context.tokens.rowTitleLead : context.tokens.rowTitle;
    final titleStyle = titleColor == null
        ? base
        : base.copyWith(color: titleColor);

    // The glyph sits on the title's line, not on the row's centre.
    final indent = leading == null ? 0.0 : leadingWidth + Spacing.lg;
    final titleLine =
        MediaQuery.textScalerOf(context).scale(titleStyle.fontSize!) *
        titleStyle.height!;
    final line = itemLine(title);

    Widget indented(Widget child) => Padding(
      padding: EdgeInsets.only(left: indent),
      child: child,
    );

    final lines = <Widget>[
      if (kicker != null)
        indented(
          Text(
            kicker!,
            style: context.tokens.rowKicker,
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
              // As tall as the title's line is drawn, not as designed: held at the one, the glyph
              // rose off the letters the moment the reader asked for a larger text size.
              height: titleLine,
              child: Center(child: leading),
            ),
            const SizedBox(width: Spacing.lg),
          ],
          Expanded(
            child: literalTitle
                ? PathLine(title, style: titleStyle, decode: decode)
                : SignalText(
                    line.text,
                    style: titleStyle,
                    decodeOnEntry: decode,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
          ),
          if (!literalTitle && line.more > 0)
            SizedBox(
              height: titleLine,
              child: Center(child: LineCount(line.more)),
            ),
        ],
      ),
      if (subtitle != null)
        indented(
          Text(
            subtitle!,
            style: subtitleColor == null
                ? context.tokens.rowSubtitle
                : context.tokens.rowSubtitle.copyWith(color: subtitleColor),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      if (caption != null)
        indented(
          Text(
            caption!,
            style: context.tokens.label,
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
            if (mark != null) ...[const SizedBox(width: Spacing.lg), mark!],
            if (progress != null) ...[
              const SizedBox(width: Spacing.lg),
              SizedBox(
                width: BarSizes.inlineWidth,
                child: ProgressBar(value: progress!),
              ),
            ],
            if (value != null || valueSpans != null) ...[
              const SizedBox(width: Spacing.lg),
              Text.rich(
                valueSpans == null
                    ? TextSpan(text: value)
                    : TextSpan(children: valueSpans),
                textAlign: TextAlign.right,
                style:
                    (valueStrong
                            ? context.tokens.valueStrong
                            : context.tokens.value)
                        .copyWith(color: valueColor),
              ),
            ],
            if (node) ...[
              const SizedBox(width: Spacing.md),
              DazzleIcon(
                DazzleIcons.progressMarker,
                size: IconSizes.glyph,
                color: context.tokens.textDisabled,
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
          // Last child, so it is hit-tested first and its recognizer enters the arena before the
          // row's.
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

class ListRowGroup extends StatelessWidget {
  const ListRowGroup({super.key, required this.children, this.ruled = true});

  final List<Widget> children;

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
              color: context.tokens.borderSubtle,
            ),
          children[i],
        ],
      ],
    );
  }
}
