import 'package:flutter/material.dart';

import '../colors.dart';
import '../motion.dart';
import '../spacing.dart';
import 'action_block.dart';
import 'keyboard_toolbar.dart';
import 'panel.dart';

/// SPEC.md §39.4: the item quick view, the MOVE picker and the PAIR picker are
/// the app's only modal surfaces, and all three are a [Panel] parked at the
/// bottom of the screen. Material's sheet is not used: no drag handle, no
/// rounded shoulders, no elevation, no scrim animation of its own.
///
/// The body is scrollable and the panel is capped at [maxHeightFraction] of the
/// screen, so an item with a long title and six links stays a sheet instead of
/// growing into a page.
Future<T?> showPanelSheet<T>(
  BuildContext context, {
  required String title,
  required WidgetBuilder builder,
  double maxHeightFraction = 0.86,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: title,
    barrierColor: const Color(0xCC000000),
    transitionDuration: Motion.fast,
    pageBuilder: (context, animation, secondary) => _SheetFrame(
      maxHeightFraction: maxHeightFraction,
      child: Builder(builder: builder),
    ),
    transitionBuilder: (context, animation, secondary, child) {
      return FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween(
            begin: const Offset(0, 0.04),
            end: Offset.zero,
          ).animate(CurvedAnimation(parent: animation, curve: Motion.enter)),
          child: child,
        ),
      );
    },
  );
}

/// SPEC.md §39.13 and §39.14: the app's confirmation modal — a [Panel] with the
/// question as its header and two blocks, the affirmative one filled accent per
/// §16c. Everything that asks before acting asks in this shape.
Future<bool> confirmSheet(
  BuildContext context, {
  required String title,
  required String confirmLabel,
}) async {
  final answer = await showPanelSheet<bool>(
    context,
    title: title,
    builder: (context) => PanelSheetBody(
      title: title,
      children: [
        Row(
          children: [
            Expanded(
              child: ActionBlock(
                label: 'CANCEL',
                onTap: () => Navigator.of(context).pop(false),
              ),
            ),
            const SizedBox(width: Spacing.md),
            Expanded(
              child: ActionBlock(
                label: confirmLabel,
                tone: HotlineColors.accent,
                filled: true,
                onTap: () => Navigator.of(context).pop(true),
              ),
            ),
          ],
        ),
      ],
    ),
  );
  return answer ?? false;
}

class _SheetFrame extends StatelessWidget {
  const _SheetFrame({required this.child, required this.maxHeightFraction});

  final Widget child;
  final double maxHeightFraction;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return ValueListenableBuilder<double>(
      valueListenable: KeyboardAccessory.reservedHeight,
      builder: (context, accessory, child) => Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          // A dialog route does not resize for the IME the way a scaffold
          // does, so without this the sheet opens under the keyboard — and
          // under the §39.9 strip, which is an overlay on top of both.
          padding: EdgeInsets.only(
            left: Spacing.screenEdge,
            right: Spacing.screenEdge,
            bottom:
                media.viewInsets.bottom +
                media.padding.bottom +
                accessory +
                Spacing.md,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: media.size.height * maxHeightFraction,
            ),
            child: Material(color: const Color(0x00000000), child: child),
          ),
        ),
      ),
      child: child,
    );
  }
}

/// The scrolling body every sheet shares. Kept here rather than in each caller
/// so the panel's own padding and the scroll view's stay in one place.
class PanelSheetBody extends StatelessWidget {
  const PanelSheetBody({
    super.key,
    required this.title,
    required this.children,
    this.affordance,
    this.onTitleLongPress,
  });

  final String title;
  final Widget? affordance;
  final VoidCallback? onTitleLongPress;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Panel(
      title: title,
      affordance: affordance,
      onHeaderLongPress: onTitleLongPress,
      bodyPadding: const EdgeInsets.all(Spacing.panelPadding),
      bodyFlexible: true,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: children,
        ),
      ),
    );
  }
}

/// A hairline between the sections of a sheet: the §38.1 rule, inset to the
/// panel body rather than run edge to edge, because inside a body it separates
/// content and not rows of a table.
class SheetRule extends StatelessWidget {
  const SheetRule({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: Borders.hairline,
      margin: const EdgeInsets.symmetric(vertical: Spacing.md),
      color: HotlineColors.borderSubtle,
    );
  }
}
