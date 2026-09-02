import 'package:flutter/widgets.dart';

import '../colors.dart';
import '../icons/hotline_icon.dart';
import '../icons/hotline_icons.dart';
import '../spacing.dart';
import '../typography.dart';
import 'signal_text.dart';

/// SPEC.md §38.1. Every section on every screen is one of these: 1px border,
/// 2px radius, a header strip *inside* the frame, and an 8px body. There is no
/// bare section header left in the app — grouping is the border, not whitespace.
///
/// The strip is a filled bar one step over the panel fill, edge to edge, with
/// the rule still under it: the concept image carries it on every panel and is
/// ground truth over the mocks, which dropped the fill.
class Panel extends StatelessWidget {
  const Panel({
    super.key,
    this.child,
    this.title,
    this.affordance,
    this.onHeaderTap,
    this.bodyPadding = const EdgeInsets.all(Spacing.panelPadding),
    this.border = HotlineColors.borderNormal,
  });

  /// A panel with no body is its own row — the STATUS line, a folded DONE.
  final Widget? child;

  /// Omitted only by panels that are their own header — the detail hero card.
  final String? title;

  /// §38.1: the right-hand slot on the header strip — a count, `VIEW ALL >`,
  /// `ALL +`. Same type as the title, so it reads as part of the strip.
  final Widget? affordance;

  /// Makes the whole header strip the affordance's tap target. The strip is
  /// only 27px tall, so widening the text itself would never reach 44.
  final VoidCallback? onHeaderTap;

  /// A body of rows passes zero vertical padding: the rows carry their own, and
  /// doubling it would break the rule spacing between them.
  final EdgeInsets bodyPadding;

  final Color border;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: HotlineColors.surfacePrimary,
        border: Border.all(color: border, width: Borders.hairline),
        borderRadius: BorderRadius.circular(Radii.sharp),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title != null)
            _HeaderStrip(
              title: title!,
              affordance: affordance,
              onTap: onHeaderTap,
              ruled: child != null,
            ),
          if (child != null) Padding(padding: bodyPadding, child: child!),
        ],
      ),
    );
  }
}

class _HeaderStrip extends StatelessWidget {
  const _HeaderStrip({
    required this.title,
    required this.ruled,
    this.affordance,
    this.onTap,
  });

  final String title;
  final Widget? affordance;
  final VoidCallback? onTap;

  /// A header with nothing under it takes the body's padding back so the panel
  /// still reads as a row rather than as a clipped strip.
  final bool ruled;

  @override
  Widget build(BuildContext context) {
    final vertical = ruled ? Spacing.md : Spacing.lg;
    final strip = Padding(
      padding: EdgeInsets.fromLTRB(
        Spacing.panelPadding,
        vertical,
        Spacing.panelPadding,
        ruled ? Spacing.sm + 2 : vertical,
      ),
      child: Row(
        children: [
          Expanded(
            child: SignalText(
              title.toUpperCase(),
              style: HotlineText.panelHeader,
              decodeOnEntry: true,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          ?affordance,
        ],
      ),
    );

    return Container(
      color: HotlineColors.surfaceSecondary,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onTap == null)
            strip
          else
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onTap,
              child: strip,
            ),
          // The rule runs the fill's full width: an inset rule under an edge to
          // edge fill reads as two competing edges.
          if (ruled)
            Container(
              height: Borders.hairline,
              color: HotlineColors.borderNormal,
            ),
        ],
      ),
    );
  }
}

/// The `VIEW ALL >` / `4  VIEW ALL >` / `2  v` form from the mocks: a mono
/// count, an optional word, an optional glyph, always at the strip's right.
class PanelAffordance extends StatelessWidget {
  const PanelAffordance(
    this.label, {
    super.key,
    this.icon = HotlineIcons.forward,
    this.showIcon = true,
    this.color,
    this.onTap,
  });

  final String label;
  final HotlineIcons icon;
  final bool showIcon;
  final Color? color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tint = color ?? HotlineColors.textMuted;
    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: HotlineText.panelHeader.copyWith(color: tint)),
        if (showIcon) ...[
          const SizedBox(width: Spacing.sm),
          HotlineIcon(icon, size: IconSizes.affordance, color: tint),
        ],
      ],
    );
    if (onTap == null) return content;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: content,
    );
  }
}

/// §38.1: panels stack with an 8px gap and nothing else.
class PanelStack extends StatelessWidget {
  const PanelStack({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(height: Spacing.panelGap),
          children[i],
        ],
      ],
    );
  }
}

/// A panel whose body is a list of rows: the rows own their vertical padding,
/// so the panel gives them horizontal padding only.
const panelRowsPadding = EdgeInsets.symmetric(horizontal: Spacing.panelPadding);
