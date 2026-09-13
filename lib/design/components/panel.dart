import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../colors.dart';
import '../effects/glitch.dart';
import '../icons/dazzle_icon.dart';
import '../icons/dazzle_icons.dart';
import '../spacing.dart';
import '../typography.dart';
import 'path_line.dart';
import 'signal_text.dart';

/// Every section on every screen is one of these: 1px border,
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
    this.literalTitle = false,
    this.leading,
    this.affordance,
    this.onHeaderTap,
    this.onHeaderLongPress,
    this.bodyPadding = const EdgeInsets.all(Spacing.panelPadding),
    this.bodyFlexible = false,
    this.border = DazzleColors.borderNormal,
    this.headerGlitch,
  });

  /// A panel with no body is its own row — the STATUS line, a folded DONE.
  final Widget? child;

  /// Omitted only by panels that are their own header — the detail hero card.
  final String? title;

  /// The title is a name this app did not choose — a path, a sha — so it is
  /// drawn in the case it has and given up from the left rather than from the
  /// end, which is the half that identifies it. Set here rather than guessed
  /// from the string: a title with a slash in it is not necessarily one of
  /// these, and one of these is not necessarily too long to matter.
  final bool literalTitle;

  /// The `x` at the left of the header strip when a panel is in
  /// selection mode. Nothing else uses it: a strip's left is its title.
  final Widget? leading;

  /// The right-hand slot on the header strip — a count, `VIEW ALL >`,
  /// `ALL +`. Same type as the title, so it reads as part of the strip.
  final Widget? affordance;

  /// Makes the whole header strip the affordance's tap target. The strip grew
  /// to a row's height, but a strip carries at most one of these and the
  /// affordance beside it keeps its own.
  final VoidCallback? onHeaderTap;

  /// The drop quick view hangs its delete off the breadcrumb strip, the
  /// only chrome a drop's sheet has left once its state blocks are gone.
  final VoidCallback? onHeaderLongPress;

  /// A body of rows passes zero vertical padding: the rows carry their own, and
  /// doubling it would break the rule spacing between them.
  final EdgeInsets bodyPadding;

  /// A scrolling body has to be allowed to shrink: a [SingleChildScrollView]
  /// laid out by a [Column] is given unbounded height, sizes to its content
  /// and overflows the panel instead of scrolling inside it. Only a
  /// sheet needs this — every panel on a screen is as tall as its rows.
  final bool bodyFlexible;

  final Color border;

  /// A capture filed from a pushed route has no nav icon to
  /// land on, so the panel it lands in says so itself. A header strip carries
  /// no glyph — its title is the only mark on it — so the tear takes
  /// the strip, which is the smallest thing here that can stand for the panel.
  final GlitchController? headerGlitch;

  @override
  Widget build(BuildContext context) {
    final glitch = headerGlitch;
    return Container(
      decoration: BoxDecoration(
        color: DazzleColors.surfacePrimary,
        border: Border.all(color: border, width: Borders.hairline),
        borderRadius: BorderRadius.circular(Radii.sharp),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title != null)
            if (glitch == null)
              _HeaderStrip(
                title: title!,
                literalTitle: literalTitle,
                leading: leading,
                affordance: affordance,
                onTap: onHeaderTap,
                onLongPress: onHeaderLongPress,
                ruled: child != null,
              )
            else
              GlitchPanel(
                controller: glitch,
                child: _HeaderStrip(
                  title: title!,
                  literalTitle: literalTitle,
                  leading: leading,
                  affordance: affordance,
                  onTap: onHeaderTap,
                  onLongPress: onHeaderLongPress,
                  ruled: child != null,
                ),
              ),
          if (child != null)
            if (bodyFlexible)
              Flexible(
                child: Padding(padding: bodyPadding, child: child!),
              )
            else
              Padding(padding: bodyPadding, child: child!),
        ],
      ),
    );
  }
}

class _HeaderStrip extends StatelessWidget {
  const _HeaderStrip({
    required this.title,
    required this.literalTitle,
    required this.ruled,
    this.leading,
    this.affordance,
    this.onTap,
    this.onLongPress,
  });

  final String title;
  final bool literalTitle;
  final Widget? leading;
  final Widget? affordance;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// A header with nothing under it takes the body's padding back so the panel
  /// still reads as a row rather than as a clipped strip.
  final bool ruled;

  @override
  Widget build(BuildContext context) {
    // The strip is a row's height, 27px before, so a text action on it
    // has 36 to be hit with. Two consequences for the layout below. The
    // vertical padding rides on the title instead of the whole strip, or the
    // Row would be 28 tall inside a 36 strip and an affordance could never
    // fill it; the horizontal padding is a pair of siblings for the same
    // reason, since a Padding around the Row puts the panel's own margin out
    // of the last action's reach. Nothing moves: the numbers are the same.
    final vertical = ruled ? Spacing.sm : Spacing.lg;
    final strip = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: RowMetrics.minHeight),
      child: Row(
        children: [
          const SizedBox(width: Spacing.panelPadding),
          if (leading != null) ...[leading!, const SizedBox(width: Spacing.md)],
          Expanded(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: vertical),
              child: literalTitle
                  ? PathLine(
                      title,
                      style: DazzleText.panelHeader,
                      decode: true,
                    )
                  : SignalText(
                      title.toUpperCase(),
                      style: DazzleText.panelHeader,
                      decodeOnEntry: true,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
            ),
          ),
          // The title is handed the strip's slack, so a strip shrunk to the
          // width of its own words has none left to hold the affordance off
          // the title. The gap is a sibling the title cannot take.
          if (affordance != null) ...[
            const SizedBox(width: Spacing.md),
            affordance!,
          ],
          const SizedBox(width: Spacing.panelPadding),
        ],
      ),
    );

    return Container(
      color: DazzleColors.surfaceSecondary,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onTap == null && onLongPress == null)
            strip
          else
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onTap,
              onLongPress: onLongPress,
              child: strip,
            ),
          // The rule runs the fill's full width: an inset rule under an edge to
          // edge fill reads as two competing edges.
          if (ruled)
            Container(
              height: Borders.hairline,
              color: DazzleColors.borderNormal,
            ),
        ],
      ),
    );
  }
}

