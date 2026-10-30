import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'package:striked/design/icons/striked_icon.dart';
import 'package:striked/design/icons/striked_icons.dart';
import 'package:striked/design/spacing.dart';
import 'package:striked/design/tokens.dart';

class MenuEntry {
  const MenuEntry(this.label, this.icon, this.onSelected);

  final String label;
  final StrikedIcons icon;
  final VoidCallback onSelected;
}

Future<void> showAnchorMenu(
  BuildContext anchor, {
  required String title,
  required List<MenuEntry> entries,
}) {
  final box = anchor.findRenderObject()! as RenderBox;
  final rect = box.localToGlobal(Offset.zero) & box.size;
  return showGeneralDialog<void>(
    context: anchor,
    useRootNavigator: false,
    barrierDismissible: true,
    barrierLabel: 'DISMISS $title',
    barrierColor: const Color(0x00000000),
    transitionDuration: Duration.zero,
    pageBuilder: (context, _, _) => _AnchoredMenu(rect: rect, entries: entries),
  );
}

class _AnchoredMenu extends StatelessWidget {
  const _AnchoredMenu({required this.rect, required this.entries});

  static const _width = 248.0;

  final Rect rect;
  final List<MenuEntry> entries;

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final right = rect.center.dx > screen.width / 2;
    final left = right
        ? math.max(Spacing.screenEdge, rect.right - _width)
        : math.min(rect.left, screen.width - Spacing.screenEdge - _width);
    return Stack(
      children: [
        Positioned(
          left: left,
          top: rect.bottom + Spacing.xs,
          width: _width,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: context.tokens.surfacePrimary,
              border: Border.all(
                color: context.tokens.borderNormal,
                width: Borders.hairline,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final entry in entries)
                  Semantics(
                    button: true,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        Navigator.of(context).pop();
                        entry.onSelected();
                      },
                      child: SizedBox(
                        height: 48,
                        child: Row(
                          children: [
                            const SizedBox(width: Spacing.lg),
                            StrikedIcon(
                              entry.icon,
                              size: IconSizes.md,
                              color: context.tokens.textSecondary,
                            ),
                            const SizedBox(width: Spacing.lg),
                            Expanded(
                              child: Text(
                                entry.label,
                                style: context.tokens.rowTitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
