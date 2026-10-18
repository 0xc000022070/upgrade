import 'package:flutter/material.dart';

import 'package:striked/design/tokens.dart';
import 'package:striked/design/spacing.dart';
import 'package:striked/design/components/sheet_route.dart';

class SheetAction {
  const SheetAction(
    this.label,
    this.onSelected, {
    this.danger = false,
    this.selected = false,
  });

  final String label;
  final VoidCallback onSelected;
  final bool danger;

  final bool selected;
}

Future<void> showActionSheet(
  BuildContext context, {
  required String title,
  required List<SheetAction> actions,
  bool recommendFirst = true,
}) {
  return showSheetRoute<void>(
    context,
    title: title,
    child: Align(
      alignment: Alignment.bottomCenter,
      child: _Sheet(
        title: title,
        actions: actions,
        recommendFirst: recommendFirst,
      ),
    ),
  );
}

class _Sheet extends StatelessWidget {
  const _Sheet({
    required this.title,
    required this.actions,
    required this.recommendFirst,
  });

  final String title;
  final List<SheetAction> actions;

  final bool recommendFirst;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      title: title,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < actions.length; i++)
            Builder(
              builder: (context) {
                final action = actions[i];
                final block = actions[i].selected || (i == 0 && recommendFirst);
                return Padding(
                  padding: EdgeInsets.symmetric(
                    vertical: block ? Spacing.sm : 0,
                  ),
                  child: block
                      ? _BlockRow(action: action)
                      : _PlainRow(
                          label: action.label,
                          danger: action.danger,
                          divider: i < actions.length - 1,
                          onTap: () {
                            Navigator.of(context).pop();
                            action.onSelected();
                          },
                        ),
                );
              },
            ),
        ],
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.tokens.surfacePrimary,
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(
              color: context.tokens.borderNormal,
              width: Borders.hairline,
            ),
          ),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              Spacing.screenEdge,
              Spacing.lg,
              Spacing.screenEdge,
              Spacing.md,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: Spacing.md),
                  child: Text(
                    title.toUpperCase(),
                    style: context.tokens.panelHeader,
                  ),
                ),
                child,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BlockRow extends StatelessWidget {
  const _BlockRow({required this.action});

  final SheetAction action;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        Navigator.of(context).pop();
        action.onSelected();
      },
      child: Container(
        constraints: const BoxConstraints(minHeight: TapTargets.minHeight),
        padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
        decoration: BoxDecoration(
          color: context.tokens.accent,
          borderRadius: BorderRadius.circular(Radii.sharp),
        ),
        child: Row(
          children: [
            Text(
              '// ',
              style: context.tokens.valueStrong.copyWith(
                color: context.tokens.backgroundPrimary,
              ),
            ),
            Expanded(
              child: Text(
                action.label,
                style: context.tokens.rowTitle.copyWith(
                  color: context.tokens.backgroundPrimary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlainRow extends StatelessWidget {
  const _PlainRow({
    required this.label,
    required this.onTap,
    this.danger = false,
    this.divider = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool danger;
  final bool divider;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        alignment: Alignment.centerLeft,
        constraints: const BoxConstraints(minHeight: TapTargets.minHeight),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: divider
                  ? context.tokens.borderSubtle
                  : const Color(0x00000000),
              width: Borders.hairline,
            ),
          ),
        ),
        child: Text(
          label,
          style: context.tokens.rowTitle.copyWith(
            color: danger ? context.tokens.danger : context.tokens.textPrimary,
          ),
        ),
      ),
    );
  }
}
