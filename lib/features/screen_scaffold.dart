import 'package:flutter/widgets.dart';

import '../design/colors.dart';
import '../design/components/panel.dart';
import '../design/components/signal_text.dart';
import '../design/layout.dart';
import '../design/spacing.dart';
import '../design/typography.dart';

/// Geometry from the mocks: a breadcrumb line, the title with
/// its `_` cursor, a rule across the content width, then the panel stack.
///
/// A detail screen has no chevron — the mocks drop it and the breadcrumb takes
/// the tap instead, which keeps the title's full width for the project's name.
class ScreenScaffold extends StatelessWidget {
  const ScreenScaffold({
    super.key,
    this.title,
    required this.children,
    this.breadcrumb = '/ PERSONAL CONTROL PLANE',
    this.breadcrumbSegments,
    this.breadcrumbTrailing,
    this.titleTrailing,
    this.onBack,
    this.header,
    this.padding = const EdgeInsets.fromLTRB(
      Spacing.screenEdge,
      Spacing.lg,
      Spacing.screenEdge,
      Spacing.xxl,
    ),
  });

  /// Home has no `TODAY_`: the AGENTS panel is the first thing
  /// on the screen and a title over it would only name the day. Every other
  /// screen keeps one, so this is null on exactly one screen.
  final String? title;
  final String breadcrumb;

  /// A path whose segments are individually tappable, each
  /// popping the stack back to what it names. When set it replaces
  /// [breadcrumb]; screens with a fixed path keep passing the string.
  final List<CrumbSegment>? breadcrumbSegments;

  /// The detail screen's `EDIT` sits here. The breadcrumb line is the
  /// only row above the title, and a screen-level verb belongs beside the path
  /// it acts on rather than beside the name it would compete with.
  final Widget? breadcrumbTrailing;

  final List<Widget> children;

  /// A small mono control on the title's right, only when it does
  /// something. Nothing renders here otherwise.
  final Widget? titleTrailing;

  final VoidCallback? onBack;

  /// Rendered above the panel stack — the detail hero card, which is a panel
  /// but not a section.
  final Widget? header;

  final EdgeInsets padding;

  /// The crumb never wraps (orchestrator ruling, 2026-09-02), so on a line that
  /// also carries a verb the path has to give up width rather than take a
  /// second line. It gives up the root segment: `/ PERSONAL CONTROL PLANE /
  /// PROJECTS` becomes `/ PROJECTS`, which is the half that says where you are.
  /// A screen with nothing trailing keeps the full path.
  static String crumbFor(String breadcrumb, {required bool hasTrailing}) {
    final segments = breadcrumb
        .split('/')
        .map((segment) => segment.trim())
        .where((segment) => segment.isNotEmpty)
        .toList();
    if (segments.isEmpty) return breadcrumb;
    // Never down to nothing: a one-segment path is already as short as it goes.
    if (hasTrailing && segments.length > 1) segments.removeAt(0);
    return '/ ${segments.join(' / ')}';
  }

  @override
  Widget build(BuildContext context) {
    final segments = breadcrumbSegments;
    final trailing = breadcrumbTrailing;
    Widget crumb = segments == null
        ? Text(
            crumbFor(breadcrumb, hasTrailing: trailing != null),
            style: HotlineText.breadcrumb,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          )
        : _SegmentedCrumb(segments: segments);
    // A crumb line that carries a tap target is at least a row tall,
    // and the back tap takes that whole height rather than the 13px the path
    // paints. A line with nothing to hit on it keeps the compact spacing —
    // there is nothing on it to miss.
    final interactive = onBack != null || segments != null || trailing != null;
    final crumbHeight = trailing == null
        ? RowMetrics.minHeight
        : TapTargets.minHeight;
    // Tight from the [Expanded] down through the [Align], so the back tap is
    // the whole cell rather than the width and height of the path's glyphs.
    Widget crumbCell = Align(alignment: Alignment.centerLeft, child: crumb);
    if (segments == null && onBack != null) {
      crumbCell = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onBack,
        child: crumbCell,
      );
    }

    // The stack scrolls under the system gesture area on any screen that pins
    // nothing over it — the form screens end on a commit block, and that block
    // was landing on the pill. Zero wherever a bar below already spent the
    // inset, so no screen that had it right gains a gap.
    final systemBottom = MediaQuery.paddingOf(context).bottom;

    return SafeArea(
      bottom: false,
      child: LayoutBuilder(
        builder: (context, constraints) => ListView(
          // The column is centred by widening the scroll view's
          // padding, not by narrowing the scroll view. A capped ListView would
          // leave the margins dead to a drag, and on a near-square display the
          // margins are a third of the screen.
          padding:
              padding +
              EdgeInsets.only(bottom: systemBottom) +
              EdgeInsets.symmetric(
                horizontal: Layout.gutterFor(constraints.maxWidth),
              ),
          children: [
            if (!interactive) ...[
              crumb,
              const SizedBox(height: Spacing.sm),
            ] else
              // The row takes a tap target's height so the trailing verb is
              // hittable without a 13px control floating in the margin; the
              // gap under it is given back, so the header keeps its rhythm.
              SizedBox(
                height: crumbHeight,
                child: Row(
                  children: [
                    // Expanded and not Flexible-plus-Spacer: the collapse
                    // rule is about the width left beside the verbs, and two
                    // flex children would have split that width in half before
                    // the path was ever measured against it.
                    Expanded(child: crumbCell),
                    ?trailing,
                  ],
                ),
              ),
            if (title != null)
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // The cursor rides with the title inside its own Row: a
                  // Spacer as a direct sibling would claim half the width and
                  // ellipsize a project's name long before it had to.
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: SignalText(
                            title!,
                            style: HotlineText.screenTitle,
                            decodeOnEntry: true,
                            smearOnEntry: true,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const Text('_', style: HotlineText.screenTitle),
                      ],
                    ),
                  ),
                  ?titleTrailing,
                ],
              ),
            const SizedBox(height: Spacing.md),
            Container(
              height: Borders.hairline,
              color: HotlineColors.borderNormal,
            ),
            const SizedBox(height: Spacing.lg),
            ?header,
            ...children,
          ],
        ),
      ),
    );
  }
}

