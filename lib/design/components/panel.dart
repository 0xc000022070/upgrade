import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../tokens.dart';
import '../effects/glitch.dart';
import '../icons/dazzle_icon.dart';
import '../icons/dazzle_icons.dart';
import '../spacing.dart';
import 'path_line.dart';
import 'signal_text.dart';

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
    this.onHeaderFlick,
    this.bodyPadding = const EdgeInsets.all(Spacing.panelPadding),
    this.bodyFlexible = false,
    this.border,
    this.headerGlitch,
  });

  final Widget? child;

  final String? title;

  final bool literalTitle;

  final Widget? leading;

  final Widget? affordance;

  final VoidCallback? onHeaderTap;

  final VoidCallback? onHeaderLongPress;

  final void Function(int step)? onHeaderFlick;

  final EdgeInsets bodyPadding;

  /// A [SingleChildScrollView] laid out by a [Column] is given unbounded height, sizes to
  /// its content and overflows the panel instead of scrolling inside it.
  final bool bodyFlexible;

  final Color? border;

  final GlitchController? headerGlitch;

  @override
  Widget build(BuildContext context) {
    final glitch = headerGlitch;
    final border = this.border ?? context.tokens.borderNormal;
    return Container(
      decoration: BoxDecoration(
        color: context.tokens.surfacePrimary,
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
                onFlick: onHeaderFlick,
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
                  onFlick: onHeaderFlick,
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
    this.onFlick,
  });

  final String title;
  final bool literalTitle;
  final Widget? leading;
  final Widget? affordance;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final void Function(int step)? onFlick;

  final bool ruled;

  @override
  Widget build(BuildContext context) {
    // The vertical padding rides on the title rather than the strip, or the Row would be 28
    // tall inside a 36 strip and an affordance could never fill it; the horizontal padding
    // is a pair of siblings, since a Padding around the Row puts the panel's own margin out
    // of the last action's reach.
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
                      style: context.tokens.panelHeader,
                      decode: true,
                    )
                  : SignalText(
                      title.toUpperCase(),
                      style: context.tokens.panelHeader,
                      decodeOnEntry: true,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
            ),
          ),
          // The gap is a sibling the title cannot take: the title is handed the strip's slack.
          if (affordance != null) ...[
            const SizedBox(width: Spacing.md),
            affordance!,
          ],
          const SizedBox(width: Spacing.panelPadding),
        ],
      ),
    );

    return Container(
      color: context.tokens.surfaceSecondary,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onTap == null && onLongPress == null && onFlick == null)
            strip
          else
            _StripGestures(
              onTap: onTap,
              onLongPress: onLongPress,
              onFlick: onFlick,
              child: strip,
            ),
          if (ruled)
            Container(
              height: Borders.hairline,
              color: context.tokens.borderNormal,
            ),
        ],
      ),
    );
  }
}

/// One detector for the three: split apart they take separate arena entries, and the
/// drag never cancels the tap sitting under it.
class _StripGestures extends StatefulWidget {
  const _StripGestures({
    required this.child,
    this.onTap,
    this.onLongPress,
    this.onFlick,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final void Function(int step)? onFlick;

  @override
  State<_StripGestures> createState() => _StripGesturesState();
}

class _StripGesturesState extends State<_StripGestures> {
  double _travel = 0;

  @override
  Widget build(BuildContext context) {
    final flick = widget.onFlick;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      dragStartBehavior: DragStartBehavior.down,
      onVerticalDragStart: flick == null ? null : (_) => _travel = 0,
      onVerticalDragUpdate: flick == null
          ? null
          : (details) => _travel += details.delta.dy,
      onVerticalDragEnd: flick == null
          ? null
          : (_) {
              if (_travel.abs() < Gestures.flick) return;
              flick(_travel > 0 ? 1 : -1);
            },
      child: widget.child,
    );
  }
}

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
    final tint = _down
        ? context.tokens.accent
        : widget.color ?? context.tokens.textMuted;
    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          widget.label,
          style: context.tokens.panelHeader.copyWith(color: tint),
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

/// A hit box for a label that must not move: the box lays out at its child's size and
/// only the hit test grows, the way Material's own `_InputPadding` forwards one. Where
/// two expanded actions share a gap their rects overlap; a [Row] hit-tests back to front,
/// so the right-hand one owns the overlap. The semantics node stays the label's size.
class TapExpansion extends SingleChildRenderObjectWidget {
  const TapExpansion({super.key, required super.child});

  @override
  RenderProxyBox createRenderObject(BuildContext context) =>
      _RenderTapExpansion();
}

class _RenderTapExpansion extends RenderProxyBox {
  Rect get _hitRect {
    // The row's real height when a parent bounds it, the row token when it does not: a
    // header strip's Row hands its children an unbounded cross axis. Clamped either way,
    // since a bounded parent can be the height of the whole screen.
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

const panelRowsPadding = EdgeInsets.symmetric(horizontal: Spacing.panelPadding);
