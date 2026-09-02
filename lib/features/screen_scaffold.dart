import 'package:flutter/widgets.dart';

import '../design/colors.dart';
import '../design/components/signal_text.dart';
import '../design/spacing.dart';
import '../design/typography.dart';

/// SPEC.md §38.5, geometry from the mocks: a breadcrumb line, the title with
/// its `_` cursor, a rule across the content width, then the panel stack.
///
/// A detail screen has no chevron — the mocks drop it and the breadcrumb takes
/// the tap instead, which keeps the title's full width for the project's name.
class ScreenScaffold extends StatelessWidget {
  const ScreenScaffold({
    super.key,
    required this.title,
    required this.children,
    this.breadcrumb = '/ PERSONAL CONTROL PLANE',
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

  final String title;
  final String breadcrumb;

  /// §39.2: the detail screen's `EDIT` sits here. The breadcrumb line is the
  /// only row above the title, and a screen-level verb belongs beside the path
  /// it acts on rather than beside the name it would compete with.
  final Widget? breadcrumbTrailing;

  final List<Widget> children;

  /// §38.5: a small mono control on the title's right, only when it does
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
    Widget crumb = Text(
      crumbFor(breadcrumb, hasTrailing: breadcrumbTrailing != null),
      style: HotlineText.breadcrumb,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    if (onBack != null) {
      crumb = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onBack,
        child: Padding(
          // The back tap needs height of its own, except in a row that already
          // gives the whole line a tap target's worth.
          padding: EdgeInsets.only(
            bottom: breadcrumbTrailing == null ? Spacing.md : 0,
          ),
          child: crumb,
        ),
      );
    }

    return SafeArea(
      bottom: false,
      child: ListView(
        padding: padding,
        children: [
          if (breadcrumbTrailing == null) ...[
            crumb,
            const SizedBox(height: Spacing.sm),
          ] else
            // The row takes a full tap target's height so the trailing verb is
            // hittable (§35) without a 13px control floating in the margin; the
            // gap under it is given back, so the header keeps its rhythm.
            SizedBox(
              height: TapTargets.minHeight,
              child: Row(
                children: [
                  // The path takes the room it needs and the verb keeps its
                  // own: an Expanded crumb would ellipsize a long path before
                  // the trailing control had any reason to move.
                  Flexible(child: crumb),
                  const Spacer(),
                  breadcrumbTrailing!,
                ],
              ),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // The cursor rides with the title inside its own Row: a Spacer
              // as a direct sibling would claim half the width and ellipsize
              // a project's name long before it had to.
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: SignalText(
                        title,
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
    );
  }
}