/// One hop of a [ScreenScaffold.breadcrumbSegments] path.
class CrumbSegment {
  const CrumbSegment(this.label, {this.onTap});

  final String label;
  final VoidCallback? onTap;
}

/// The path never wraps, so when it does not fit beside the
/// trailing verbs the leading segments collapse to a single `…` and the
/// immediate parent always stays.
///
/// The number of segments to drop is measured rather than guessed: laid out as
/// a plain [Row] the overflow would be silent in release and a yellow bar in
/// debug, and ellipsizing the row's last child would eat the one segment the
/// rule says to keep.
class _SegmentedCrumb extends StatelessWidget {
  const _SegmentedCrumb({required this.segments});

  final List<CrumbSegment> segments;

  static const _style = HotlineText.breadcrumb;
  static const _separator = ' / ';
  static const _elision = '…';

  @override
  Widget build(BuildContext context) {
    if (segments.isEmpty) return const SizedBox.shrink();
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);

    double widthOf(String text) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: _style),
        textDirection: direction,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final width = painter.width;
      painter.dispose();
      return width;
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        var dropped = 0;
        // Never past the immediate parent: `/ … / HOMELAB` is the floor, and a
        // name too long even for that ellipsizes on its own below.
        while (dropped < segments.length - 1 &&
            widthOf(_textFor(dropped)) > constraints.maxWidth) {
          dropped++;
        }
        // Below the floor even `/ … / PARENT` does not fit, and the row's
        // fixed `/ ` and `… / ` would overflow rather than clip. One
        // ellipsizing line cannot: it gives up the per-segment taps at a width
        // where there is no segment left to hit anyway.
        if (widthOf(_textFor(dropped)) > constraints.maxWidth) {
          return Text(
            _textFor(dropped),
            style: _style,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          );
        }
        final kept = segments.sublist(dropped);
        // A tappable segment is a text-only action like any other, so
        // it takes the crumb row's whole height. The Row is the ceiling — a
        // child never takes a hit its parent has already rejected — so it is
        // given the line's height rather than the 13px the path paints. The
        // labels stay where they were: the [Align] centred them in this height
        // before, and the Row's own centre does it now.
        final line = constraints.maxHeight.isFinite
            ? constraints.maxHeight.clamp(
                RowMetrics.minHeight,
                TapTargets.minHeight,
              )
            : null;
        return SizedBox(
          height: line,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // The punctuation is decoration and a [Text] answers a
              // hit, so a separator left pointing would swallow the tap a
              // segment's box reaches into it for.
              const IgnorePointer(child: Text('/ ', style: _style)),
              if (dropped > 0)
                const IgnorePointer(
                  child: Text('$_elision$_separator', style: _style),
                ),
              for (var i = 0; i < kept.length; i++) ...[
                if (i > 0)
                  const IgnorePointer(child: Text(_separator, style: _style)),
                // Only the last segment flexes. A Flexible child is capped at its
                // equal share of the free space, so making every segment one gave
                // `INFRA PERSONAL` a third of a row it fitted in whole and
                // ellipsized it with slack still to its right. One flex child
                // takes the whole remainder, and it is the immediate parent that
                // absorbs a measurement that came up a pixel short.
                if (i == kept.length - 1)
                  Flexible(
                    fit: FlexFit.loose,
                    child: _Segment(segment: kept[i]),
                  )
                else
                  _Segment(segment: kept[i]),
              ],
            ],
          ),
        );
      },
    );
  }

  String _textFor(int dropped) {
    final kept = segments.sublist(dropped).map((s) => s.label);
    final prefix = dropped > 0 ? '$_elision$_separator' : '';
    return '/ $prefix${kept.join(_separator)}';
  }
}

class _Segment extends StatefulWidget {
  const _Segment({required this.segment});

  final CrumbSegment segment;

  @override
  State<_Segment> createState() => _SegmentState();
}

class _SegmentState extends State<_Segment> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final onTap = widget.segment.onTap;
    // The press, the same one the verbs and the affordances paint. The
    // last segment is the screen the user is on and has no [onTap]: it is the
    // end of a path, not a control, and it is not painted as one.
    final style = _down
        ? _SegmentedCrumb._style.copyWith(color: HotlineColors.accent)
        : _SegmentedCrumb._style;
    final text = Text(
      widget.segment.label,
      style: style,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    if (onTap == null) return text;
    return TapExpansion(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _down = true),
        onTapCancel: () => setState(() => _down = false),
        onTapUp: (_) => setState(() => _down = false),
        onTap: onTap,
        child: text,
      ),
    );
  }
}