/// The `VIEW ALL >` / `4  VIEW ALL >` / `2  v` form from the mocks: a mono
/// count, an optional word, an optional glyph, always at the strip's right.
///
/// With an [onTap] it is a button, and the hit box is the row's full
/// height by at least [TapTargets.minHeight] wide — see [TapExpansion] for
/// why that box is not laid out. Without one it is a readout: no press, no
/// expansion, nothing to miss.
class PanelAffordance extends StatefulWidget {
  const PanelAffordance(
    this.label, {
    super.key,
    this.icon = DazzleIcons.forward,
    this.showIcon = true,
    this.color,
    this.onTap,
  });

  final String label;
  final DazzleIcons icon;
  final bool showIcon;
  final Color? color;
  final VoidCallback? onTap;

  @override
  State<PanelAffordance> createState() => _PanelAffordanceState();
}

class _PanelAffordanceState extends State<PanelAffordance> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final onTap = widget.onTap;
    // The press is the one the verbs paint: accent for as long as the
    // finger is down, and the resting ink back the moment it lifts.
    final tint = _down
        ? DazzleColors.accent
        : widget.color ?? DazzleColors.textMuted;
    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          widget.label,
          style: DazzleText.panelHeader.copyWith(color: tint),
        ),
        if (widget.showIcon) ...[
          const SizedBox(width: Spacing.sm),
          DazzleIcon(widget.icon, size: IconSizes.affordance, color: tint),
        ],
      ],
    );
    if (onTap == null) return content;
    return TapExpansion(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _down = true),
        onTapCancel: () => setState(() => _down = false),
        onTapUp: (_) => setState(() => _down = false),
        onTap: onTap,
        child: content,
      ),
    );
  }
}

/// A hit box for a label that must not move: the box lays out at its
/// child's size and only the hit test grows — the row's full height by the
/// label plus [Spacing.md] each side, never under [TapTargets.minHeight] wide.
///
/// "The label does not move, the padding eats into the gap between
/// neighbouring actions". A [Padding] cannot do that — it takes its space out
/// of the row and pushes the label off the panel's right margin — and the
/// callers' `SizedBox(width: Spacing.lg)` between two actions is not this
/// side's to remove. So the box lays out at the label's size, and only the hit
/// test grows: a tap inside the expanded rect is forwarded to the child's
/// centre, the way Material's own `_InputPadding` forwards one.
///
/// Where two expanded actions share a `Spacing.lg` gap their rects overlap by
/// 2px each side of the midpoint. A [Row] hit-tests its children back to
/// front, so the right-hand action owns the overlap; both are hit everywhere
/// their own label is.
///
/// What this cannot give is a wider semantics node: the node is the tappable
/// child's, and the child is the size of its label. A finger gets the box, a
/// screen reader is still offered the words. Growing that too means growing
/// the layout, which is the thing this exists to avoid.
class TapExpansion extends SingleChildRenderObjectWidget {
  const TapExpansion({super.key, required super.child});

  @override
  RenderProxyBox createRenderObject(BuildContext context) =>
      _RenderTapExpansion();
}

class _RenderTapExpansion extends RenderProxyBox {
  Rect get _hitRect {
    // The row's real height when a parent bounds it — the breadcrumb line is a
    // fixed 44 — and the row token when it does not: a header strip's Row
    // hands its children an unbounded cross axis, and 36 is what it measures.
    // Clamped to a row either way: a bounded parent can be the height of the
    // whole screen (a panel inside an [Expanded]), and a tap target that tall
    // is a bug waiting on nothing but a shallower ancestor to expose it.
    final rowHeight = constraints.maxHeight.isFinite
        ? constraints.maxHeight.clamp(
            RowMetrics.minHeight,
            TapTargets.minHeight,
          )
        : RowMetrics.minHeight;
    final dx = math.max(Spacing.md, (TapTargets.minHeight - size.width) / 2);
    final dy = math.max(0.0, (rowHeight - size.height) / 2);
    return Rect.fromLTRB(-dx, -dy, size.width + dx, size.height + dy);
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (super.hitTest(result, position: position)) return true;
    final target = child;
    if (target == null || !_hitRect.contains(position)) return false;
    final centre = size.center(Offset.zero);
    return result.addWithRawTransform(
      transform: MatrixUtils.forceToPoint(centre),
      position: centre,
      hitTest: (result, position) => target.hitTest(result, position: centre),
    );
  }
}

/// Panels stack with an 8px gap and nothing else.
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
