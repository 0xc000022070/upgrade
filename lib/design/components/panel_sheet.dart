import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:upgrade/application/plugins/plugin_scope_stub.dart'
    if (dart.library.ffi) 'package:upgrade/application/plugins/native_plugins.dart'
    show inheritPluginScope;

import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/design/layout.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/design/components/action_block.dart';
import 'package:upgrade/design/components/keyboard_toolbar.dart';
import 'package:upgrade/design/components/meta.dart';
import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/design/components/sheet_route.dart';

Future<T?> showPanelSheet<T>(
  BuildContext context, {
  required String title,
  required WidgetBuilder builder,
  double maxHeightFraction = 0.86,
  double maxWidth = Layout.columnMax,
}) {
  final content = inheritPluginScope(
    context,
    _SheetFrame(
      maxHeightFraction: maxHeightFraction,
      maxWidth: maxWidth,
      child: Builder(builder: builder),
    ),
  );
  return showSheetRoute<T>(context, title: title, child: content);
}

Future<bool> confirmSheet(
  BuildContext context, {
  required String title,
  required String confirmLabel,
  String? message,
}) async {
  final answer = await showPanelSheet<bool>(
    context,
    title: title,
    builder: (context) => ConfirmSheetBody(
      title: title,
      confirmLabel: confirmLabel,
      message: message,
    ),
  );
  return answer ?? false;
}

/// [onConfirm] runs inside the confirm tap, after the pop: what it starts is fresh from it.
class ConfirmSheetBody extends StatelessWidget {
  const ConfirmSheetBody({
    super.key,
    required this.title,
    required this.confirmLabel,
    this.message,
    this.onConfirm,
  });

  final String title;
  final String confirmLabel;
  final String? message;
  final VoidCallback? onConfirm;

  @override
  Widget build(BuildContext context) {
    final message = this.message;
    return PanelSheetBody(
      title: title,
      children: [
        if (message != null) ...[
          Text(message, style: context.tokens.prose),
          const SizedBox(height: Spacing.md),
        ],
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
                tone: context.tokens.accent,
                filled: true,
                onTap: () {
                  Navigator.of(context).pop(true);
                  onConfirm?.call();
                },
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _SheetFrame extends StatelessWidget {
  const _SheetFrame({
    required this.child,
    required this.maxHeightFraction,
    required this.maxWidth,
  });

  final Widget child;
  final double maxHeightFraction;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return ValueListenableBuilder<double>(
      valueListenable: KeyboardAccessory.reservedHeight,
      builder: (context, accessory, child) {
        final bottom =
            media.viewInsets.bottom +
            media.padding.bottom +
            accessory +
            Spacing.md;
        final room = media.size.height - bottom - media.padding.top;
        return Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            // A dialog route does not resize for the IME the way a scaffold does, and the accessory
            // strip is an overlay on top of both.
            padding: EdgeInsets.only(
              left: Spacing.screenEdge,
              right: Spacing.screenEdge,
              bottom: bottom,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: maxWidth,
                maxHeight: math.max(
                  0,
                  math.min(media.size.height * maxHeightFraction, room),
                ),
              ),
              child: Material(color: const Color(0x00000000), child: child),
            ),
          ),
        );
      },
      child: child,
    );
  }
}

class PanelSheetBody extends StatelessWidget {
  const PanelSheetBody({
    super.key,
    required this.title,
    required this.children,
    this.affordance,
    this.onTitleLongPress,
    this.footer = const [],
  });

  final String title;
  final Widget? affordance;
  final VoidCallback? onTitleLongPress;
  final List<Widget> children;

  /// Stays below the scrolling children, so an action that ends a long list is always
  /// in reach.
  final List<Widget> footer;

  @override
  Widget build(BuildContext context) {
    final scroll = SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    );
    return Panel(
      title: title,
      affordance: affordance,
      onHeaderLongPress: onTitleLongPress,
      bodyPadding: const EdgeInsets.all(Spacing.panelPadding),
      bodyFlexible: true,
      child: footer.isEmpty
          ? scroll
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(child: scroll),
                const SheetRule(),
                ...footer,
              ],
            ),
    );
  }
}

class SheetRule extends StatelessWidget {
  const SheetRule({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: Borders.hairline,
      margin: const EdgeInsets.symmetric(vertical: Spacing.md),
      color: context.tokens.borderSubtle,
    );
  }
}

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
