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
  final List<Widget> children;

  /// §38.5: a small mono control on the title's right, only when it does
  /// something. Nothing renders here otherwise.
  final Widget? titleTrailing;

  final VoidCallback? onBack;

  /// Rendered above the panel stack — the detail hero card, which is a panel
  /// but not a section.
  final Widget? header;

  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final crumb = Text(breadcrumb, style: HotlineText.breadcrumb);

    return SafeArea(
      bottom: false,
      child: ListView(
        padding: padding,
        children: [
          if (onBack == null)
            crumb
          else
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onBack,
              child: Padding(
                padding: const EdgeInsets.only(bottom: Spacing.md),
                child: crumb,
              ),
            ),
          const SizedBox(height: Spacing.sm),
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
