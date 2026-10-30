import 'package:flutter/widgets.dart';

import 'package:striked/design/tokens.dart';
import 'package:striked/design/components/panel.dart';
import 'package:striked/design/components/path_line.dart';
import 'package:striked/design/components/signal_text.dart';
import 'package:striked/design/layout.dart';
import 'package:striked/design/spacing.dart';

class ScreenScaffold extends StatelessWidget {
  const ScreenScaffold({
    super.key,
    this.title,
    required this.children,
    this.breadcrumb = '/ PERSONAL CONTROL PLANE',
    this.breadcrumbSegments,
    this.breadcrumbWidget,
    this.breadcrumbTrailing,
    this.titleTrailing,
    this.onBack,
    this.header,
    this.maxContentWidth = Layout.columnMax,
    this.fill = false,
    this.padding = const EdgeInsets.fromLTRB(
      Spacing.screenEdge,
      Spacing.lg,
      Spacing.screenEdge,
      Spacing.xxl,
    ),
  });

  /// Null on exactly one screen: home, where the first panel is already the subject and a
  /// title over it would only name the day.
  final String? title;
  final String breadcrumb;

  /// Replaces [breadcrumb] when set.
  final List<CrumbSegment>? breadcrumbSegments;

  final Widget? breadcrumbWidget;

  final Widget? breadcrumbTrailing;

  final List<Widget> children;

  final Widget? titleTrailing;

  final VoidCallback? onBack;

  final Widget? header;
  final double maxContentWidth;

  final bool fill;

  final EdgeInsets padding;

  /// The crumb never wraps, so on a line that also carries a verb the path gives up its
  /// root segment rather than a second line.
  static String crumbFor(String breadcrumb, {required bool hasTrailing}) {
    final segments = breadcrumb
        .split('/')
        .map((segment) => segment.trim())
        .where((segment) => segment.isNotEmpty)
        .toList();
    if (segments.isEmpty) return breadcrumb;
    // A one-segment path is already as short as it goes.
    if (hasTrailing && segments.length > 1) segments.removeAt(0);
    return '/ ${segments.join(' / ')}';
  }

  @override
  Widget build(BuildContext context) {
    final segments = breadcrumbSegments;
    final trailing = breadcrumbTrailing;
    Widget crumb =
        breadcrumbWidget ??
        (segments == null
            ? Text(
                crumbFor(breadcrumb, hasTrailing: trailing != null),
                style: context.tokens.breadcrumb,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              )
            : _SegmentedCrumb(segments: segments));
    // A tap target's height on every screen, whether or not the line carries a verb or a
    // back tap, so the title under it does not move between tabs.
    const crumbHeight = TapTargets.minHeight;
    // Tight from the [Expanded] down through the [Align], so the back tap is the whole cell
    // rather than the width and height of the path's glyphs.
    Widget crumbCell = Align(alignment: Alignment.centerLeft, child: crumb);
    if (segments == null && onBack != null) {
      crumbCell = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onBack,
        child: crumbCell,
      );
    }

    // Zero wherever a bar below already spent the inset, so no screen that had it right
    // gains a gap.
    final systemBottom = MediaQuery.paddingOf(context).bottom;

    return SafeArea(
      bottom: false,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final insets =
              padding +
              EdgeInsets.only(bottom: systemBottom) +
              EdgeInsets.symmetric(
                horizontal: Layout.gutterFor(
                  constraints.maxWidth,
                  maxWidth: maxContentWidth,
                ),
              );
          final head = [
            // The gap under the row is given back, so taking a tap target's height keeps the
            // header's rhythm.
            SizedBox(
              height: crumbHeight,
              child: Row(
                children: [
                  // Expanded and not Flexible-plus-Spacer: two flex children would split the width in half
                  // before the path was ever measured against it.
                  Expanded(child: crumbCell),
                  ?trailing,
                ],
              ),
            ),
            if (title != null)
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // The cursor rides with the title inside its own Row: a Spacer as a direct sibling would
                  // claim half the width and ellipsize a project's name long before it had to.
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: SignalText(
                            title!,
                            style: context.tokens.screenTitle,
                            decodeOnEntry: true,
                            smearOnEntry: true,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text('_', style: context.tokens.screenTitle),
                      ],
                    ),
                  ),
                  ?titleTrailing,
                ],
              ),
            const SizedBox(height: Spacing.md),
            Container(
              height: Borders.hairline,
              color: context.tokens.borderNormal,
            ),
            const SizedBox(height: Spacing.lg),
            ?header,
          ];
          if (fill) {
            return Padding(
              padding: insets,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ...head,
                  Expanded(child: children.single),
                ],
              ),
            );
          }
          // Centred by padding, not by narrowing the ListView: its margins stay live to a drag,
          // and on a near-square display they are a third of the screen.
          return ListView(padding: insets, children: [...head, ...children]);
        },
      ),
    );
  }
}

class CrumbSegment {
  const CrumbSegment(this.label, {this.onTap});

  final String label;
  final VoidCallback? onTap;
}

/// How many segments to drop is measured rather than guessed: laid out as a plain [Row]
/// the overflow would be silent in release and a yellow bar in debug, and ellipsizing the
/// row's last child would eat the one segment the rule says to keep.
class _SegmentedCrumb extends StatelessWidget {
  const _SegmentedCrumb({required this.segments});

  final List<CrumbSegment> segments;

  static TextStyle _styleOf(BuildContext context) => context.tokens.breadcrumb;
  static const _separator = ' / ';
  static const _elision = '…';

  @override
  Widget build(BuildContext context) {
    if (segments.isEmpty) return const SizedBox.shrink();
    final style = _styleOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        double widthOf(String text) => lineWidth(context, text, style);

        var dropped = 0;
        // Never past the immediate parent; a name too long even for that ellipsizes below.
        while (dropped < segments.length - 1 &&
            widthOf(_textFor(dropped)) > constraints.maxWidth) {
          dropped++;
        }
        // Below the floor the row's fixed `/ ` and `… / ` would overflow rather than clip, so
        // one ellipsizing line takes over and gives up the per-segment taps.
        if (widthOf(_textFor(dropped)) > constraints.maxWidth) {
          return Text(
            _textFor(dropped),
            style: style,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          );
        }
        final kept = segments.sublist(dropped);
        // The Row is the ceiling — a child never takes a hit its parent has already rejected —
        // so a segment is given the line's height rather than the 13px the path paints.
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
              // A [Text] answers a hit, so a separator left pointing would swallow the tap a segment's
              // box reaches into it for.
              IgnorePointer(child: Text('/ ', style: style)),
              if (dropped > 0)
                IgnorePointer(
                  child: Text('$_elision$_separator', style: style),
                ),
              for (var i = 0; i < kept.length; i++) ...[
                if (i > 0) IgnorePointer(child: Text(_separator, style: style)),
                // Only the last segment flexes: a Flexible child is capped at its equal share of the
                // free space, so making every segment one ellipsized names that fitted whole with slack
                // still to their right.
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
    // The last segment is the screen the user is on and has no [onTap], so it is not painted
    // as a control.
    final baseStyle = _SegmentedCrumb._styleOf(context);
    final style = _down
        ? baseStyle.copyWith(color: context.tokens.accent)
        : baseStyle;
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
