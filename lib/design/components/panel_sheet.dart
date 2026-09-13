import 'package:flutter/material.dart';

import '../../application/native_plugins.dart';

import '../colors.dart';
import '../layout.dart';
import '../motion.dart';
import '../spacing.dart';
import 'action_block.dart';
import 'keyboard_toolbar.dart';
import 'meta.dart';
import 'panel.dart';

/// The item quick view, the MOVE picker and the PAIR picker are
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
  final content = inheritPluginScope(
    context,
    _SheetFrame(
      maxHeightFraction: maxHeightFraction,
      child: Builder(builder: builder),
    ),
  );
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: title,
    barrierColor: const Color(0xCC000000),
    transitionDuration: Motion.fast,
    pageBuilder: (context, animation, secondary) => content,
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

/// The app's confirmation modal — a [Panel] with the
/// question as its header and two blocks, the affirmative one filled accent.
/// Everything that asks before acting asks in this shape.
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
                tone: DazzleColors.accent,
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
          // under the accessory strip, which is an overlay on top of both.
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
              // The [Align] above is already bottom-centred, so the cap
              // is all the sheet needs to stay a sheet on a wide display
              // instead of a band across it.
              maxWidth: Layout.columnMax,
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

/// A hairline between the sections of a sheet: the panel rule, inset to the
/// panel body rather than run edge to edge, because inside a body it separates
/// content and not rows of a table.
class SheetRule extends StatelessWidget {
  const SheetRule({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: Borders.hairline,
      margin: const EdgeInsets.symmetric(vertical: Spacing.md),
      color: DazzleColors.borderSubtle,
    );
  }
}

/// Every fact in a sheet is a `[ LABEL ]` over its value, so the body reads as
/// a readout and not as a form.
class SheetField extends StatelessWidget {
  const SheetField({super.key, required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Meta('[ $label ]'),
        const SizedBox(height: Spacing.sm),
        child,
      ],
    );
  }
}
